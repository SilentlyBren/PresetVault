-- Bank Core integration: finds the optional `bankcore` plugin, keeps the
-- extension registered, and opens and closes the preset view that Core
-- draws through ui/bupage.
local M = {}
local prefs = require("core/prefs")

local EXT_ID = "presetvault"
local EXT_NAME = "Preset Vault"
local ICON_SPRITE = 18733 -- CHILD_HEADER_ICON_WORN
local ICON_FALLBACK = "OUTFIT" -- for a Core that refuses numeric icons

local ext = nil
local extHasColumn = false
-- __bankcore_api as of the last Connect; a different table means Core reloaded
local sharedAtConnect = nil
local activeId = nil
local activePreset = nil

M.OnViewChanged = nil -- hook, fired after the view opens or closes

local function fireViewChanged()
  if M.OnViewChanged then pcall(M.OnViewChanged) end
end

-- { draw, stop }, injected by main.lua before Connect
local viewProvider = nil
M.SetViewProvider = function(callbacks)
  viewProvider = callbacks
end

local function clearActive()
  -- stop runs before the early return: the live layer dies even with no view recorded
  if viewProvider ~= nil then pcall(viewProvider.stop) end
  if activeId == nil then return end
  activeId, activePreset = nil, nil
  fireViewChanged()
end

local function injectedAPI()
  return rawget(_G, "bankcore")
end

local function sharedAPI()
  return rawget(_G, "__bankcore_api")
end

M.CoreDetected = function()
  return injectedAPI() ~= nil or sharedAPI() ~= nil
end

M.Enabled = function()
  return prefs.GetBool("ui.bankUtilOff") ~= true
end

M.IsActive = function()
  return ext ~= nil
end

-- { mount, resize, unmount }, injected by main.lua before Connect
local columnProvider = nil
M.SetColumnProvider = function(callbacks)
  columnProvider = callbacks
end

local function registrationSpec(icon)
  return {
    id = EXT_ID,
    name = EXT_NAME,
    icon = icon,
    -- Core refuses a column without an icon
    column = (icon ~= nil) and columnProvider or nil,
    customView = (viewProvider ~= nil)
      and function(view) return viewProvider.draw(view) end or nil,
    onClose = function() clearActive() end,
    onBankClose = function() clearActive() end,
  }
end

-- Returns the handle and whether the registration carries the column. An
-- icon Core cannot accept fails the whole registration with "invalid"; only
-- that reason is worth retrying with another icon.
local function tryRegister(core)
  if core == nil or type(core.Register) ~= "function" then return nil, false end
  for _, icon in ipairs({ ICON_SPRITE, ICON_FALLBACK }) do
    local handle, reason = nil, nil
    pcall(function() handle, reason = core.Register(registrationSpec(icon)) end)
    if handle ~= nil then
      if icon ~= ICON_SPRITE then
        log(formatStr("[PV Bankcore] rail icon fell back to {}", icon))
      end
      return handle, columnProvider ~= nil
    end
    if reason ~= "invalid" then return nil, false end
  end
  local handle = nil
  pcall(function() handle = core.Register(registrationSpec(nil)) end)
  if handle ~= nil then log("[PV Bankcore] registered without a rail icon") end
  return handle, false
end

M.Disconnect = function()
  if ext ~= nil then
    local handle = ext
    ext = nil
    extHasColumn = false
    pcall(function() handle:Dispose() end) -- also closes a shown page
  end
  sharedAtConnect = nil
  clearActive()
end

-- A stale injected API answers "stopped" after a Core reload, so the shared
-- one is tried second.
M.Connect = function()
  M.Disconnect()
  if not M.Enabled() then return false end
  local handle, hasColumn = tryRegister(injectedAPI())
  if handle == nil then
    local shared = sharedAPI()
    if shared ~= nil and shared ~= injectedAPI() then
      handle, hasColumn = tryRegister(shared)
    end
  end
  if handle == nil then return false end
  ext = handle
  extHasColumn = hasColumn == true
  sharedAtConnect = sharedAPI()
  return true
end

M.HasColumn = function()
  return ext ~= nil and extHasColumn
end

-- Polled by main.lua: covers Core loading late, reloading (a new shared
-- table) and stopping (nil).
M.Heartbeat = function()
  if not M.Enabled() then
    if ext ~= nil then M.Disconnect() end
    return
  end
  local shared = sharedAPI()
  if ext == nil then
    if shared ~= nil or injectedAPI() ~= nil then M.Connect() end
    return
  end
  if shared ~= sharedAtConnect then
    if shared == nil then M.Disconnect() else M.Connect() end
  end
end

-- Returns true, or false plus Core's refusal reason. The record is set
-- before Open because Core draws inside Open, and is rolled back on refusal.
M.ShowPreset = function(preset)
  if ext == nil then return false, "inactive" end
  local prevId, prevPreset = activeId, activePreset
  activeId, activePreset = preset.id, preset
  local okOpen, why = false, nil
  pcall(function() okOpen, why = ext:Open() end)
  if okOpen ~= true then
    activeId, activePreset = prevId, prevPreset
    return false, why or "failed"
  end
  fireViewChanged()
  return true
end

-- No IsOpen check: the first drawing runs before Core reports the view open.
M.ViewPreset = function()
  return activePreset
end

M.Refresh = function()
  if ext == nil then return end
  pcall(function() ext:Refresh() end)
end

-- One { objectID, quantity } per native stack, placeholders included at
-- quantity 0. nil when Core cannot read the bank.
M.GetBankItems = function()
  if ext == nil then return nil end
  local items = nil
  pcall(function() items = ext:GetBankItems() end)
  return items
end

-- nil when Core cannot tell: no GetBankState, or a non-English client (its
-- detection matches English labels).
M.NativeSearchActive = function()
  if ext == nil or ext.GetBankState == nil then return nil end
  local state = nil
  pcall(function() state = ext:GetBankState() end)
  if type(state) ~= "table" then return nil end
  return state.searchActive == true or state.filterActive == true
end

M.Hide = function()
  if ext == nil then return end
  pcall(function() ext:Close() end)
  clearActive()
end

-- Checked against IsOpen: Core can close the page a tick before onClose lands.
M.ActivePresetId = function()
  if ext == nil or activeId == nil then return nil end
  local open = false
  pcall(function() open = ext:IsOpen() == true end)
  if not open then return nil end
  return activeId
end

M.ActivePreset = function()
  if M.ActivePresetId() == nil then return nil end
  return activePreset
end

return M
