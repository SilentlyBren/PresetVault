-- Preset persistence, and the vault-selection layer that decides WHICH
-- stored vault is the current one.
--
-- STORAGE LAYOUT - a small index plus ONE KEY PER PRESET. PersistentDB
-- discards any value at or above 131,072 bytes, so the split keeps every
-- stored value bounded by a single preset's contents rather than letting one
-- blob grow with the whole vault. A vault is therefore not one key:
--
--   vault.v1.<scope>.idx     { nextId, categories = {{name, icon?}, ...},
--                              order = { presetId, ... },   -- manual arrangement
--                              ids   = { presetId, ... } }  -- what exists
--   vault.v1.<scope>.p<id>   { id, name, category?, icon?,
--                              equipment = {entry...}, backpack = {entry...},
--                              bob? = { size, items = {entry...} } }
--                              entry = { slot, obj, count, name }
--
-- `<scope>` is "base" for the original vault, or the character's tracking
-- ID. Which scope is read depends on the Multi-character setting:
--   off (default) : one shared vault, `vault.sharedScope`, default "base".
--   on            : one vault per character. The claiming character keeps
--                   "base"; everyone else gets their tracking ID.
--
-- Vault data is NEVER copied or moved between scopes - toggling the setting
-- only changes which scope is read.
--
local identity = require("core/identity")

local M = {}

local PREFIX = "vault.v1"            -- all vault data lives under this
local SCOPE_BASE = "base"            -- the original vault; also character 1's
local KEY_SHARED = "vault.sharedScope" -- which scope shared mode reads
local KEY_OWNER = "vault.baseOwner"  -- tracking ID that claimed SCOPE_BASE
local KEY_LABELS = "vault.labels"    -- { [scope] = displayName } for the UI
local MAX_NAME = 25 -- UI input fields enforce this too; clamp here as backstop

local lastScope = nil -- avoids rewriting the label table on every single read

local function idxKey(scope) return PREFIX .. "." .. scope .. ".idx" end
local function presetKey(scope, id) return PREFIX .. "." .. scope .. ".p" .. id end

-- ===========================================================================
-- Verified writes
-- ===========================================================================

-- Writes a table and proves it landed. PersistentDB discards a value at or
-- above 131,072 bytes and still reports success, so a write that did nothing
-- is otherwise indistinguishable from one that worked. `rev` is bumped on
-- every write and compared on read-back: a structural check would not do,
-- since a rejected write leaves the PREVIOUS value in place and a rename
-- changes no counts.
local function writeVerified(key, tbl)
  tbl.rev = (tbl.rev or 0) + 1
  PersistentDB:SetStructuredData(key, tbl)
  local back = PersistentDB:GetStructuredData(key)
  if back ~= nil and back.rev == tbl.rev then return true end
  log(formatStr("[PV] SAVE FAILED for {} - value rejected (128 KiB ceiling?)",
    tostring(key)))
  return false
end

-- ===========================================================================
-- Scope selection
-- ===========================================================================

-- Records the current character's display name against its scope, so the
-- vault picker can read "Zezima (12 presets)" instead of a 64-bit number.
-- Per-character mode only.
local function rememberLabel(scope)
  if scope == lastScope then return end
  if not identity.Enabled() then return end
  local name = identity.DisplayName()
  -- Bail before latching lastScope if the name is not readable yet, so a
  -- later attempt still gets the chance to record it.
  if name == nil then return end
  lastScope = scope
  local labels = PersistentDB:GetStructuredData(KEY_LABELS) or {}
  if labels[scope] == name then return end
  labels[scope] = name
  PersistentDB:SetStructuredData(KEY_LABELS, labels)
end

-- The scope the vault currently reads and writes, or nil when locked.
local function scope()
  if not identity.Enabled() then
    local s = PersistentDB:GetString(KEY_SHARED)
    if s == nil or s == "" then s = SCOPE_BASE end
    return s
  end
  local id = identity.Get()
  if id == nil then return nil end
  -- An unclaimed base vault LOCKS; ownership is only ever claimed by
  -- M.ClaimBaseVault, when the user turns Multi-character on.
  local owner = PersistentDB:GetString(KEY_OWNER)
  if owner == nil or owner == "" then return nil end
  if owner == id then return SCOPE_BASE end
  return id
end

-- ===========================================================================
-- Index and preset I/O
-- ===========================================================================

local function readIndex(s)
  local idx = PersistentDB:GetStructuredData(idxKey(s))
  if idx == nil then idx = { nextId = 1 } end
  if idx.categories == nil then idx.categories = {} end
  if idx.ids == nil then idx.ids = {} end
  if idx.order == nil then idx.order = {} end
  return idx
end

-- The current vault's index, or nil when locked. Also the one place that
-- refreshes the display label, so it sits on every read path.
local function loadIndex()
  local s = scope()
  if s == nil then return nil end
  rememberLabel(s)
  return readIndex(s), s
end

local function readPreset(s, id)
  return PersistentDB:GetStructuredData(presetKey(s, id))
end

-- Every preset in the vault, in `ids` order. The only full fan-out read -
-- and the UI wants all of them whenever it calls this, so there is nothing
-- to save by being lazier.
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

-- ===========================================================================
-- Ordering
-- ===========================================================================

-- Alphabetical preset order with an id tie-break - the sort every list
-- falls back to when a preset has no manual position.
M.NameOrder = function(a, b)
  local an, bn = string.lower(a.name or ""), string.lower(b.name or "")
  if an ~= bn then return an < bn end
  return a.id < b.id
end

-- Resolves the vault's manual arrangement into a clean id list: stored
-- order first, then anything missing appended alphabetically, with ids of
-- deleted presets dropped. Needs the presets themselves for the
-- alphabetical tail, hence the argument.
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

-- Position lookup for sorting: { [presetId] = index }.
M.PresetOrderIndex = function()
  local presets, idx = loadAll()
  if presets == nil then return {} end
  local index = {}
  for i, id in ipairs(resolveOrder(idx, presets)) do index[id] = i end
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

-- ===========================================================================
-- Lock state and ownership
-- ===========================================================================

-- True while per-character mode is waiting on, or has failed to get, an
-- identity.
M.Locked = function()
  return scope() == nil
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
  lastScope = nil -- the scope is about to change; relabel on the next read
  return true
end

-- An opaque token identifying the current vault, for comparison against
-- M.Vaults()[i].key. Only ui/settings uses it, for the shared-vault picker.
M.CurrentKey = scope

-- ===========================================================================
-- Presets
-- ===========================================================================

M.All = function()
  local presets = loadAll()
  return presets or {}
end

-- Appends a preset record and registers it in the index. Two small writes
-- (the preset, then the index) instead of rewriting the whole vault.
local function addPreset(p)
  local idx, s = loadIndex()
  if idx == nil then return nil end
  p.id = idx.nextId
  idx.nextId = idx.nextId + 1
  if not writeVerified(presetKey(s, p.id), p) then return nil end
  idx.ids[#idx.ids + 1] = p.id
  writeVerified(idxKey(s), idx)
  return p
end

-- Stores a fresh snapshot capture under a new id and default name.
M.Add = function(capture)
  capture.name = "New Preset"
  return addPreset(capture)
end

-- Stores a preset decoded from someone else's share code, keeping the
-- sender's name and icon. Always lands in Uncategorised - share codes
-- carry no category. Returns the stored preset, or nil when the vault is
-- locked.
M.Import = function(preset)
  if type(preset) ~= "table" then return nil end
  local p = {
    name = string.sub(tostring(preset.name or "Untitled"), 1, MAX_NAME),
    equipment = preset.equipment or {},
    backpack = preset.backpack or {},
  }
  if preset.icon ~= nil then p.icon = preset.icon end
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
  -- Index first here: a surviving preset key whose id is deregistered is
  -- invisible, whereas a deleted key still listed in `ids` would be a gap
  -- loadAll has to skip on every read.
  writeVerified(idxKey(s), idx)
  PersistentDB:Delete(presetKey(s, presetId))
end

-- Mutates one preset in place: read its key, apply `fn`, write it back.
-- The index is not touched, so these are the cheapest writes in the module.
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

-- Sets the sprite id shown beside the preset's name; nil clears it.
M.SetIcon = function(presetId, iconId)
  editPreset(presetId, function(p) p.icon = iconId end)
end

M.Rename = function(presetId, newName)
  editPreset(presetId, function(p)
    p.name = string.sub(newName, 1, MAX_NAME)
  end)
end

-- ===========================================================================
-- Categories (index only, except where preset.category must follow)
-- ===========================================================================

-- The category records ({name, icon?}), in display order.
M.Categories = function()
  local idx = loadIndex()
  if idx == nil then return {} end
  return idx.categories
end

-- Sets the sprite id shown on the category's header; nil clears it.
M.SetCategoryIcon = function(name, iconId)
  local idx, s = loadIndex()
  if idx == nil then return end
  for _, c in ipairs(idx.categories) do
    if c.name == name then
      c.icon = iconId
      break
    end
  end
  writeVerified(idxKey(s), idx)
end

-- Drops `name` onto `targetName`: dragging DOWN lands after the target,
-- dragging UP lands before it. A blank or unknown target means first - a
-- drop on the pinned Uncategorised section.
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

-- Moves `name` to sit directly above or below `targetName` - the explicit
-- form menu-driven reordering needs, where there is no drag direction to
-- infer from.
M.MoveCategory = function(name, targetName, below)
  if name == targetName then return end
  local idx, s = loadIndex()
  if idx == nil then return end
  local from
  for i, c in ipairs(idx.categories) do
    if c.name == name then
      from = i
      break
    end
  end
  if from == nil then return end
  local rec = table.remove(idx.categories, from)
  local to = nil
  for i, c in ipairs(idx.categories) do
    if c.name == targetName then
      to = i
      break
    end
  end
  if to == nil then return end -- unknown target: the local copy is discarded
  table.insert(idx.categories, below and (to + 1) or to, rec)
  writeVerified(idxKey(s), idx)
end

-- Creates an empty category with a unique placeholder name and returns it.
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

-- Removes the category; its presets fall back to Uncategorised.
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

-- Renames a category across the stored list and every preset using it.
-- Renaming onto an existing category MERGES into it: the target record
-- survives, adopting the source's icon only when it has none of its own.
M.RenameCategory = function(old, new)
  if new == nil or new == "" or new == old then return end
  new = string.sub(new, 1, MAX_NAME)
  if new == old then return end
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

-- ===========================================================================
-- Vault management (settings panel)
-- ===========================================================================

-- Every vault that holds data, as { key, label, count }, label-sorted.
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

-- Picks which vault shared mode reads. Moves no data, so the others stay
-- dormant and intact.
M.SetSharedVault = function(key)
  if key == nil or key == "" then return end
  PersistentDB:SetString(KEY_SHARED, key)
  lastScope = nil
end

-- Wipes the vault in use - this character's, or the shared one. Other
-- characters' vaults and all settings survive.
M.ResetCurrentVault = function()
  local s = scope()
  if s == nil then return false end
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
  return true
end

return M
