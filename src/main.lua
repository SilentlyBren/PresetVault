-- Preset Vault: lifecycle and wiring only. core/ holds the data systems,
-- ui/ everything that draws. The plugin reads game state and renders UI; it
-- never sends actions or makes network calls.

log("[PV] loading...")
local prefs = require("core/prefs")

local window = require("ui/pvwin")
local bankpage = require("ui/bankpage")
local bankutil = require("core/bankutil")
local bucolumn = require("ui/bucolumn")
local bupage = require("ui/bupage")
local overlay = require("ui/overlay")
local identity = require("core/identity")
local uikit = require("ui/uikit")
local settings = require("ui/settings")
local ribbon = require("ui/ribbon")

-- the providers must be set before Connect
bankutil.SetColumnProvider(bucolumn.Provider)
bankutil.SetViewProvider(bupage.Provider)
pcall(bankutil.Connect)
pcall(overlay.Init)

-- A nudge only, and it never inspects the event: Heartbeat detects Bank Core
-- arriving, reloading or leaving by itself.
function PluginDependencyUpdate()
  pcall(bankutil.Heartbeat)
end

local function onSettingsLayer(event)
  settings.Build(event.component)
end
Event.SettingsLayerReady.Subscribe("pvSettingsLayer", onSettingsLayer)

local function onContentLayer(event)
  ribbon.Build(event.component)
end
Event.ContentLayerReady.Subscribe("pvContentLayer", onContentLayer)

local bankWasOpen = false
local function applyBankState(bankNow)
  -- The client detaches plugin children of bank components on close: the
  -- handles keep answering but never render again, so chrome is destroyed.
  if bankWasOpen and not bankNow then
    bankpage.Restore() -- event path can land before bankpage's own tick
    bankpage.DestroyChrome()
    pcall(overlay.DestroyChrome)
    -- WantOpen lasts one bank session, except in manual mode
    if prefs.GetBool("ui.manualMode") ~= true then
      window.ClearWantOpen()
    end
  end
  bankWasOpen = bankNow

  local open
  if bankutil.HasColumn() then
    -- HasColumn, not Enabled: a registration without a column keeps the window
    open = false
  elseif prefs.GetBool("ui.manualMode") == true then
    open = window.WantOpen()
  else
    open = bankNow or window.WantOpen()
  end
  if open then
    window.EnsureBuilt()
    window.SetHidden(false)
  else
    window.SetHidden(true)
  end
end

-- core/identity's RESOLVE_TIMEOUT counts these polls: change both together.
local POLL_TICKS = 10
local identityWasReady = nil
local function bankWindowTick(event)
  if event.logicTick % POLL_TICKS ~= 0 then return end
  identity.Update()
  pcall(bankutil.Heartbeat)
  local ready = identity.State()
  if ready ~= identityWasReady then
    identityWasReady = ready
    pcall(window.OnIdentityChanged)
    pcall(settings.ScheduleRebuild)
    pcall(bucolumn.OnIdentityChanged)
  end
  applyBankState(bankpage.IsBankOpen())
end
Event.Logic.Subscribe("pvBankWindow", bankWindowTick)

local function forgetIdentity()
  pcall(function()
    identity.Forget()
    window.OnIdentityChanged()
    settings.ScheduleRebuild()
  end)
end
Event.GameStateChanged.Subscribe("pvIdentityState", forgetIdentity)
Event.OptionalPermissionChanged.Subscribe("pvIdentityPerm", forgetIdentity)

-- Inventory 95 is the bank. Timing only: the poll still decides visibility,
-- so a spurious add (inventories streaming in at login) cannot flash the window.
local function onBankInvEvent(event)
  pcall(function()
    if event.inv ~= nil and event.inv.id == 95 then
      applyBankState(bankpage.IsBankOpen())
    end
  end)
end
Event.InventoryAdded.Subscribe("pvBankInvAdd", onBankInvEvent)
Event.InventoryRemoved.Subscribe("pvBankInvRm", onBankInvEvent)

function PluginShutdown()
  Event.SettingsLayerReady.Unsubscribe("pvSettingsLayer")
  Event.ContentLayerReady.Unsubscribe("pvContentLayer")
  Event.Logic.Unsubscribe("pvBankWindow")
  Event.InventoryAdded.Unsubscribe("pvBankInvAdd")
  Event.InventoryRemoved.Unsubscribe("pvBankInvRm")
  Event.GameStateChanged.Unsubscribe("pvIdentityState")
  Event.OptionalPermissionChanged.Unsubscribe("pvIdentityPerm")
  -- Restore first: it unsets the opConfig flags, which needs the chrome alive
  bankpage.Restore()
  bankpage.DestroyChrome()
  overlay.Shutdown()
  bankutil.Disconnect()
  bucolumn.Shutdown()
  uikit.Shutdown()
  window.Destroy()
  log("[PV] Preset Vault unloaded")
end
