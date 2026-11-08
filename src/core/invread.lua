-- Shared inventory readers. Ids: 93 backpack, 94 worn, 95 bank, 530 BoB.
local M = {}

-- Total units per obj id in an inventory.
M.CountInv = function(invId)
  local counts = {}
  pcall(function()
    local inv = Inventory.Find(invId)
    local slots = inv and inv:GetSlots()
    if slots == nil then return end
    for _, slot in pairs(slots) do
      local o = slot.obj
      if o ~= nil and o.id ~= nil and o.id >= 0 then
        counts[o.id] = (counts[o.id] or 0) + (slot.count or 0)
      end
    end
  end)
  return counts
end

-- Per-slot contents: { [slot] = { obj, count } }.
M.Slots = function(invId)
  local held = {}
  pcall(function()
    local inv = Inventory.Find(invId)
    local slots = inv and inv:GetSlots()
    if slots == nil then return end
    for slotId, slot in pairs(slots) do
      local o = slot.obj
      local s = tonumber(slotId)
      if s ~= nil and o ~= nil and o.id ~= nil and o.id >= 0 then
        held[s] = { obj = o.id, count = slot.count or 1 }
      end
    end
  end)
  return held
end

-- What the player holds, per container, keyed by preset section name.
M.Carried = function()
  return { backpack = M.CountInv(93), equipment = M.CountInv(94),
    bob = M.CountInv(530) }
end

return M
