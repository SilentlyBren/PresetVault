-- Character identity for per-character vaults, from
-- `Player.GetTrackingID()`. The id is used only as a local PersistentDB key
-- suffix.
local M = {}
local prefs = require("core/prefs")

-- counted in Update() calls, not ticks
local RESOLVE_TIMEOUT = 300

local cached = nil -- decimal string
local waited = 0

M.HasPermission = function()
  local ok, has = pcall(function()
    return Plugin.HasPermission(PluginPermissions.trackingAccess) == true
  end)
  return ok and has == true
end

M.Enabled = function()
  return prefs.GetBool("vault.multiChar") == true
end

-- Anything but a plain integer reads as unresolved, which locks the vault
-- instead of keying it off a value in an unknown format.
local function readId()
  local ok, value = pcall(function() return Player.GetTrackingID() end)
  if not ok or value == nil then return nil end
  if math.type(value) ~= "integer" then return nil end
  return tostring(value)
end

M.Update = function()
  if cached ~= nil then return end
  if not M.HasPermission() then
    waited = 0
    return
  end
  local id = readId()
  if id ~= nil then
    cached = id
    return
  end
  waited = waited + 1
end

M.Forget = function()
  cached = nil
  waited = 0
end

-- Returns "off", "ready", "nopermission", "resolving" or "unavailable".
M.State = function()
  if not M.Enabled() then return "off" end
  if cached ~= nil then return "ready" end
  if not M.HasPermission() then return "nopermission" end
  if waited >= RESOLVE_TIMEOUT then return "unavailable" end
  return "resolving"
end

-- nil means the id is not known yet; callers must wait, not fall back.
M.Get = function()
  return cached
end

-- A UI label only, never a key. nil when not readable.
M.DisplayName = function()
  local name
  pcall(function() name = PlayerList.Self().displayName end)
  if name == nil or name == "" then return nil end
  return tostring(name)
end

return M
