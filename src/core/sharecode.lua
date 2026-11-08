-- Preset share codes: one preset to a short ASCII string, and back.
--
--   PV1-AQPYAb82At6HBtr1BqiVBpaHBsLABvyRB/r6A8r1...
--   ^^^ ^
--   |   format version (also the first payload byte)
--   plugin namespace
--
-- The body is standard unpadded base64 (symbols "+" and "/"), so it is
-- CASE-SENSITIVE and nothing here may upper-case it.
--
-- PAYLOAD LAYOUT, in order:
--   version    1 byte
--   flags      1 byte  - icon / bob present
--   icon       varint                  (only if flagged)
--   bob size   varint, clamped 1..32   (only if bob flagged)
--   sections   equipment, backpack, and bob if flagged; each is a
--              fixed-width SLOT BITMAP (3, 4 and 4 bytes = 19, 28 and 32
--              bits, one per slot) followed by one { obj, count } pair per
--              set bit, in ascending slot order
--   name       varint length + bytes
--   ext        varint length + that many bytes, skipped by this version
--   checksum   CRC-16/CCITT-FALSE over everything above
--
-- A code carries ITEMS ONLY: no preset id, no vault key, no tracking id,
-- no category - imports always land in Uncategorised.
local M = {}

M.VERSION = 1 -- payload format version; also the digit in the "PV1-" prefix
M.PREFIX = "PV"
local MAX_NAME = 25 -- matches store.lua's MAX_NAME

-- Container geometry. Slots are 1-based, so slot N maps to bit N-1.
--   equipment  inv 94  - 19 slots
--   backpack   inv 93  - 28 slots
--   bob        inv 530 - 32 slots
local SECTIONS = {
  { key = "equipment", slots = 19, bytes = 3 },
  { key = "backpack", slots = 28, bytes = 4 },
  { key = "bob", slots = 32, bytes = 4 }, -- only when preset.bob exists
}

local FLAG_ICON = 0x02
local FLAG_BOB = 0x04

-- Hostile-input ceilings: every bound explicit, every loop bounded by a
-- constant rather than by the payload.
local MAX_CODE_CHARS = 2000 -- before decoding: a 10MB paste must not reach the
-- bit loop at all (the client kills any Lua call over 1000ms)
local MAX_VARINT_BYTES = 5 -- 5 * 7 = 35 bits, comfortably over MAX_COUNT
local MAX_OBJ = 0x1FFFFF -- 2,097,151: current ids are ~5 figures, so this
-- leaves generous headroom while keeping obj<<1 inside 3 varint bytes
local MAX_COUNT = 0x7FFFFFFF -- int32, the engine's own stack ceiling
local MAX_ICON = 0x7FFFFFFF -- int32 max: sprite ids span the whole positive
-- int32 range; at most 5 varint bytes, within MAX_VARINT_BYTES
local MAX_EXT_BYTES = 512 -- a v1 decoder only skips this, never parses it

-- ---- base64 (standard alphabet, unpadded) -----------------------------------
local ALPHABET =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DECODE_MAP = {}
do
  for i = 1, #ALPHABET do
    DECODE_MAP[string.sub(ALPHABET, i, i)] = i - 1
  end
end

-- Both directions carry 6-bit groups through a small accumulator. Masking
-- `acc` to the bits still PENDING on each step keeps it under 14 bits.
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
  -- padding - the decoder drops leftover bits, which are always under 8.
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
      -- The offending character is quoted back only when printable ASCII;
      -- anything else is reported by position alone.
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

-- ---- CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) --------------------------
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

-- ---- byte writer ------------------------------------------------------------
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

-- Fixed-width little-endian, used for the slot bitmaps.
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

-- ---- byte reader ------------------------------------------------------------
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
  -- A varint longer than the cap is corruption or an attack, never real data.
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

-- ---- labels -----------------------------------------------------------------
-- Sanitises an incoming preset or category name, falling back when nothing
-- usable survives.
local function sanitiseLabel(s, fallback)
  if type(s) ~= "string" then return fallback end
  local kept = {}
  for i = 1, #s do
    local b = string.byte(s, i)
    -- Printable ASCII only, MINUS the angle brackets, which are markup in
    -- this client.
    if b >= 32 and b <= 126 and b ~= 60 and b ~= 62 then
      kept[#kept + 1] = string.char(b)
    end
    if #kept >= MAX_NAME then break end
  end
  local out = table.concat(kept)
  out = string.match(out, "^%s*(.-)%s*$") or "" -- trim
  if out == "" then return fallback end
  return out
end

-- ---- encode -----------------------------------------------------------------
-- Collapses a section's entry array into slot -> { obj, count } plus its
-- bitmap, rejecting anything the format cannot represent.
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
      -- Entries follow in ascending slot order, which is exactly the order
      -- the decoder walks the bitmap in - no slot numbers on the wire.
      for slot = 1, sec.slots do
        local e = bySlot[slot]
        if e ~= nil then
          -- Low bit flags "an explicit count follows". Count 1 is by far the
          -- commonest case, so leaving it implicit saves a byte per item.
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

  w:varint(0) -- ext block, empty in v1 (see the header note)

  local payload = w:tostring()
  local crc = crc16(payload)
  local body = payload .. string.char((crc >> 8) & 0xFF, crc & 0xFF)

  -- One hyphen, after the prefix, and none inside the body: codes travel by
  -- copy and paste, so grouping would only add length. The decoder strips
  -- hyphens anyway, so a grouped code still imports.
  return M.PREFIX .. M.VERSION .. "-" .. base64Encode(body)
end

-- ---- decode -----------------------------------------------------------------
-- Splits "PV1-XXXX" into its version and bare body. The version is checked
-- BEFORE any decoding.
local function splitPrefix(code)
  -- The separator may be a hyphen or whitespace, but NOT absent.
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

-- Code string -> preset table, or nil + reason. The preset carries no id;
-- the caller assigns one.
--   resolveName(obj) -> display name, or nil if this client cannot resolve
--   it. Passing nil skips name resolution entirely.
M.Decode = function(code, resolveName)
  if type(code) ~= "string" then return nil, "no code" end
  if #code > MAX_CODE_CHARS then return nil, "code is too long to be valid" end

  -- Backticks are stripped before anything else.
  code = string.gsub(code, "`", "")

  local body, prefixErr = splitPrefix(code)
  if body == nil then return nil, prefixErr end

  -- Strips wrapped whitespace and any hyphens. Case is left ALONE.
  body = string.gsub(body, "[%-%s]", "")
  if #body < 8 then return nil, "code is too short to be valid" end

  local bytes, b64Err = base64Decode(body)
  if bytes == nil then return nil, b64Err end
  if #bytes < 4 then return nil, "code is too short to be valid" end

  -- Checksum first: nothing below is interpreted until the bytes are known
  -- to be intact.
  local payload = string.sub(bytes, 1, #bytes - 2)
  local want = (string.byte(bytes, #bytes - 1) << 8) | string.byte(bytes, #bytes)
  if crc16(payload) ~= want then
    return nil, "this code is damaged - it may have been copied incompletely"
  end

  local r = newReader(payload)

  local version, err = r:byte()
  if version == nil then return nil, err end
  -- The prefix already agreed; a disagreement here means the code was
  -- truncated and re-joined, or two codes were pasted together.
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
      -- The loop is bounded by sec.slots, a constant - a hostile bitmap can
      -- only ever describe that many items.
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
          -- An unresolved obj keeps its id and goes in unnamed.
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

  -- Ext block: a later format version may append optional fields here. This
  -- decoder deliberately skips them and imports what it does understand.
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

-- Display form: the bare code wrapped in backticks, as the share window
-- shows it.
M.Wrap = function(code)
  if type(code) ~= "string" then return code end
  return "`" .. code .. "`"
end

-- Exposed so the codec's primitives can be unit-tested directly. Nothing in
-- the plugin reads this table.
M._internal = {
  crc16 = crc16,
  base64Encode = base64Encode,
  base64Decode = base64Decode,
}

return M
