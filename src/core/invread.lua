-- Shared inventory readers. Ids: 93 backpack, 94 worn, 95 bank, 530 BoB.
-- An unreadable inventory reads as empty.
local M = {}

-- { [objId] = total units }
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

-- { [slot] = { obj, count } }
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

-- Keyed by preset section name; the three containers stay separate.
M.Carried = function()
  return { backpack = M.CountInv(93), equipment = M.CountInv(94),
    bob = M.CountInv(530) }
end

return M
