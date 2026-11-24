-- The settings panel, built into the layer the Plugin Hub provides. Every
-- setting is stored through core/prefs and read live by its consumer.
local M = {}
local prefs = require("core/prefs")

local store = require("core/store")
local identity = require("core/identity")
local bankutil = require("core/bankutil")
local bankpage = require("ui/bankpage")
local uikit = require("ui/uikit")
local window = require("ui/pvwin")

local settingsView
local settingsTab = 1 -- module-level so a rebuild keeps the user's tab

local lastLayer
local rebuildAt = nil -- a uikit.Now() value

-- Deferred a tick: the control asking for a rebuild lives in the view that
-- the rebuild destroys.
M.ScheduleRebuild = function()
  if lastLayer then rebuildAt = uikit.Now() + 1 end
end

uikit.AddTicker("pvSettingsRebuild", function()
  if rebuildAt and uikit.Now() >= rebuildAt then
    rebuildAt = nil
    if lastLayer then pcall(function() M.Build(lastLayer) end) end
  end
end)

local resetDisarm = nil -- replaced by each Build
uikit.AddTicker("pvSettingsDisarm", function()
  if resetDisarm then resetDisarm() end
end)

M.Build = function(layerComponent)
  lastLayer = layerComponent
  if settingsView then
    pcall(function() settingsView:Destroy() end)
    settingsView = nil
  end
  local ok, err = pcall(function()
    local w = layerComponent.width or 400
    local h = layerComponent.height or 300
    local view = prettyui.SimpleView.new(layerComponent,
      { width = w, height = h, categoryID = "auto" })
    -- claimed before anything can throw, or a failed build orphans the view
    settingsView = view

    if bankutil.HasColumn() then
      view:AddText({
        text = "Bank Core integration enabled",
        colour = 0xB8A169CC })
    else
      view:AddFancyButton("Open vault window", function()
        pcall(window.ForceOpen)
      end, { variant = "positive" })
    end

    -- An explicit height is required: Tabs falls back to a fixed 180px.
    local used = view.contentHeight or 0
    local tabs = view:AddTabs({ "General", "Interface", "Permissions", "Danger Zone" }, {
      scrollable = true,
      height = math.max(140, h - used - 8),
      activeIndex = settingsTab,
      onChange = function(_, index) settingsTab = index or 1 end,
    })
    local gen, int = tabs:GetPage(1), tabs:GetPage(2)
    local perm, danger = tabs:GetPage(3), tabs:GetPage(4)

    local noCats = prefs.GetBool("ui.noCategories") == true

    -- an open bank view was built from the old flags
    local function rebuildBankView()
      pcall(function()
        local p = bankpage.activePreset
        if p ~= nil then
          bankpage.Restore()
          bankpage.Show(p, true)
        end
        bankutil.Refresh()
      end)
    end

    -- An unset bool reads false, so a default-on setting stores an opt-out
    -- key and a default-off one stores the flag itself.
    local function onSettingChanged(_, _, changedValue, selected)
      pcall(function()
        if changedValue == "auto" then
          prefs.SetBool("ui.manualMode", selected ~= true)
        elseif changedValue == "usecats" then
          prefs.SetBool("ui.noCategories", selected ~= true)
          M.ScheduleRebuild()
        elseif changedValue == "uncat" then
          prefs.SetBool("ui.noUncatBucket", selected ~= true)
        elseif changedValue == "align" then
          prefs.SetBool("ui.alignNamesOff", selected ~= true)
        elseif changedValue == "lockalpha" then
          prefs.SetBool("ui.lockAlpha", selected == true)
        elseif changedValue == "sfxoff" then
          prefs.SetBool("ui.sfxOff", selected == true)
        elseif changedValue == "overlay" then
          prefs.SetBool("ui.overlayOff", selected ~= true)
          M.ScheduleRebuild()
        elseif changedValue == "wrongslot" then
          prefs.SetBool("ui.wrongSlotOff", selected ~= true)
        elseif changedValue == "packstack" then
          prefs.SetBool("ui.packStackOff", selected ~= true)
          rebuildBankView()
        elseif changedValue == "exactlayout" then
          prefs.SetBool("ui.exactLayout", selected == true)
          rebuildBankView()
          M.ScheduleRebuild()
        elseif changedValue == "bankutil" then
          prefs.SetBool("ui.bankUtilOff", selected ~= true)
          pcall(function()
            if selected == true then
              -- Hiding is not enough: Bank Core addresses the bank grid by
              -- dynamicID, so the standalone chrome must free its ids first.
              pcall(bankpage.Restore)
              pcall(bankpage.DestroyChrome)
              bankutil.Connect()
            else
              bankutil.Disconnect()
            end
          end)
          M.ScheduleRebuild()
        end
        window.Relayout()
      end)
    end

    -- Everything on the Interface page is placed absolutely (an explicit y
    -- takes a control out of the flow), so nothing flowed may follow it.
    local pageW = int.contentWidth or (w - 24)
    local colW = math.max(110, math.floor((pageW - 12) / 2))
    local col2X = colW + 12
    local TOGGLE_Y = 10
    local TITLES_Y = TOGGLE_Y + 30
    local integrated = false
    if bankutil.CoreDetected() then
      integrated = bankutil.Enabled()
      int:AddCheckboxButton({
        { text = "Bank Core Integration", value = "bankutil",
          selected = integrated },
      }, { x = 0, y = TOGGLE_Y, width = pageW, onChange = onSettingChanged })
    else
      int:AddText({ text = "Bank Core not detected - using built-in UI.",
        colour = 0xB8A169CC, x = 0, y = TOGGLE_Y, width = pageW })
      TITLES_Y = TOGGLE_Y + 24
    end
    if integrated then
      int:AddTitle({ text = "Bank Core interface", x = 0, y = TITLES_Y,
        width = pageW })
      int:AddCheckboxButton({
        { text = "Use categories", value = "usecats", selected = not noCats },
        { text = "Uncategorised section", value = "uncat",
          selected = prefs.GetBool("ui.noUncatBucket") ~= true,
          disabled = noCats },
        { text = "Presets alphabetical order", value = "lockalpha",
          selected = prefs.GetBool("ui.lockAlpha") == true },
      }, { x = 0, y = TITLES_Y + 26, width = pageW, onChange = onSettingChanged })
      int:AddText({
        text = "Preset Vault's dedicated windows are hidden while integration is on.",
        colour = 0xB8A169CC, x = 0, y = TITLES_Y + 116, width = pageW })
    else
      local COLS_Y = TITLES_Y + 26
      int:AddTitle({ text = "Categories", x = 0, y = TITLES_Y, width = colW })
      int:AddTitle({ text = "Presets", x = col2X, y = TITLES_Y, width = colW })
      int:AddCheckboxButton({
        { text = "Use categories", value = "usecats", selected = not noCats },
        { text = "Uncategorised section", value = "uncat",
          selected = prefs.GetBool("ui.noUncatBucket") ~= true,
          disabled = noCats },
      }, { x = 0, y = COLS_Y, width = colW, onChange = onSettingChanged })
      int:AddCheckboxButton({
        { text = "Align no-icon names", value = "align",
          selected = prefs.GetBool("ui.alignNamesOff") ~= true },
        { text = "Lock alphabetical order", value = "lockalpha",
          selected = prefs.GetBool("ui.lockAlpha") == true },
      }, { x = col2X, y = COLS_Y, width = colW, onChange = onSettingChanged })
    end

    -- HasColumn, not Enabled: a registration without a column keeps the window
    local autoDead = bankutil.HasColumn()
    gen:AddCheckboxButton({
      { text = autoDead
          and "Auto-open with bank <col=b8a169>- Bank Core enabled</col>"
          or "Auto-open with bank",
        value = "auto",
        selected = prefs.GetBool("ui.manualMode") ~= true,
        disabled = autoDead },
      { text = "Discrepancy overlay", value = "overlay",
        selected = prefs.GetBool("ui.overlayOff") ~= true },
      { text = "Wrong-slot guide", value = "wrongslot",
        selected = prefs.GetBool("ui.wrongSlotOff") ~= true
          and prefs.GetBool("ui.overlayOff") ~= true,
        disabled = prefs.GetBool("ui.overlayOff") == true },
      { text = "Vertically stack backpack", value = "packstack",
        selected = prefs.GetBool("ui.packStackOff") ~= true },
      { text = "Exact preset layout in bank", value = "exactlayout",
        selected = prefs.GetBool("ui.exactLayout") == true },
    }, { onChange = onSettingChanged })

    if prefs.GetBool("ui.exactLayout") == true then
      local function packLabel()
        return prefs.GetBool("ui.packTall") == true and "7 rows x 4"
          or "4 rows x 7"
      end
      local packBtn
      packBtn = gen:AddFancyButton(packLabel(), function()
        pcall(function()
          prefs.SetBool("ui.packTall", prefs.GetBool("ui.packTall") ~= true)
          packBtn:SetText(packLabel())
          rebuildBankView()
        end)
      end, { tooltip = "Backpack arrangement in the exact layout" })
    end

    gen:AddCheckboxButton({
      { text = "Disable interface sounds", value = "sfxoff",
        selected = prefs.GetBool("ui.sfxOff") == true },
    }, { onChange = onSettingChanged })

    -- The toggle also shows while it is on without the permission: otherwise
    -- a revoked permission leaves every vault locked with no way to turn it off.
    local multiOn = prefs.GetBool("vault.multiChar") == true
    if identity.HasPermission() or multiOn then
      perm:AddCheckboxButton({
        { text = "Multi-character vaults", value = "multichar",
          selected = multiOn },
      }, {
        onChange = function(_, _, changedValue, selected)
          if changedValue ~= "multichar" then return end
          pcall(function()
            if selected == true then
              -- Must refuse while unidentified: an unowned base vault is
              -- claimed by the next character to be identified.
              if not store.ClaimBaseVault() then
                log("[PV] cannot enable multi-character - character not identified yet")
                M.ScheduleRebuild()
                return
              end
            end
            prefs.SetBool("vault.multiChar", selected == true)
            pcall(bankpage.Restore) -- the open bank view belongs to the old vault
            pcall(bankutil.Hide)
            window.OnVaultChanged()
            M.ScheduleRebuild()
          end)
        end,
      })
      perm:AddText({
        text = "Off: every character on this device shares one vault.",
        colour = 0xB8A169CC })
      if identity.HasPermission() and identity.Get() == nil then
        perm:AddText({
          text = "Waiting for character identity - cannot enable yet.",
          colour = 0xE0B050FF })
      end
    else
      perm:AddText({
        text = "Multi-character vaults need the tracking permission.",
        colour = 0xB8A169CC })
      perm:AddText({
        text = "Grant it in this plugin's permissions, then return here.",
        colour = 0xB8A169CC })
    end

    if prefs.GetBool("vault.multiChar") ~= true then
      local vaults = store.Vaults()
      if #vaults > 1 then
        -- ComboField entry ids must be integers (a string id throws), so
        -- vault keys are mapped through keyByID.
        local current = store.CurrentKey()
        local entries, keyByID, selectedID = {}, {}, nil
        for i, v in ipairs(vaults) do
          entries[#entries + 1] = {
            label = formatStr("{} ({} presets)", v.label, v.count),
            id = i,
          }
          keyByID[i] = v.key
          if v.key == current then selectedID = i end
        end
        perm:AddTitle({ text = "Shared vault", marginTop = 12 })
        perm:AddComboBox({
          entries = entries,
          selectedID = selectedID,
          -- also fires when the dropdown opens or closes, hence the key test
          onChange = function(_, entryID)
            local key = keyByID[entryID]
            if key == nil or key == store.CurrentKey() then return end
            pcall(function()
              store.SetSharedVault(key)
              pcall(bankpage.Restore)
              pcall(bankutil.Hide)
              window.OnVaultChanged()
            end)
          end,
        })
        perm:AddText({
          text = "The other vaults stay saved, just not shown.",
          colour = 0xB8A169CC })
      end
    end

    -- Ticks. A second click inside ARM_GRACE is taken as a double-click and
    -- ignored; an armed button disarms after ARM_TIMEOUT.
    local ARM_GRACE, ARM_TIMEOUT = 25, 250
    local armed = nil -- { key, button, label, at }
    resetDisarm = function()
      if armed == nil then return end
      if (uikit.Now() - armed.at) < ARM_TIMEOUT then return end
      local a = armed
      armed = nil
      pcall(function() a.button:SetText(a.label) end)
    end
    -- Returns true when this click is the confirming one.
    local function armOrFire(key, button, label, armedLabel)
      if armed ~= nil and armed.key ~= key then
        pcall(function() armed.button:SetText(armed.label) end)
        armed = nil
      end
      if armed ~= nil and (uikit.Now() - armed.at) >= ARM_GRACE then
        armed = nil
        pcall(function() button:SetText(label) end)
        return true
      end
      if armed == nil then
        armed = { key = key, button = button, label = label, at = uikit.Now() }
        pcall(function() button:SetText(armedLabel) end)
      end
      return false
    end

    danger:AddText({
      text = identity.Enabled()
        and "Deletes the presets on the character you are using now."
        or "Deletes all presets. Multi-character is off, so every character loses them.",
      colour = 0xE05A4AFF })
    local resetVaultBtn
    resetVaultBtn = danger:AddFancyButton("Reset Current Vault", function()
      if not armOrFire("vault", resetVaultBtn, "Reset Current Vault",
        "Click again to delete") then return end
      pcall(function()
        pcall(bankpage.Restore)
        pcall(bankutil.Hide)
        if not store.ResetCurrentVault() then
          log("[PV] no current vault to reset - character not identified")
          return
        end
        window.OnVaultChanged()
        log("[PV] current vault cleared")
      end)
    end, { variant = "negative" })

    danger:AddText({ text = "Returns the plugin to its first-install state.",
      colour = 0xE05A4AFF, marginTop = 16 })
    danger:AddText({
      text = "This clears EVERY character's vault and returns settings to default",
      colour = 0xE05A4AFF })
    local resetAllBtn
    resetAllBtn = danger:AddFancyButton("Reset Plugin", function()
      if not armOrFire("plugin", resetAllBtn, "Reset Plugin",
        "Click again to wipe everything") then return end
      pcall(function()
        pcall(bankpage.Restore)
        pcall(bankutil.Hide)
        -- Clear bypasses both caches, so each is dropped by hand
        PersistentDB:Clear()
        store.Invalidate()
        prefs.Invalidate()
        window.OnVaultChanged()
        M.ScheduleRebuild()
      end)
      log("[PV] factory reset - all stored data cleared")
    end, { variant = "negative" })
  end)
  if not ok then log(formatStr("[PV] settings build failed: {}", tostring(err))) end
end

return M
