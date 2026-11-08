-- Character identity for per-character vaults, from
-- `Player.GetTrackingID()`.
--
-- The ID is used only as a local PersistentDB key suffix. It is never shown
-- to the user, written into a preset, or transmitted anywhere.
local M = {}

local RESOLVE_TIMEOUT = 600

local cached = nil -- resolved id, as a decimal string
local waited = 0   -- Update() calls spent waiting for the id this session

M.HasPermission = function()
  local ok, has = pcall(function()
    return Plugin.HasPermission(PluginPermissions.trackingAccess) == true
  end)
  return ok and has == true
end

-- True when the user has asked for per-character vaults.
M.Enabled = function()
  return PersistentDB:GetBool("vault.multiChar") == true
end

-- The id arrives as a plain Lua integer; its decimal form is the key
-- suffix. Anything else reads as "not resolved", which locks the vault
-- rather than keying it off a guessed value.
local function readId()
  local ok, value = pcall(function() return Player.GetTrackingID() end)
  if not ok or value == nil then return nil end
  if math.type(value) ~= "integer" then return nil end
  return tostring(value)
end

-- Polls for the ID until it arrives. Cheap once resolved, and safe to call
-- when the feature is off or unpermitted.
M.Update = function()
  if cached ~= nil then return end
  if not M.HasPermission() then
    waited = 0 -- a later grant starts its wait from scratch
    return
  end
  local id = readId()
  if id ~= nil then
    cached = id
    return
  end
  waited = waited + 1
end

-- Drops the cached ID. Called on logout and on any permission change.
M.Forget = function()
  cached = nil
  waited = 0
end

-- "off"           - per-character vaults disabled; the shared vault is in use
-- "ready"         - ID resolved, M.Get() is safe
-- "nopermission"  - enabled, but trackingAccess was not granted
-- "resolving"     - enabled and permitted, ID not transmitted yet (post-login)
-- "unavailable"   - enabled and permitted, but the ID never arrived
M.State = function()
  if not M.Enabled() then return "off" end
  if cached ~= nil then return "ready" end
  if not M.HasPermission() then return "nopermission" end
  if waited >= RESOLVE_TIMEOUT then return "unavailable" end
  return "resolving"
end

-- The resolved tracking ID, or nil when it is not known yet.
M.Get = function()
  return cached
end

-- The current character's display name. A UI label only, never a key.
M.DisplayName = function()
  local name
  pcall(function() name = PlayerList.Self().displayName end)
  if name == nil or name == "" then return nil end
  return tostring(name)
end

return M
