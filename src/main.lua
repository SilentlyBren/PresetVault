-- Preset Vault: unlimited gear/inventory preset manager.
--
-- Lifecycle and wiring only. The implementation is in core/ (data systems,
-- no UI) and ui/ (everything that draws).
--
-- This plugin READS game state and renders UI. It never sends actions, makes
-- network calls, or automates anything: the player clicks, we only display
-- and organise. One optional permission is requested, trackingAccess, used
-- solely to tell characters apart for per-character vaults.

log("[PV] loading...")

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

-- Register with BankUtil Core, injecting the sidebar column and custom-view
-- drawer first. Core is OPTIONAL - everything works without it.
bankutil.SetColumnProvider(bucolumn.Provider)
bankutil.SetViewProvider(bupage.Provider)
pcall(bankutil.Connect)
-- The side-panel discrepancy overlay; draws only while a preset view is on.
pcall(overlay.Init)

-- A dependency was enabled or disabled; let the heartbeat work out what
-- that means for us.
function PluginDependencyUpdate()
  pcall(bankutil.Heartbeat)
end

-- The Plugin Hub's Settings button hands us an empty layer to fill.
local function onSettingsLayer(event)
  settings.Build(event.component)
end
Event.SettingsLayerReady.Subscribe("pvSettingsLayer", onSettingsLayer)

-- The ribbon icon's content layer, rebuilt on each "on" transition.
local function onContentLayer(event)
  ribbon.Build(event.component)
end
Event.ContentLayerReady.Subscribe("pvContentLayer", onContentLayer)

local bankWasOpen = false
local function applyBankState(bankNow)
  -- On bank close, our chrome is torn down and rebuilt next session.
  if bankWasOpen and not bankNow then
    bankpage.Restore() -- event path can land before bankpage's own tick
    bankpage.DestroyChrome()
    pcall(overlay.DestroyChrome) -- side-panel chrome detaches the same way
    -- force-open is a bank-session override in auto mode only; a manual-mode
    -- window outlives the bank
    if PersistentDB:GetBool("ui.manualMode") ~= true then
      window.ClearWantOpen()
    end
  end
  bankWasOpen = bankNow

  local open
  if bankutil.HasColumn() then
    -- Integration owns the UI outright: the column IS the vault.
    open = false
  elseif PersistentDB:GetBool("ui.manualMode") == true then
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

local identityWasReady = nil
local function bankWindowTick(event)
  if event.logicTick % 5 ~= 0 then return end
  identity.Update()
  pcall(bankutil.Heartbeat)
  -- Every surface that can show the vault-locked notice redraws when the
  -- identity state changes.
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

-- Drops the cached identity so it is re-resolved before the vault reopens.
local function forgetIdentity()
  pcall(function()
    identity.Forget()
    window.OnIdentityChanged()
    settings.ScheduleRebuild()
  end)
end
Event.GameStateChanged.Subscribe("pvIdentityState", forgetIdentity)
Event.OptionalPermissionChanged.Subscribe("pvIdentityPerm", forgetIdentity)

-- Bank open/close timing: inv 95 is added on open, removed on close. The
-- readability poll stays the source of truth; this only makes it prompt.
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
  bankpage.Restore() -- hand the bank back untouched if a view was active
  bankpage.DestroyChrome() -- chrome survives Restore; only shutdown kills it
  overlay.Shutdown() -- side-panel overlay: tick + chrome
  bankutil.Disconnect() -- release the Core extension (removes icon + view)
  bucolumn.Shutdown() -- the right-click menu subscription
  uikit.Shutdown() -- the shared UI heartbeat (tooltips, drags, timers)
  window.Destroy()
  log("[PV] Preset Vault unloaded")
end
