-- The settings panel: a force-open button plus tabbed checkbox pages,
-- built into the layer the Plugin Hub provides.
--
-- Tabs are General / Interface / Permissions / Danger Zone. Everything
-- stores straight to PersistentDB and is read live by its consumer.
local M = {}

local store = require("core/store")
local identity = require("core/identity")
local bankutil = require("core/bankutil")
local bankpage = require("ui/bankpage")
local uikit = require("ui/uikit")
local window = require("ui/pvwin")

local settingsView
local settingsTab = 1

-- Rebuilds the panel one tick later, via the uikit heartbeat.
local lastLayer -- layer from the most recent Build call
local rebuildAt = nil -- uikit.Now() value to rebuild the panel at

M.ScheduleRebuild = function()
  if lastLayer then rebuildAt = uikit.Now() + 1 end
end

uikit.AddTicker("pvSettingsRebuild", function()
  if rebuildAt and uikit.Now() >= rebuildAt then
    rebuildAt = nil
    if lastLayer then pcall(function() M.Build(lastLayer) end) end
  end
end)

-- Per-tick disarm for the two-click Danger Zone buttons; the closure is
-- replaced by each Build.
local resetDisarm = nil
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
    -- The reference is claimed HERE, not at the end of the build.
    settingsView = view

    if bankutil.HasColumn() then
      -- Integrated: there is no window to force open, so say where the
      -- vault lives instead.
      view:AddText({
        text = "BankUtils (Bankcore) integration enabled",
        colour = 0xB8A169CC })
    else
      view:AddFancyButton("Open vault window", function()
        pcall(window.ForceOpen)
      end, { variant = "positive" })
    end

    -- Tab box sized to fill whatever the layer gives us: contentHeight is
    -- the height used so far, so the rest is ours. Pages scroll inside it.
    local used = view.contentHeight or 0
    local tabs = view:AddTabs({ "General", "Interface", "Permissions", "Danger Zone" }, {
      scrollable = true,
      height = math.max(140, h - used - 8),
      activeIndex = settingsTab, -- restore the tab the user was last on
      onChange = function(_, index) settingsTab = index or 1 end,
    })
    local gen, int = tabs:GetPage(1), tabs:GetPage(2)
    local perm, danger = tabs:GetPage(3), tabs:GetPage(4)

    local noCats = PersistentDB:GetBool("ui.noCategories") == true

    -- One dispatch for every checkbox group across all tabs. Default-ON
    -- toggles store an OPT-OUT key; default-OFF ones store the flag
    -- directly.
    local function onSettingChanged(_, _, changedValue, selected)
      pcall(function()
        if changedValue == "auto" then
          PersistentDB:SetBool("ui.manualMode", selected ~= true)
        elseif changedValue == "usecats" then
          PersistentDB:SetBool("ui.noCategories", selected ~= true)
          -- flips the Uncategorised toggle's greyed state, so the panel
          -- itself has to redraw, not just the window
          M.ScheduleRebuild()
        elseif changedValue == "uncat" then
          PersistentDB:SetBool("ui.noUncatBucket", selected ~= true)
        elseif changedValue == "align" then
          PersistentDB:SetBool("ui.alignNamesOff", selected ~= true)
        elseif changedValue == "lockalpha" then
          PersistentDB:SetBool("ui.lockAlpha", selected == true)
        elseif changedValue == "sfxoff" then
          PersistentDB:SetBool("ui.sfxOff", selected == true)
        elseif changedValue == "overlay" then
          PersistentDB:SetBool("ui.overlayOff", selected ~= true)
          -- the wrong-slot sub-toggle greys with this, so the panel redraws
          M.ScheduleRebuild()
        elseif changedValue == "wrongslot" then
          PersistentDB:SetBool("ui.wrongSlotOff", selected ~= true)
        elseif changedValue == "exactlayout" then
          PersistentDB:SetBool("ui.exactLayout", selected == true)
          -- the open bank view was built from the old flag; rebuild it in
          -- place so the toggle reads as live, like every other setting
          pcall(function()
            local p = bankpage.activePreset
            if p ~= nil then
              bankpage.Restore()
              bankpage.Show(p, true)
            end
            -- same for an open Core-backed view: queue a redraw - the
            -- drawer reads the flag per drawing (no-op when nothing shows)
            bankutil.Refresh()
          end)
        elseif changedValue == "bankutil" then
          -- Master integration switch: ON hands the bank view to Core and
          -- shows our rail icon, OFF disposes the extension. The handover
          -- closes the other engine's view first.
          PersistentDB:SetBool("ui.bankUtilOff", selected ~= true)
          pcall(function()
            if selected == true then
              -- Restore hands the natives back; DestroyChrome then FREES
              -- the grid dynamicIDs the standalone canvas + cells held.
              pcall(bankpage.Restore)
              pcall(bankpage.DestroyChrome)
              bankutil.Connect()
            else
              bankutil.Disconnect()
            end
          end)
          M.ScheduleRebuild()
        end
        window.Relayout() -- live refresh if the window is up
      end)
    end

    -- Interface: two columns under their own headings, placed absolutely.
    -- Labels drop the prefix the heading already supplies, and each entry's
    -- `disabled` flag greys it where the mode makes it meaningless.
    local pageW = int.contentWidth or (w - 24)
    local colW = math.max(110, math.floor((pageW - 12) / 2))
    local col2X = colW + 12
    -- The integration toggle sits ABOVE everything else here - it decides
    -- which UI module runs, so it outranks the cosmetic toggles. Rendered
    -- only when Core is reachable; otherwise one explanation line.
    local TOGGLE_Y = 10 -- breathing room above the master switch
    local TITLES_Y = TOGGLE_Y + 30
    local integrated = false
    if bankutil.CoreDetected() then
      integrated = bankutil.Enabled()
      int:AddCheckboxButton({
        { text = "BankUtils (Bankcore) Integration", value = "bankutil",
          selected = integrated },
      }, { x = 0, y = TOGGLE_Y, width = pageW, onChange = onSettingChanged })
    else
      int:AddText({ text = "BankUtils Core not detected - using built-in UI.",
        colour = 0xB8A169CC, x = 0, y = TOGGLE_Y, width = pageW })
      TITLES_Y = TOGGLE_Y + 24
    end
    -- No font override on titles: AddTitle defaults to CINZEL_13PT_BOLD, the
    -- same face as the window titles and category banners.
    if integrated then
      -- INTEGRATED SET: just what the Core column honours, plus a note.
      -- Stored values are untouched and the full set returns when
      -- integration is switched off.
      int:AddTitle({ text = "BankUtils interface", x = 0, y = TITLES_Y,
        width = pageW })
      int:AddCheckboxButton({
        { text = "Use categories", value = "usecats", selected = not noCats },
        { text = "Uncategorised section", value = "uncat",
          selected = PersistentDB:GetBool("ui.noUncatBucket") ~= true,
          disabled = noCats },
        { text = "Presets alphabetical order", value = "lockalpha",
          selected = PersistentDB:GetBool("ui.lockAlpha") == true },
      }, { x = 0, y = TITLES_Y + 26, width = pageW, onChange = onSettingChanged })
      int:AddText({
        text = "Preset Vault's dedicated windows are hidden while integration is on.",
        colour = 0xB8A169CC, x = 0, y = TITLES_Y + 116, width = pageW })
    else
      local COLS_Y = TITLES_Y + 26 -- below the headings
      int:AddTitle({ text = "Categories", x = 0, y = TITLES_Y, width = colW })
      int:AddTitle({ text = "Presets", x = col2X, y = TITLES_Y, width = colW })
      int:AddCheckboxButton({
        { text = "Use categories", value = "usecats", selected = not noCats },
        { text = "Uncategorised section", value = "uncat",
          selected = PersistentDB:GetBool("ui.noUncatBucket") ~= true,
          disabled = noCats },
      }, { x = 0, y = COLS_Y, width = colW, onChange = onSettingChanged })
      int:AddCheckboxButton({
        -- default-ON first, matching the Categories column's shape; the
        -- default-OFF toggle follows
        { text = "Align no-icon names", value = "align",
          selected = PersistentDB:GetBool("ui.alignNamesOff") ~= true },
        { text = "Lock alphabetical order", value = "lockalpha",
          selected = PersistentDB:GetBool("ui.lockAlpha") == true },
      }, { x = col2X, y = COLS_Y, width = colW, onChange = onSettingChanged })
    end

    -- Auto-open greys out with a note while the Core column is the in-bank
    -- UI. The stored value is untouched.
    local autoDead = bankutil.HasColumn()
    gen:AddCheckboxButton({
      { text = autoDead
          and "Auto-open with bank <col=b8a169>- BankUtils enabled</col>"
          or "Auto-open with bank",
        value = "auto",
        selected = PersistentDB:GetBool("ui.manualMode") ~= true,
        disabled = autoDead },
      -- The wrong-slot guide is the purple move-by-move state, and greys
      -- out with its parent.
      { text = "Discrepancy overlay", value = "overlay",
        selected = PersistentDB:GetBool("ui.overlayOff") ~= true },
      { text = "Wrong-slot guide", value = "wrongslot",
        selected = PersistentDB:GetBool("ui.wrongSlotOff") ~= true,
        disabled = PersistentDB:GetBool("ui.overlayOff") == true },
      -- Bank view draws one cell per snapshot SLOT (gaps kept, per-slot
      -- counts) instead of the compact merged grid
      { text = "Exact preset layout in bank", value = "exactlayout",
        selected = PersistentDB:GetBool("ui.exactLayout") == true },
      { text = "Disable interface sounds", value = "sfxoff",
        selected = PersistentDB:GetBool("ui.sfxOff") == true },
    }, { onChange = onSettingChanged })

    -- The permission GATES this toggle; the toggle cannot request it.
    -- Granting it mid-session swaps the explanation for the checkbox live.
    -- Exception: with Multi-character already ON, the toggle shows even
    -- without the permission, so it can still be turned OFF - disabling
    -- writes one bool and claims nothing, so it needs no identity.
    local multiOn = PersistentDB:GetBool("vault.multiChar") == true
    if identity.HasPermission() or multiOn then
      perm:AddCheckboxButton({
        { text = "Multi-character vaults", value = "multichar",
          selected = multiOn },
      }, {
        onChange = function(_, _, changedValue, selected)
          if changedValue ~= "multichar" then return end
          pcall(function()
            if selected == true then
              -- Binds the existing vault to THIS character, and REFUSES to
              -- enable if the character cannot be identified.
              if not store.ClaimBaseVault() then
                log("[PV] cannot enable multi-character - character not identified yet")
                M.ScheduleRebuild() -- re-render unticked from stored state
                return
              end
            end
            PersistentDB:SetBool("vault.multiChar", selected == true)
            pcall(bankpage.Restore) -- the open bank view belongs to the old vault
            pcall(bankutil.Hide)
            window.OnVaultChanged()
            M.ScheduleRebuild() -- show/hide the shared-vault picker
          end)
        end,
      })
      perm:AddText({
        text = "Off: every character on this device shares one vault.",
        colour = 0xB8A169CC })
      -- With the permission granted but no character ID yet, say so
      -- instead of offering a toggle that would refuse the tick. The
      -- stranded case (permission off, toggle still on) gets no extra
      -- line - the tab's own text already explains it.
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

    -- Shared mode reads ONE vault, so with several on the machine the user
    -- picks which. Switching moves no data.
    if PersistentDB:GetBool("vault.multiChar") ~= true then
      local vaults = store.Vaults()
      if #vaults > 1 then
        -- Entry ids must be INTEGERS, so the entries are indexed and the
        -- id mapped back to a vault key on change.
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
        -- A proper section title (same CINZEL face as the Interface tab's
        -- subtitles), with breathing room above the whole picker block.
        perm:AddTitle({ text = "Shared vault", marginTop = 12 })
        perm:AddComboBox({
          entries = entries,
          selectedID = selectedID,
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

    -- ---------------------------------------------------------------------
    -- Danger Zone. Both buttons are irreversible, so both ARM on the first
    -- click and only act on a second. ARM_GRACE swallows the second half
    -- of a double-click; ARM_TIMEOUT disarms if the user walks away.
    -- ---------------------------------------------------------------------
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
      if armed ~= nil and armed.key ~= key then -- arming one disarms the other
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

    -- Button 1: this character's vault only. Settings and every other
    -- character's vault survive. The wording follows the mode.
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

    -- Button 2: the whole plugin namespace - presets, categories, every
    -- ui.* setting, the vault mode, and EVERY character's vault. The panel
    -- rebuilds a tick later so the checkboxes show defaults again.
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
        pcall(bankpage.Restore) -- release an active preset bank view first
        pcall(bankutil.Hide)
        PersistentDB:Clear()
        window.OnVaultChanged()
        M.ScheduleRebuild()
      end)
      log("[PV] factory reset - all stored data cleared")
    end, { variant = "negative" })
  end)
  if not ok then log(formatStr("[PV] settings build failed: {}", tostring(err))) end
end

return M
