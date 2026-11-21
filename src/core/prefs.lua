-- The plugin's on/off settings, read from PersistentDB once and then served
-- from memory. Every flag read and write in the plugin goes through here.
local M = {}

local NONE = {} -- marks a key the DB holds no value for
local known = {}

M.GetBool = function(key)
  local v = known[key]
  if v == nil then
    v = PersistentDB:GetBool(key)
    if v == nil then v = NONE end
    known[key] = v
  end
  if v == NONE then return nil end
  return v
end

M.SetBool = function(key, value)
  PersistentDB:SetBool(key, value)
  known[key] = nil
end

M.Invalidate = function()
  known = {}
end

return M
