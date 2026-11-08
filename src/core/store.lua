-- Preset persistence, and the vault-selection layer that decides WHICH
-- stored vault is the current one.
--
-- A vault is one PersistentDB key holding:
--   { nextId, presets = { {id, name, category?, icon?, equipment, backpack,
--     bob?} }, categories = { {name, icon?}, ... }, order = { presetId, ... } }
--
-- Which key is read depends on the Multi-character setting:
--   off (default) : one shared vault, `vault.sharedKey`, defaulting to the
--                   original `vault.v1`.
--   on            : one vault per character, keyed by tracking ID. The
--                   claiming character keeps `vault.v1` itself; everyone
--                   else gets `vault.v1.<id>`.
--
-- Vault data is NEVER copied or moved between keys - toggling the setting
-- only changes which key is read.
local identity = require("core/identity")

local M = {}

local KEY_BASE = "vault.v1"          -- the original vault; also character 1's
local KEY_SHARED = "vault.sharedKey" -- which vault shared mode reads
local KEY_OWNER = "vault.baseOwner"  -- tracking ID that claimed KEY_BASE
local KEY_LABELS = "vault.labels"    -- { [vaultKey] = displayName } for the UI
local MAX_NAME = 25 -- UI input fields enforce this too; clamp here as backstop

local lastKey = nil -- avoids rewriting the label table on every single read

-- Records the current character's display name against its vault key, so the
-- vault picker can read "Zezima (12 presets)" instead of a 64-bit number.
-- Per-character mode only.
local function rememberLabel(key)
  if key == lastKey then return end
  if not identity.Enabled() then return end
  local name = identity.DisplayName()
  -- Bail before latching lastKey if the name is not readable yet, so a
  -- later attempt still gets the chance to record it.
  if name == nil then return end
  lastKey = key
  local labels = PersistentDB:GetStructuredData(KEY_LABELS) or {}
  if labels[key] == name then return end
  labels[key] = name
  PersistentDB:SetStructuredData(KEY_LABELS, labels)
end

-- The key the vault currently reads and writes, or nil when locked.
local function vaultKey()
  if not identity.Enabled() then
    local key = PersistentDB:GetString(KEY_SHARED)
    if key == nil or key == "" then key = KEY_BASE end
    return key
  end
  local id = identity.Get()
  if id == nil then return nil end
  -- An unclaimed base vault LOCKS; ownership is only ever claimed by
  -- M.ClaimBaseVault, when the user turns Multi-character on.
  local owner = PersistentDB:GetString(KEY_OWNER)
  if owner == nil or owner == "" then return nil end
  if owner == id then return KEY_BASE end
  return KEY_BASE .. "." .. id
end

local function load()
  local key = vaultKey()
  if key == nil then return nil end
  rememberLabel(key)
  local data = PersistentDB:GetStructuredData(key) or { nextId = 1, presets = {} }
  if data.categories == nil then data.categories = {} end
  return data
end

local function save(data)
  local key = vaultKey()
  if key == nil then return end -- locked: never guess which vault to write
  PersistentDB:SetStructuredData(key, data)
end

-- Alphabetical preset order with an id tie-break - the sort every list
-- falls back to when a preset has no manual position.
M.NameOrder = function(a, b)
  local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
  if an ~= bn then return an < bn end
  return a.id < b.id
end

-- Resolves the vault's manual preset arrangement into a clean id list:
-- stored order first, then anything missing appended alphabetically, with
-- ids of deleted presets dropped.
local function ensureOrder(data)
  local known, out, seen = {}, {}, {}
  for _, p in ipairs(data.presets) do known[p.id] = true end
  for _, id in ipairs(data.order or {}) do
    if known[id] and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  local rest = {}
  for _, p in ipairs(data.presets) do
    if not seen[p.id] then rest[#rest + 1] = p end
  end
  table.sort(rest, M.NameOrder)
  for _, p in ipairs(rest) do out[#out + 1] = p.id end
  data.order = out
  return out
end

-- Position lookup for sorting: { [presetId] = index }.
M.PresetOrderIndex = function()
  local data = load()
  if data == nil then return {} end
  local index = {}
  for i, id in ipairs(ensureOrder(data)) do index[id] = i end
  return index
end

-- Drops `movedId` onto `targetId`: dragging DOWN lands after the target,
-- dragging UP lands before it. A nil target goes to the end.
--
-- Both indices are read BEFORE the removal, which is what preserves the
-- direction: removing `from` shifts a later target down one, so "after the
-- target" and "before the target" both collapse to `target`.
M.ReorderPreset = function(movedId, targetId)
  if movedId == targetId then return end
  local data = load()
  if data == nil then return end
  local order = ensureOrder(data)
  local from, target
  for i, id in ipairs(order) do
    if id == movedId then from = i end
    if id == targetId then target = i end
  end
  if from == nil then return end
  table.remove(order, from)
  table.insert(order, target or (#order + 1), movedId)
  save(data)
end

-- True while per-character mode is waiting on, or has failed to get, an
-- identity.
M.Locked = function()
  return vaultKey() == nil
end

-- identity.State, plus the one condition only the store can see:
-- "unclaimed" - identified fine, but nobody owns the base vault.
M.IdentityState = function()
  local state = identity.State()
  if state ~= "ready" then return state end
  local owner = PersistentDB:GetString(KEY_OWNER)
  if owner == nil or owner == "" then return "unclaimed" end
  return "ready"
end

-- Binds the existing vault to the current character. Returns false when the
-- character cannot be identified, in which case the caller MUST NOT enable
-- the setting. An existing owner is never overwritten.
M.ClaimBaseVault = function()
  local id = identity.Get()
  if id == nil then return false end
  local owner = PersistentDB:GetString(KEY_OWNER)
  if owner == nil or owner == "" then
    PersistentDB:SetString(KEY_OWNER, id)
  end
  lastKey = nil -- the vault key is about to change; relabel on the next read
  return true
end

M.CurrentKey = vaultKey

M.All = function()
  local data = load()
  if data == nil then return {} end
  return data.presets
end

-- Stores a fresh snapshot capture under a new id and default name.
M.Add = function(capture)
  local data = load()
  if data == nil then return nil end
  capture.id = data.nextId
  capture.name = "New Preset"
  data.nextId = data.nextId + 1
  data.presets[#data.presets + 1] = capture
  save(data)
  return capture
end

-- Stores a preset decoded from someone else's share code, keeping the
-- sender's name and icon. Always lands in Uncategorised - share codes
-- carry no category. Returns the stored preset, or nil when the vault is
-- locked.
M.Import = function(preset)
  if type(preset) ~= "table" then return nil end
  local data = load()
  if data == nil then return nil end

  local p = {
    id = data.nextId,
    name = string.sub(tostring(preset.name or "Untitled"), 1, MAX_NAME),
    equipment = preset.equipment or {},
    backpack = preset.backpack or {},
  }
  if preset.icon ~= nil then p.icon = preset.icon end
  if preset.bob ~= nil then p.bob = preset.bob end

  data.nextId = data.nextId + 1
  data.presets[#data.presets + 1] = p
  save(data)
  return p
end

M.Delete = function(presetId)
  local data = load()
  if data == nil then return end
  for i, p in ipairs(data.presets) do
    if p.id == presetId then
      table.remove(data.presets, i)
      break
    end
  end
  save(data)
end

M.SetCategory = function(presetId, category)
  local data = load()
  if data == nil then return end
  for _, p in ipairs(data.presets) do
    if p.id == presetId then
      p.category = (category ~= nil and category ~= "") and category or nil
      break
    end
  end
  save(data)
end

-- Sets the sprite id shown beside the preset's name; nil clears it.
M.SetIcon = function(presetId, iconId)
  local data = load()
  if data == nil then return end
  for _, p in ipairs(data.presets) do
    if p.id == presetId then
      p.icon = iconId
      break
    end
  end
  save(data)
end

-- Sets the sprite id shown on the category's header; nil clears it.
M.SetCategoryIcon = function(name, iconId)
  local data = load()
  if data == nil then return end
  for _, c in ipairs(data.categories) do
    if c.name == name then
      c.icon = iconId
      break
    end
  end
  save(data)
end

-- The category records ({name, icon?}), in display order.
M.Categories = function()
  local data = load()
  if data == nil then return {} end
  return data.categories
end

-- Drops `name` onto `targetName`: dragging DOWN lands after the target,
-- dragging UP lands before it. A blank or unknown target means first - a
-- drop on the pinned Uncategorised section.
--
-- Both indices are read BEFORE the removal, which is what preserves the
-- direction: removing `from` shifts a later target down one, so "after the
-- target" and "before the target" both collapse to `target`.
M.ReorderCategory = function(name, targetName)
  if name == targetName then return end
  local data = load()
  if data == nil then return end
  local from, target
  for i, c in ipairs(data.categories) do
    if c.name == name then from = i end
    if c.name == targetName then target = i end
  end
  if from == nil then return end
  local rec = table.remove(data.categories, from)
  table.insert(data.categories, target or 1, rec)
  save(data)
end

-- Moves `name` to sit directly above or below `targetName` - the explicit
-- form menu-driven reordering needs, where there is no drag direction to
-- infer from.
M.MoveCategory = function(name, targetName, below)
  if name == targetName then return end
  local data = load()
  if data == nil then return end
  local from
  for i, c in ipairs(data.categories) do
    if c.name == name then
      from = i
      break
    end
  end
  if from == nil then return end
  local rec = table.remove(data.categories, from)
  local to = nil
  for i, c in ipairs(data.categories) do
    if c.name == targetName then
      to = i
      break
    end
  end
  if to == nil then return end -- unknown target: the local copy is discarded
  table.insert(data.categories, below and (to + 1) or to, rec)
  save(data)
end

-- Creates an empty category with a unique placeholder name and returns it.
M.AddCategory = function()
  local data = load()
  if data == nil then return nil end
  local taken = {}
  for _, c in ipairs(data.categories) do taken[c.name] = true end
  local n, name = 1, "New Category"
  while taken[name] do
    n = n + 1
    name = "New Category " .. n
  end
  table.insert(data.categories, 1, { name = name })
  save(data)
  return name
end

-- Removes the category; its presets fall back to Uncategorised.
M.DeleteCategory = function(name)
  local data = load()
  if data == nil then return end
  for i, c in ipairs(data.categories) do
    if c.name == name then
      table.remove(data.categories, i)
      break
    end
  end
  for _, p in ipairs(data.presets) do
    if p.category == name then p.category = nil end
  end
  save(data)
end

-- Renames a category across the stored list and every preset using it.
-- Renaming onto an existing category MERGES into it: the target record
-- survives, adopting the source's icon only when it has none of its own.
M.RenameCategory = function(old, new)
  if new == nil or new == "" or new == old then return end
  new = string.sub(new, 1, MAX_NAME)
  if new == old then return end
  local data = load()
  if data == nil then return end
  local from, target
  for i, c in ipairs(data.categories) do
    if c.name == old then from = i end
    if c.name == new then target = c end
  end
  if from == nil then return end
  if target ~= nil then
    local rec = table.remove(data.categories, from)
    if target.icon == nil then target.icon = rec.icon end
  else
    data.categories[from].name = new
  end
  for _, p in ipairs(data.presets) do
    if p.category == old then p.category = new end
  end
  save(data)
end

M.Rename = function(presetId, newName)
  local data = load()
  if data == nil then return end
  for _, p in ipairs(data.presets) do
    if p.id == presetId then
      p.name = string.sub(newName, 1, MAX_NAME)
      break
    end
  end
  save(data)
end

-- ===========================================================================
-- Vault management (settings panel)
-- ===========================================================================

-- Every vault that holds data, as { key, label, count }, label-sorted.
M.Vaults = function()
  local labels = PersistentDB:GetStructuredData(KEY_LABELS) or {}
  local seen, out = {}, {}
  local function add(key)
    if key == nil or key == "" or seen[key] then return end
    seen[key] = true
    local data = PersistentDB:GetStructuredData(key)
    if data == nil then return end
    out[#out + 1] = {
      key = key,
      label = labels[key] or "Unknown character",
      count = (data.presets ~= nil) and #data.presets or 0,
    }
  end
  add(KEY_BASE)
  for key in pairs(labels) do add(key) end
  table.sort(out, function(a, b) return a.label < b.label end)
  return out
end

-- Picks which vault shared mode reads. Moves no data, so the others stay
-- dormant and intact.
M.SetSharedVault = function(key)
  if key == nil or key == "" then return end
  PersistentDB:SetString(KEY_SHARED, key)
  lastKey = nil
end

-- Wipes the vault in use - this character's, or the shared one. Other
-- characters' vaults and all settings survive.
M.ResetCurrentVault = function()
  local key = vaultKey()
  if key == nil then return false end
  PersistentDB:Delete(key)
  local labels = PersistentDB:GetStructuredData(KEY_LABELS)
  if labels ~= nil then
    labels[key] = nil
    PersistentDB:SetStructuredData(KEY_LABELS, labels)
  end
  lastKey = nil
  return true
end

return M
