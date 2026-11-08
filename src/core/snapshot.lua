-- Captures the player's current worn equipment, backpack, and - when a Beast
-- of Burden familiar is carrying anything - its inventory, as preset data.
local M = {}

local INV_BACKPACK = 93
local INV_EQUIPMENT = 94
local INV_BOB = 530 -- LORE_BOB: BoB familiar storage (fixed 32-slot container)
local INV_BANK = 95
local BOB_MAX = 32 -- engine max BoB capacity (pack mammoth)
local BOB_SLOTS_COMPONENT = 517 * 65536 + 34 -- BANK__BOB_SLOTS (bank interface)

-- The familiar's burden capacity, straight from the game's own config: the
-- pouch names its familiar, and the familiar carries its storage space.
-- Returns nil if any link in that chain is unavailable.
local function capacityFromConfig(pouchObjId)
  local cap = nil
  pcall(function()
    local pouch = config.Obj.FromID(pouchObjId)
    if pouch == nil then return end
    local npc = pouch:GetParamValue(config.Param.FOLLOWER_NPC)
    if npc == nil then return end
    if type(npc) == "number" then npc = config.NPC.FromID(npc) end
    if npc == nil then return end
    local n = npc:GetParamValue(config.Param.LORE_STORAGE_SPACE)
    if type(n) == "number" and n >= 1 and n <= BOB_MAX then cap = n end
  end)
  return cap
end

-- Filled slots as { slot, obj, count, name }; nil if the inventory is not
-- readable. Names are captured here so display never needs a config lookup.
local function captureInv(invId)
  local inv = Inventory.Find(invId)
  local slots = inv and inv:GetSlots()
  if slots == nil then return nil end
  local out = {}
  for i, slot in pairs(slots) do
    local o = slot.obj
    if o ~= nil and o.id ~= nil and o.id >= 0 and (slot.count or 0) > 0 then
      out[#out + 1] = { slot = i, obj = o.id, count = slot.count, name = tostring(o.name) }
    end
  end
  return out
end

-- The summoned familiar's pouch obj id, or nil when none is out.
local function followerObjId()
  local objId = nil
  pcall(function()
    local v = var.VarPlayer["FOLLOWER_OBJ"].value
    if type(v) == "number" then
      objId = v
    else
      objId = v.id -- the var carries an Obj config
    end
  end)
  if objId == nil or objId < 0 then return nil end
  return objId
end

-- The familiar's burden capacity, in descending order of trust: the game's
-- own config, the native BoB panel's child count, the highest filled slot,
-- then BOB_MAX.
local function bobCapacity(items)
  local objId = followerObjId()
  if objId ~= nil then
    local fromConfig = capacityFromConfig(objId)
    if fromConfig ~= nil then return fromConfig end
    local fromPanel = nil
    pcall(function()
      local bankInv = Inventory.Find(INV_BANK)
      if bankInv == nil or bankInv:GetSlots() == nil then return end -- bank closed
      local comp = ui.Interfaces:GetComponent(BOB_SLOTS_COMPONENT)
      if comp == nil then return end
      local n = 0
      comp:IterateDynamicComponents(function() n = n + 1 end)
      if n >= 1 and n <= BOB_MAX then fromPanel = n end
    end)
    if fromPanel ~= nil then return fromPanel end
  end
  local highest = 0
  for _, e in ipairs(items) do
    if e.slot ~= nil and e.slot > highest then highest = e.slot end
  end
  if highest >= 1 and highest <= BOB_MAX then return highest end
  return BOB_MAX
end

-- Captures all three containers into preset data. nil if equipment or
-- backpack is unreadable; the BoB section is present only when the familiar
-- is actually carrying something.
M.Capture = function()
  local equipment = captureInv(INV_EQUIPMENT)
  local backpack = captureInv(INV_BACKPACK)
  if equipment == nil or backpack == nil then return nil end
  local bob = nil
  local bobItems = captureInv(INV_BOB)
  if bobItems ~= nil and #bobItems > 0 then
    bob = { size = bobCapacity(bobItems), items = bobItems }
  end
  return { equipment = equipment, backpack = backpack, bob = bob }
end

return M
