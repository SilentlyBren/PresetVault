-- BankUtil Core integration: the connection lifecycle to the `bankcore`
-- plugin, and view control for the preset page Core draws on our behalf.
--
-- While integration is active the vault's view buttons route here instead of to
-- ui/bankpage, and the preset is rendered by ui/bupage through Core's custom
-- view. Our own panel engine is the fallback when Core is absent, disabled,
-- or the setting is off.
--
-- Core IS an optional dependency and the dev manifest declares it as one.
-- Detection is runtime in both builds, against two globals: the
-- client-injected `bankcore` while that manifest declaration is live, and
-- otherwise `__bankcore_api`, the shared API global Core publishes for
-- exactly this purpose. Either way integration lights up for players who
-- have Core and stays silent for players who do not.
local M = {}

local EXT_ID = "presetvault"
local EXT_NAME = "Preset Vault"
local ICON_SPRITE = 18733 -- CHILD_HEADER_ICON_WORN
local ICON_FALLBACK = "OUTFIT" -- for a Core that refuses numeric icons

local ext = nil -- live extension handle; nil = not registered
local extHasColumn = false -- whether the live registration carries the column
local sharedAtConnect = nil -- __bankcore_api as of the successful Connect
local activeId = nil -- preset id whose page we last opened
local activePreset = nil

M.OnViewChanged = nil -- ui/pvwin hook, fired after open/close/external close

local function fireViewChanged()
  if M.OnViewChanged then pcall(M.OnViewChanged) end
end

-- The custom-view drawer's callbacks (ui/bupage.Provider: draw + stop),
-- injected by main.lua before Connect.
local viewProvider = nil
M.SetViewProvider = function(callbacks)
  viewProvider = callbacks
end

local function clearActive()
  -- stop() runs unconditionally, BEFORE the early return: the drawer's live
  -- layer must be torn down even if we had no view recorded.
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
  return PersistentDB:GetBool("ui.bankUtilOff") ~= true
end

-- Registered and usable right now.
M.IsActive = function()
  return ext ~= nil
end

-- The sidebar column's { mount, resize, unmount } callbacks (ui/bucolumn),
-- injected by main.lua before Connect.
local columnProvider = nil
M.SetColumnProvider = function(callbacks)
  columnProvider = callbacks
end

local function registrationSpec(icon)
  return {
    id = EXT_ID,
    name = EXT_NAME,
    icon = icon,
    -- No icon means no column either - Core will not accept one without
    -- the other.
    column = (icon ~= nil) and columnProvider or nil,
    -- Core calls the drawer on open, on Refresh, and after every bank item
    -- change; the drawer reads the preset back via M.ViewPreset().
    customView = (viewProvider ~= nil)
      and function(view) return viewProvider.draw(view) end or nil,
    -- Our view stopped showing: native tab, another plugin's page, a close,
    -- or a failed redraw.
    onClose = function() clearActive() end,
    onBankClose = function() clearActive() end,
  }
end

-- Registers with the first icon Core accepts, falling back to no rail icon.
-- Returns the handle, plus whether that registration carried the column.
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

-- Registers, or re-registers, with whichever API answers.
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

-- Whether the live registration includes the sidebar column.
M.HasColumn = function()
  return ext ~= nil and extHasColumn
end

-- Reconnect check, polled from main.lua's 5-tick heartbeat. Handles Core
-- loading late, reloading (a new table) and stopping (nil).
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

-- ---- view control -----------------------------------------------------------

-- Opens the preset's view. Returns true, or false plus Core's refusal
-- reason. The active record is set BEFORE Open and rolled back on refusal.
M.ShowPreset = function(preset)
  if ext == nil then return false, "inactive" end
  -- Our own wrong-tab gate, BEFORE Core's: Core's Open gate trusts its
  -- CACHED tab flag, which only player-driven tab clicks update - so after
  -- the CLIENT switches tabs itself (a deposit landing in another tab's
  -- placeholder) the stale cache lets Open succeed on the wrong tab, and
  -- our structural tick then closes the view a tick later: the preset
  -- flashes on and dies with no refusal chime or pulse. NativeViewAll is
  -- the FRESH reading (GetBankState detects before consulting the cache);
  -- nil means pre-1.5 Core, where Core's own gate is all there is.
  if M.NativeViewAll() == false then return false, "not_all_items" end
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

-- The preset the custom-view drawer should render.
M.ViewPreset = function()
  return activePreset
end

-- Queues a redraw of our shown view, for setting changes on our side.
M.Refresh = function()
  if ext == nil then return end
  pcall(function() ext:Refresh() end)
end

-- Core's own bank read: one { objectID, quantity } per native stack,
-- placeholders included at quantity 0. nil when unavailable.
M.GetBankItems = function()
  if ext == nil then return nil end
  local items = nil
  pcall(function() items = ext:GetBankItems() end)
  return items
end

-- Core's own "native All Items tab is selected" reading, or nil when Core
-- cannot answer (pre-1.5 Core has no GetBankState, or the call fails) - the
-- caller then falls back to its own BANK_3 read.
M.NativeViewAll = function()
  if ext == nil or ext.GetBankState == nil then return nil end
  local state = nil
  pcall(function() state = ext:GetBankState() end)
  if type(state) ~= "table" then return nil end
  return state.viewAll == true
end

-- True when Core reports a native bank search OR filter is active; nil when
-- Core cannot answer (pre-1.5, or a non-English client where the labels do
-- not match), so the caller simply does not bail.
M.NativeSearchActive = function()
  if ext == nil or ext.GetBankState == nil then return nil end
  local state = nil
  pcall(function() state = ext:GetBankState() end)
  if type(state) ~= "table" then return nil end
  return state.searchActive == true or state.filterActive == true
end

-- Returns the bank to its native view if our page is the one showing.
M.Hide = function()
  if ext == nil then return end
  pcall(function() ext:Close() end)
  clearActive()
end

-- The preset whose page the bank is showing NOW, verified against Core's
-- own IsOpen rather than trusting our record alone.
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
