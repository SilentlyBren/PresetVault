-- Preset share codes: one preset to a short ASCII string ("PV1-" plus
-- unpadded standard base64), and back. Touches no game globals, so it runs
-- in plain Lua 5.4.
local M = {}

M.VERSION = 1
M.PREFIX = "PV"
local MAX_NAME = 25 -- must equal core/store's MAX_NAME

-- Slots are 1-based: slot N is bit N-1 of a section's `bytes`-wide bitmap.
local SECTIONS = {
  { key = "equipment", slots = 19, bytes = 3 },
  { key = "backpack", slots = 28, bytes = 4 },
  { key = "bob", slots = 32, bytes = 4 },
}

local FLAG_ICON = 0x02
local FLAG_BOB = 0x04

-- Codes are untrusted: no loop below may be sized from the payload.
local MAX_CODE_CHARS = 2000
local MAX_VARINT_BYTES = 5
local MAX_OBJ = 0x1FFFFF -- keeps obj << 1 inside 3 varint bytes
local MAX_COUNT = 0x7FFFFFFF
local MAX_ICON = 0x7FFFFFFF
local MAX_EXT_BYTES = 512

local ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE_MAP = {}
do
  for i = 1, #ALPHABET do
    DECODE_MAP[string.sub(ALPHABET, i, i)] = i - 1
  end
end

-- Keeps the accumulator to its pending bits, so it cannot grow with input.
local function maskPending(acc, bits)
  return acc & ((1 << bits) - 1)
end

local function base64Encode(bytes)
  local out, acc, bits = {}, 0, 0
  for i = 1, #bytes do
    acc = (maskPending(acc, bits) << 8) | string.byte(bytes, i)
    bits = bits + 8
    while bits >= 6 do
      bits = bits - 6
      local v = (acc >> bits) & 0x3F
      out[#out + 1] = string.sub(ALPHABET, v + 1, v + 1)
    end
  end
  -- Trailing bits are left-aligned into one final character, with no "="
  -- padding; the decoder drops the leftover bits.
  if bits > 0 then
    local v = (maskPending(acc, bits) << (6 - bits)) & 0x3F
    out[#out + 1] = string.sub(ALPHABET, v + 1, v + 1)
  end
  return table.concat(out)
end

local function base64Decode(text)
  local out, acc, bits = {}, 0, 0
  for i = 1, #text do
    local ch = string.sub(text, i, i)
    local v = DECODE_MAP[ch]
    if v == nil then
      -- Only printable ASCII is echoed into a player-visible message.
      local b = string.byte(ch)
      if b >= 33 and b <= 126 then
        return nil, "unexpected character '" .. ch .. "' in code"
      end
      return nil, "unexpected character at position " .. i .. " in code"
    end
    acc = (maskPending(acc, bits) << 6) | v
    bits = bits + 6
    if bits >= 8 then
      bits = bits - 8
      out[#out + 1] = string.char((acc >> bits) & 0xFF)
    end
  end
  return table.concat(out)
end

-- CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF.
local function crc16(bytes)
  local crc = 0xFFFF
  for i = 1, #bytes do
    crc = crc ~ (string.byte(bytes, i) << 8)
    for _ = 1, 8 do
      if (crc & 0x8000) ~= 0 then
        crc = ((crc << 1) ~ 0x1021) & 0xFFFF
      else
        crc = (crc << 1) & 0xFFFF
      end
    end
  end
  return crc & 0xFFFF
end

local Writer = {}
Writer.__index = Writer

local function newWriter()
  return setmetatable({ parts = {} }, Writer)
end

function Writer:byte(n)
  self.parts[#self.parts + 1] = string.char(n & 0xFF)
end

-- Unsigned LEB128: 7 bits per byte, high bit = "another byte follows".
function Writer:varint(n)
  n = math.floor(n)
  repeat
    local b = n & 0x7F
    n = n >> 7
    if n ~= 0 then b = b | 0x80 end
    self:byte(b)
  until n == 0
end

-- Little-endian.
function Writer:fixed(n, width)
  for i = 0, width - 1 do
    self:byte((n >> (i * 8)) & 0xFF)
  end
end

function Writer:raw(s)
  self.parts[#self.parts + 1] = s
end

function Writer:tostring()
  return table.concat(self.parts)
end

local Reader = {}
Reader.__index = Reader

local function newReader(bytes)
  return setmetatable({ s = bytes, pos = 1 }, Reader)
end

function Reader:remaining()
  return #self.s - self.pos + 1
end

function Reader:byte()
  if self.pos > #self.s then return nil, "code ends early" end
  local b = string.byte(self.s, self.pos)
  self.pos = self.pos + 1
  return b
end

function Reader:varint()
  local n, shift = 0, 0
  for _ = 1, MAX_VARINT_BYTES do
    local b, err = self:byte()
    if b == nil then return nil, err end
    n = n | ((b & 0x7F) << shift)
    if (b & 0x80) == 0 then return n end
    shift = shift + 7
  end
  return nil, "oversized number in code"
end

function Reader:fixed(width)
  local n = 0
  for i = 0, width - 1 do
    local b, err = self:byte()
    if b == nil then return nil, err end
    n = n | (b << (i * 8))
  end
  return n
end

function Reader:raw(len)
  if len > self:remaining() then return nil, "code ends early" end
  local s = string.sub(self.s, self.pos, self.pos + len - 1)
  self.pos = self.pos + len
  return s
end

local function sanitiseLabel(s, fallback)
  if type(s) ~= "string" then return fallback end
  local kept = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    -- Printable ASCII minus "<" and ">", which are markup in this client.
    if b >= 32 and b <= 126 and b ~= 60 and b ~= 62 then
      kept[#kept + 1] = string.char(b)
    end
    if #kept >= MAX_NAME then break end
  end
  local out = table.concat(kept)
  out = string.match(out, "^%s*(.-)%s*$") or ""
  if out == "" then return fallback end
  return out
end

-- Entry array -> slot-keyed { obj, count } map plus its bitmap, or nil +
-- reason for anything the format cannot represent.
local function indexSection(entries, slotCount)
  local bySlot, bitmap = {}, 0
  for _, e in ipairs(entries or {}) do
    local slot = tonumber(e.slot)
    local obj = tonumber(e.obj)
    local count = tonumber(e.count) or 1
    if slot == nil or slot < 1 or slot > slotCount or slot ~= math.floor(slot) then
      return nil, "slot " .. tostring(e.slot) .. " outside 1.." .. slotCount
    end
    if obj == nil or obj < 0 or obj > MAX_OBJ or obj ~= math.floor(obj) then
      return nil, "item id " .. tostring(e.obj) .. " out of range"
    end
    if count < 1 then count = 1 end
    if count > MAX_COUNT then count = MAX_COUNT end
    if bySlot[slot] ~= nil then
      return nil, "two items in slot " .. slot
    end
    bySlot[slot] = { obj = obj, count = math.floor(count) }
    bitmap = bitmap | (1 << (slot - 1))
  end
  return bySlot, bitmap
end

-- preset -> code string, or nil + reason.
M.Encode = function(preset)
  if type(preset) ~= "table" then return nil, "no preset" end

  local w = newWriter()
  w:byte(M.VERSION)

  local icon = tonumber(preset.icon)
  if icon ~= nil and (icon < 0 or icon > MAX_ICON) then icon = nil end
  local hasBob = type(preset.bob) == "table"
    and type(preset.bob.items) == "table"
    and #preset.bob.items > 0

  local flags = 0
  if icon ~= nil then flags = flags | FLAG_ICON end
  if hasBob then flags = flags | FLAG_BOB end
  w:byte(flags)

  if icon ~= nil then w:varint(icon) end
  if hasBob then
    local size = tonumber(preset.bob.size) or 32
    if size < 1 then size = 1 end
    if size > 32 then size = 32 end
    w:varint(math.floor(size))
  end

  for _, sec in ipairs(SECTIONS) do
    if sec.key ~= "bob" or hasBob then
      local entries = sec.key == "bob" and preset.bob.items or preset[sec.key]
      local bySlot, bitmapOrErr = indexSection(entries, sec.slots)
      if bySlot == nil then return nil, bitmapOrErr end
      w:fixed(bitmapOrErr, sec.bytes)
      -- Ascending slot order: the order the decoder walks the bitmap in.
      for slot = 1, sec.slots do
        local e = bySlot[slot]
        if e ~= nil then
          -- Low bit set = an explicit count follows; count 1 is implicit.
          local hasCount = e.count ~= 1
          w:varint((e.obj << 1) | (hasCount and 1 or 0))
          if hasCount then w:varint(e.count) end
        end
      end
    end
  end

  local name = sanitiseLabel(preset.name, "Untitled")
  w:varint(#name)
  w:raw(name)

  w:varint(0) -- empty ext block

  local payload = w:tostring()
  local crc = crc16(payload)
  local body = payload .. string.char((crc >> 8) & 0xFF, crc & 0xFF)

  return M.PREFIX .. M.VERSION .. "-" .. base64Encode(body)
end

local function splitPrefix(code)
  -- The separator may be a hyphen or whitespace, but must be present.
  local version, body = string.match(code, "^%s*[Pp][Vv](%d+)[%-%s]+(.*)$")
  if version == nil then
    return nil, "that does not look like a Preset Vault code"
  end
  version = tonumber(version)
  if version ~= M.VERSION then
    return nil, "this code needs a newer version of Preset Vault (format "
      .. version .. ")"
  end
  return body
end

-- Code string -> preset table without an id, or nil + reason.
-- resolveName(obj) returns a display name or nil; passing nil for the
-- function itself skips name resolution.
M.Decode = function(code, resolveName)
  if type(code) ~= "string" then return nil, "no code" end
  if #code > MAX_CODE_CHARS then return nil, "code is too long to be valid" end

  code = string.gsub(code, "`", "")

  local body, prefixErr = splitPrefix(code)
  if body == nil then return nil, prefixErr end

  -- "-" is not in the alphabet, so dropping it is safe. Case is data:
  -- never fold it.
  body = string.gsub(body, "[%-%s]", "")
  if #body < 8 then return nil, "code is too short to be valid" end

  local bytes, b64Err = base64Decode(body)
  if bytes == nil then return nil, b64Err end
  if #bytes < 4 then return nil, "code is too short to be valid" end

  -- Checksum first: nothing below is interpreted until it passes.
  local payload = string.sub(bytes, 1, #bytes - 2)
  local want = (string.byte(bytes, #bytes - 1) << 8) | string.byte(bytes, #bytes)
  if crc16(payload) ~= want then
    return nil, "this code is damaged - it may have been copied incompletely"
  end

  local r = newReader(payload)

  local version, err = r:byte()
  if version == nil then return nil, err end
  -- The prefix already agreed, so a mismatch here is a spliced code.
  if version ~= M.VERSION then return nil, "this code is damaged" end

  local flags
  flags, err = r:byte()
  if flags == nil then return nil, err end

  local preset = { name = "Untitled", equipment = {}, backpack = {} }

  if (flags & FLAG_ICON) ~= 0 then
    local icon
    icon, err = r:varint()
    if icon == nil then return nil, err end
    if icon >= 0 and icon <= MAX_ICON then preset.icon = icon end
  end

  local bobSize = nil
  if (flags & FLAG_BOB) ~= 0 then
    bobSize, err = r:varint()
    if bobSize == nil then return nil, err end
    if bobSize < 1 or bobSize > 32 then bobSize = 32 end
  end

  for _, sec in ipairs(SECTIONS) do
    if sec.key ~= "bob" or bobSize ~= nil then
      local bitmap
      bitmap, err = r:fixed(sec.bytes)
      if bitmap == nil then return nil, err end
      local entries = {}
      -- Bounded by sec.slots, a constant, whatever the bitmap holds.
      for slot = 1, sec.slots do
        if (bitmap & (1 << (slot - 1))) ~= 0 then
          local packed
          packed, err = r:varint()
          if packed == nil then return nil, err end
          local obj = packed >> 1
          local count = 1
          if (packed & 1) ~= 0 then
            count, err = r:varint()
            if count == nil then return nil, err end
          end
          if obj > MAX_OBJ then return nil, "item id out of range in code" end
          if count < 1 or count > MAX_COUNT then
            return nil, "item quantity out of range in code"
          end
          local name = nil
          if resolveName ~= nil then
            local ok, resolved = pcall(resolveName, obj)
            if ok and type(resolved) == "string" and resolved ~= "" then
              name = resolved
            end
          end
          entries[#entries + 1] =
            { slot = slot, obj = obj, count = count, name = name or ("?" .. obj) }
        end
      end
      if sec.key == "bob" then
        preset.bob = { size = bobSize, items = entries }
      else
        preset[sec.key] = entries
      end
    end
  end

  local nameLen
  nameLen, err = r:varint()
  if nameLen == nil then return nil, err end
  if nameLen > MAX_NAME * 4 then return nil, "name too long in code" end
  local rawName
  rawName, err = r:raw(nameLen)
  if rawName == nil then return nil, err end
  preset.name = sanitiseLabel(rawName, "Untitled")

  -- A later format version may append fields here; this decoder skips them.
  local extLen
  extLen, err = r:varint()
  if extLen == nil then return nil, err end
  if extLen > MAX_EXT_BYTES then return nil, "this code is damaged" end
  if extLen > 0 then
    local skipped
    skipped, err = r:raw(extLen)
    if skipped == nil then return nil, err end
  end

  return preset
end

M.Wrap = function(code)
  if type(code) ~= "string" then return code end
  return "`" .. code .. "`"
end

-- Test-only export; nothing in the plugin reads it.
M._internal = {
  crc16 = crc16,
  base64Encode = base64Encode,
  base64Decode = base64Decode,
}

return M
