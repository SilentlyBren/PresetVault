-- Preset persistence, and the vault-selection layer that decides which
-- stored vault is the current one. One PersistentDB key per preset plus a
-- small index per vault.
local identity = require("core/identity")

local M = {}

local PREFIX = "vault.v1"
local SCOPE_BASE = "base"
local KEY_SHARED = "vault.sharedScope"
local KEY_OWNER = "vault.baseOwner"
local KEY_LABELS = "vault.labels"
local MAX_NAME = 25

local lastScope = nil

-- { scope, idx, presets = { [id] = preset, or false when the key is absent } }
local cache = nil

-- false marks an unset key
local strings = {}

local function getStr(key)
  local v = strings[key]
  if v == nil then
    v = PersistentDB:GetString(key) or false
    strings[key] = v
  end
  return v or nil
end

local function setStr(key, value)
  PersistentDB:SetString(key, value)
  strings[key] = nil
end

M.Invalidate = function()
  cache = nil
  strings = {}
end

-- Label text is markup, and an invalid image tag crashes the client when drawn.
M.CleanName = function(s)
  s = tostring(s or ""):gsub("<[^<>]*>", ""):gsub("[<>]", "")
  return string.sub(s, 1, MAX_NAME)
end

local MAX_ICON = 0x7FFFFFFF

-- Sprite ids that crash the client when drawn.
local UNSAFE_ICONS = { [1243] = true }

-- Returns nil when the icon must not be drawn.
M.CleanIcon = function(iconId)
  local n = tonumber(iconId)
  if n == nil or n ~= math.floor(n) or n < 0 or n > MAX_ICON then return nil end
  n = math.floor(n)
  if UNSAFE_ICONS[n] then return nil end
  return n
end

local function idxKey(scope) return PREFIX .. "." .. scope .. ".idx" end
local function presetKey(scope, id) return PREFIX .. "." .. scope .. ".p" .. id end

-- PersistentDB silently drops a value of 131,072 bytes or more and reports
-- success, so every write is read back. `rev` is what gets compared, because
-- a rejected write leaves the previous value in place.
local function writeVerified(key, tbl)
  tbl.rev = (tbl.rev or 0) + 1
  PersistentDB:SetStructuredData(key, tbl)
  local back = PersistentDB:GetStructuredData(key)
  if back ~= nil and back.rev == tbl.rev then return true end
  cache = nil -- the in-memory copy holds an edit that never landed
  log(formatStr("[PV] SAVE FAILED for {} - value rejected (128 KiB ceiling?)",
    tostring(key)))
  return false
end

-- Per-character mode only: a shared scope would be relabelled by every
-- character that reads it.
local function rememberLabel(scope)
  if scope == lastScope then return end
  if not identity.Enabled() then return end
  local name = identity.DisplayName()
  -- lastScope is latched only after a name has been read
  if name == nil then return end
  lastScope = scope
  local labels = PersistentDB:GetStructuredData(KEY_LABELS) or {}
  if labels[scope] == name then return end
  labels[scope] = name
  PersistentDB:SetStructuredData(KEY_LABELS, labels)
end

-- nil means the vault is locked; callers must not substitute a default.
local function scope()
  if not identity.Enabled() then
    local s = getStr(KEY_SHARED)
    if s == nil or s == "" then s = SCOPE_BASE end
    return s
  end
  local id = identity.Get()
  if id == nil then return nil end
  -- an unclaimed base vault locks; only M.ClaimBaseVault assigns an owner
  local owner = getStr(KEY_OWNER)
  if owner == nil or owner == "" then return nil end
  if owner == id then return SCOPE_BASE end
  return id
end

local function readIndex(s)
  local idx = PersistentDB:GetStructuredData(idxKey(s))
  if idx == nil then idx = { nextId = 1 } end
  if idx.categories == nil then idx.categories = {} end
  if idx.ids == nil then idx.ids = {} end
  if idx.order == nil then idx.order = {} end
  return idx
end

local function cacheFor(s)
  if cache == nil or cache.scope ~= s then
    cache = { scope = s, idx = readIndex(s), presets = {} }
  end
  return cache
end

-- Returns the index and its scope, or nil when locked.
local function loadIndex()
  local s = scope()
  if s == nil then return nil end
  rememberLabel(s)
  return cacheFor(s).idx, s
end

local function readPreset(s, id)
  local c = cacheFor(s)
  local p = c.presets[id]
  if p == nil then
    p = PersistentDB:GetStructuredData(presetKey(s, id)) or false
    c.presets[id] = p
  end
  return p or nil
end

-- An id in `ids` with no preset key is skipped, not treated as an error.
local function loadAll()
  local idx, s = loadIndex()
  if idx == nil then return nil, nil, nil end
  local out = {}
  for _, id in ipairs(idx.ids) do
    local p = readPreset(s, id)
    if p ~= nil then out[#out + 1] = p end
  end
  return out, idx, s
end

M.NameOrder = function(a, b)
  local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
  if an ~= bn then return an < bn end
  return a.id < b.id
end

-- A preset absent from idx.order sorts by name, after the ordered ones.
local function resolveOrder(idx, presets)
  local known, out, seen = {}, {}, {}
  for _, p in ipairs(presets) do known[p.id] = true end
  for _, id in ipairs(idx.order) do
    if known[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  local rest = {}
  for _, p in ipairs(presets) do
    if not seen[p.id] then rest[#rest + 1] = p end
  end
  table.sort(rest, M.NameOrder)
  for _, p in ipairs(rest) do out[#out + 1] = p.id end
  return out
end

-- { [presetId] = position }. The resolved order is not saved.
M.PresetOrderIndex = function()
  local presets, idx = loadAll()
  if presets == nil then return {} end
  local index = {}
  for i, id in ipairs(resolveOrder(idx, presets)) do index[id] = i end
  return index
end

-- Dragging down lands after the target, up lands before it; nil goes last.
-- Both indices must be read before the removal to keep that direction.
M.ReorderPreset = function(movedId, targetId)
  if movedId == targetId then return end
  local presets, idx, s = loadAll()
  if presets == nil then return end
  local order = resolveOrder(idx, presets)
  local from, target
  for i, id in ipairs(order) do
    if id == movedId then from = i end
    if id == targetId then target = i end
  end
  if from == nil then return end
  table.remove(order, from)
  table.insert(order, target or (#order + 1), movedId)
  idx.order = order
  writeVerified(idxKey(s), idx)
end

M.Locked = function()
  return scope() == nil
end

-- identity.State(), plus "unclaimed": identified, but the base vault has no
-- owner.
M.IdentityState = function()
  local state = identity.State()
  if state ~= "ready" then return state end
  local owner = getStr(KEY_OWNER)
  if owner == nil or owner == "" then return "unclaimed" end
  return "ready"
end

-- Returns false when the character has no id; the caller must then not
-- enable per-character mode. An existing owner is never overwritten.
M.ClaimBaseVault = function()
  local id = identity.Get()
  if id == nil then return false end
  local owner = getStr(KEY_OWNER)
  if owner == nil or owner == "" then
    setStr(KEY_OWNER, id)
  end
  lastScope = nil
  return true
end

-- An opaque token, compared against M.Vaults()[i].key.
M.CurrentKey = scope

-- The cached records themselves; callers must not edit them.
M.All = function()
  local presets = loadAll()
  return presets or {}
end

-- The preset is written before the index: an orphan key is harmless, a
-- registered id with no data is not.
local function addPreset(p)
  local idx, s = loadIndex()
  if idx == nil then return nil end
  p.id = idx.nextId
  idx.nextId = idx.nextId + 1
  if not writeVerified(presetKey(s, p.id), p) then return nil end
  cacheFor(s).presets[p.id] = p
  idx.ids[#idx.ids + 1] = p.id
  writeVerified(idxKey(s), idx)
  return p
end

-- Returns nil when the vault is locked or the write is rejected.
M.Add = function(capture)
  capture.name = "New Preset"
  return addPreset(capture)
end

-- Returns nil when the vault is locked or the write is rejected.
M.Import = function(preset)
  if type(preset) ~= "table" then return nil end
  local name = M.CleanName(preset.name)
  if name == "" then name = "Untitled" end
  local p = {
    name = name,
    equipment = preset.equipment or {},
    backpack = preset.backpack or {},
  }
  p.icon = M.CleanIcon(preset.icon)
  if preset.bob ~= nil then p.bob = preset.bob end
  return addPreset(p)
end

M.Delete = function(presetId)
  local idx, s = loadIndex()
  if idx == nil then return end
  for i, id in ipairs(idx.ids) do
    if id == presetId then
      table.remove(idx.ids, i)
      break
    end
  end
  for i, id in ipairs(idx.order) do
    if id == presetId then
      table.remove(idx.order, i)
      break
    end
  end
  -- Index first: a deregistered preset key is invisible, an id still listed
  -- with no key is a gap every read has to skip.
  writeVerified(idxKey(s), idx)
  PersistentDB:Delete(presetKey(s, presetId))
  if cache ~= nil and cache.scope == s then cache.presets[presetId] = false end
end

local function editPreset(presetId, fn)
  local s = scope()
  if s == nil then return end
  local p = readPreset(s, presetId)
  if p == nil then return end
  fn(p)
  writeVerified(presetKey(s, presetId), p)
end

M.SetCategory = function(presetId, category)
  editPreset(presetId, function(p)
    p.category = (category ~= nil and category ~= "") and category or nil
  end)
end

-- A nil iconId clears the icon.
M.SetIcon = function(presetId, iconId)
  iconId = M.CleanIcon(iconId)
  editPreset(presetId, function(p) p.icon = iconId end)
end

M.Rename = function(presetId, newName)
  local name = M.CleanName(newName)
  if name == "" then name = "Untitled" end
  editPreset(presetId, function(p) p.name = name end)
end

-- The cached { name, icon? } array in display order; callers must not edit it.
M.Categories = function()
  local idx = loadIndex()
  if idx == nil then return {} end
  return idx.categories
end

-- A nil iconId clears the icon.
M.SetCategoryIcon = function(name, iconId)
  local idx, s = loadIndex()
  if idx == nil then return end
  for _, c in ipairs(idx.categories) do
    if c.name == name then
      c.icon = M.CleanIcon(iconId)
      break
    end
  end
  writeVerified(idxKey(s), idx)
end

-- Same direction rule as M.ReorderPreset; a blank or unknown target means
-- first.
M.ReorderCategory = function(name, targetName)
  if name == targetName then return end
  local idx, s = loadIndex()
  if idx == nil then return end
  local from, target
  for i, c in ipairs(idx.categories) do
    if c.name == name then from = i end
    if c.name == targetName then target = i end
  end
  if from == nil then return end
  local rec = table.remove(idx.categories, from)
  table.insert(idx.categories, target or 1, rec)
  writeVerified(idxKey(s), idx)
end

-- Both positions are resolved before the array is touched: an unknown target
-- must leave the cached index unedited.
M.MoveCategory = function(name, targetName, below)
  if name == targetName then return end
  local idx, s = loadIndex()
  if idx == nil then return end
  local from, to
  for i, c in ipairs(idx.categories) do
    if from == nil and c.name == name then from = i end
    if to == nil and c.name == targetName then to = i end
  end
  if from == nil or to == nil then return end
  local rec = table.remove(idx.categories, from)
  if from < to then to = to - 1 end -- the removal shifted the target up one
  table.insert(idx.categories, below and (to + 1) or to, rec)
  writeVerified(idxKey(s), idx)
end

-- Returns the new category's name, or nil when locked.
M.AddCategory = function()
  local idx, s = loadIndex()
  if idx == nil then return nil end
  local taken = {}
  for _, c in ipairs(idx.categories) do taken[c.name] = true end
  local n, name = 1, "New Category"
  while taken[name] do
    n = n + 1
    name = "New Category " .. n
  end
  table.insert(idx.categories, 1, { name = name })
  writeVerified(idxKey(s), idx)
  return name
end

M.DeleteCategory = function(name)
  local presets, idx, s = loadAll()
  if presets == nil then return end
  for i, c in ipairs(idx.categories) do
    if c.name == name then
      table.remove(idx.categories, i)
      break
    end
  end
  writeVerified(idxKey(s), idx)
  for _, p in ipairs(presets) do
    if p.category == name then
      p.category = nil
      writeVerified(presetKey(s, p.id), p)
    end
  end
end

-- Renaming onto an existing category merges into it; the target takes the
-- source's icon only when it has none.
M.RenameCategory = function(old, new)
  if new == nil then return end
  new = M.CleanName(new)
  if new == "" or new == old then return end
  local presets, idx, s = loadAll()
  if presets == nil then return end
  local from, target
  for i, c in ipairs(idx.categories) do
    if c.name == old then from = i end
    if c.name == new then target = c end
  end
  if from == nil then return end
  if target ~= nil then
    local rec = table.remove(idx.categories, from)
    if target.icon == nil then target.icon = rec.icon end
  else
    idx.categories[from].name = new
  end
  writeVerified(idxKey(s), idx)
  for _, p in ipairs(presets) do
    if p.category == old then
      p.category = new
      writeVerified(presetKey(s, p.id), p)
    end
  end
end

-- { key, label, count } for every vault that holds data, sorted by label.
M.Vaults = function()
  local labels = PersistentDB:GetStructuredData(KEY_LABELS) or {}
  local seen, out = {}, {}
  local function add(s)
    if s == nil or s == "" or seen[s] then return end
    seen[s] = true
    local idx = PersistentDB:GetStructuredData(idxKey(s))
    if idx == nil then return end
    out[#out + 1] = {
      key = s,
      label = labels[s] or "Unknown character",
      count = (idx.ids ~= nil) and #idx.ids or 0,
    }
  end
  add(SCOPE_BASE)
  for s in pairs(labels) do add(s) end
  table.sort(out, function(a, b) return a.label < b.label end)
  return out
end

M.SetSharedVault = function(key)
  if key == nil or key == "" then return end
  setStr(KEY_SHARED, key)
  lastScope = nil
end

-- Returns false when locked.
M.ResetCurrentVault = function()
  local s = scope()
  if s == nil then return false end
  -- the id list must be read before the index is deleted
  local idx = readIndex(s)
  for _, id in ipairs(idx.ids) do
    PersistentDB:Delete(presetKey(s, id))
  end
  PersistentDB:Delete(idxKey(s))
  local labels = PersistentDB:GetStructuredData(KEY_LABELS)
  if labels ~= nil then
    labels[s] = nil
    PersistentDB:SetStructuredData(KEY_LABELS, labels)
  end
  lastScope = nil
  cache = nil
  return true
end

return M
