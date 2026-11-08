-- The main Preset Vault window: the standalone vault UI, built on PrettyUI.
-- Its satellite windows live in their own modules - the detail window in
-- ui/detailwin, the icon picker in ui/iconwin, share/import in ui/sharewin -
-- each configured from here and never requiring this module back.
--
-- BUILD-ONCE ARCHITECTURE - everything here is built once and updated in
-- place:
--   * preset rows and category headers live in reusable pools, hidden when
--     unused, then positioned and re-labelled on each relayout();
--   * ONE shared tooltip, ONE drag ghost, ONE inline rename field, and the
--     persistent satellite windows above.
-- Mutating properties (content, spriteID, position, hidden) costs nothing;
-- only *.new() does real work.
local M = {}

local store = require("core/store")
local snapshot = require("core/snapshot")
local bankpage = require("ui/bankpage")
local bankutil = require("core/bankutil")
local uikit = require("ui/uikit")
local sharewin = require("ui/sharewin")
local iconwin = require("ui/iconwin")
local detailwin = require("ui/detailwin")

-- Shared plumbing lives in ui/uikit (sounds, the one-tooltip-per-window
-- system, window-chrome repairs); aliased locally so the call sites read
-- as they always did.
local playSfx, playRandomSfx = uikit.PlaySfx, uikit.PlayRandomSfx
local centreTitle, syncWindowChrome = uikit.CentreTitle, uikit.SyncWindowChrome
local setButtonSprites = uikit.SetButtonSprites
local attachDelayedTooltip, hideTip = uikit.AttachDelayedTooltip, uikit.HideTip
local BLOCKED_SFX = uikit.BLOCKED_SFX

-- CLICK is the light "UI notch" on interactive buttons; SAVE is a bigger
-- confirm for "Save current gear".
local CLICK_SFX = uikit.CLICK_SFX
local SAVE_SFX = 20223
-- Bank preset view open/close: a matched pair from one sprite family,
-- played randomly as the client itself does, so toggling reads as one
-- action in one voice.
local BANKVIEW_ON_SFX = { 59077, 59078, 59079, 59080, 59081, 59082 }
local BANKVIEW_OFF_SFX = { 59073, 59074, 59075, 59076 }
local CATEGORY_TOGGLE_SFX = 25537 -- accordion open/close
-- The plugin hub's permissions-button chime, played randomly from its five
-- variants as the client itself does, so it blends in.
local EYE_SFX = { 59087, 59088, 59089, 59090, 59091 }
local DROP_SFX = uikit.DROP_SFX -- confirmed drag-drop: category reordered /
-- preset recategorised (shared with the column's "Move to >")

-- List theme: headers and preset rows are flat rows in one continuous
-- zebra - an expanded header goes soft gold with a thin accent strip
-- uniting it with its rows, hover lifts a single row's fill.
local ROW_ODD = 0x211E1BCC -- zebra bands at 80% alpha; state fills opaque
local ROW_EVEN = 0x2A2622CC
local ROW_HOVER = 0x403728FF
local ROW_SELECTED = 0x49371FFF -- fill while the preset's bank view is live
local ROW_TEXT_RGBA = 0xD7D0BFFF -- preset names
local SELECTED_BORDER = 0xD2A84DFF
local HEADING_TEXT = 0xD1BF9AFF -- category names
local HEADING_EXPANDED = 0x3B3222FF -- soft gold, well under ROW_SELECTED
local HEADING_EXPANDED_HOVER = 0x463A26FF
local ACCENT_W = 2 -- the strip down the far left of an expanded section
local ACCENT_RGBA = 0xD2A84D90
-- 1px separator, drawn only where a header sits below an EXPANDED card -
-- without it, back-to-back expanded sections merge their accent strips.
local CARD_SEP_RGBA = 0x756C60FF
-- Header collapse chevron, far right of the row.
local ARROW_SPRITE = 8085
local ARROW_COLLAPSED_DEG = 270 -- anticlockwise 270 = 90 clockwise: up -> right
local ARROW_EXPANDED_DEG = 180 -- half turn: up -> down
local ARROW_SIZE = 16
local ARROW_PAD = 4 -- chevron inset from the row's right edge
-- Headers and rows share one MUSEO face - a step up from bucolumn's
-- smallest, since the window has more room than the bank sidebar. Guarded
-- like uikit.SmallFont: a missing enum reads -1, never nil.
local LIST_FONT = (function()
  local f = nil
  pcall(function() f = id.Font.MUSEO_SANS_13PT_REGULAR end)
  if type(f) == "number" and f >= 0 then return f end
  return (uikit.SmallFont())
end)()

local WIN_W, WIN_H = 360, 440
local BORDER, TITLE_H = 8, 32 -- PrettyUI Window chrome metrics
local SCROLLBAR_W = 18
local USABLE = WIN_W - BORDER * 2 - SCROLLBAR_W
local TOP_Y = 8
-- The top-right icon cluster: 26px buttons, 6px gaps, left to right
-- SEARCH / EDIT / + / IMPORT. Positions derive from the slot index counting
-- from the RIGHT, so adding or removing one is a change to TOP_BTN_COUNT.
-- Everything else centred in the top bar spans USABLE minus this.
local TOP_BTN, TOP_BTN_GAP = 26, 6
local TOP_BTN_COUNT = 4
local TOP_BTNS_W = TOP_BTN_COUNT * (TOP_BTN + TOP_BTN_GAP) - TOP_BTN_GAP
-- Slot 1 is the FAR RIGHT button, slot 2 its left neighbour, and so on.
local function topBtnX(slotFromRight)
  return USABLE - slotFromRight * (TOP_BTN + TOP_BTN_GAP) + TOP_BTN_GAP
end
local TOP_SLOT_IMPORT, TOP_SLOT_PLUS, TOP_SLOT_EDIT, TOP_SLOT_SEARCH = 1, 2, 3, 4
-- Import-code icon, shared look with the BankUtil column's import button.
local IMPORT_SPRITE = 29456
local LIST_Y = 50
local ROW_H = 30 -- headers use the same height: they are rows in the flow
local CAT_INDENT = 8 -- extra left indent on rows sitting under a header
local UNCAT = "Uncategorised"
-- Sentinel pseudo-category holding every preset when categories are off. The
-- \0 makes it impossible to collide with a real (user-typed) category name.
local FLAT = "\0flat"

-- Collapse state is SESSION-ONLY, in memory: every category starts
-- collapsed each session, and nothing about it touches PersistentDB.
local expandedCats = {}
local function isCollapsed(cat)
  return expandedCats[cat] ~= true
end
local function setCollapsed(cat, collapsed)
  if cat == nil then return end
  expandedCats[cat] = (not collapsed) or nil -- never keep false entries
end

-- The lock-state notice, up to NOTICE_LINES short lines: the reason, then
-- the way out of it. Shared with the BankUtil column (M.LockLines) so the
-- two surfaces always say the same thing.
local NOTICE_LINES = 4
local function lockLines(lockState)
  return (lockState == "resolving" and { "Identifying character..." })
    or (lockState == "nopermission" and { "Tracking permission required",
      "Turn it back on", "or turn off multi-character",
      "to return to a shared vault" })
    or (lockState == "unclaimed" and { "No vault owner set",
      "Re-tick Multi-character in settings" })
    or (lockState ~= nil and { "Character not identified" })
    or {}
end

-- ---- module state -----------------------------------------------------------
local host -- the plugin build layer the windows live in
local win -- prettyui.Window (main vault)
local rowPool = {} -- reusable preset-row widget sets
local headerPool = {} -- reusable category-header widget sets
local hintPool = {} -- reusable "(drag presets here)" texts
local sepPool = {} -- reusable 1px card separators (see CARD_SEP_RGBA)
local renameField, renameOk -- the single inline category-rename pair
local commitRename -- commits an in-progress category rename (set with the pair)
local ghost -- the single drag ghost (SimpleButton, hidden when idle)
local selectedId = nil -- preset whose detail window is open (row highlight)
local editingCat = nil
local editMode = false -- rename/delete buttons + drag-to-rearrange only when on (persisted)
local dropZones = {}
local rowZones = {} -- { id, y0, y1 } per rendered preset row, for reordering
local saveBtn, searchField -- top bar pair: exactly one of them is visible
local searchClear -- the field's clear icon (uikit.AttachClearButton)
local editBtn, searchBtn -- top bar toggles, reset when the window closes
local plusBtn -- "New category": hidden while categories are switched off
local importBtn -- "Import a preset code": far right of the top-bar cluster
-- (the share + import windows live in ui/sharewin; this module owns when
-- they close, sharewin owns what they are)
local searchQuery = "" -- live preset-name filter; "" = search inactive

-- Case-insensitive name match. `*` is a wildcard; with no `*` the query is a
-- plain substring search, so typing "zuk" finds "Zuk melee" without ceremony.
-- The matcher itself is shared with the Core column (uikit.MatchesSearch).
local function matchesSearch(name)
  return uikit.MatchesSearch(name, searchQuery)
end

-- Edit and search are transient VIEW states, not preferences: closing the
-- window drops both, so it always reopens in the plain browse view.
local function resetTransientModes()
  editMode = false
  searchQuery = ""
  pcall(function() editBtn:SetActive(false) end)
  pcall(function() searchBtn:SetActive(false) end)
  pcall(function() searchField:SetText("") end) -- no callback: won't relayout
  pcall(function() searchClear.SetVisible(false) end)
  pcall(function() searchField.root.hidden = true end)
  pcall(function() saveBtn.root.hidden = false end)
  -- The import box belongs to the vault window that opened it. Left open it
  -- would float with a stale code in it after the bank closed the vault.
  pcall(sharewin.CloseImport)
end
local drag = nil -- { slot } while a button drag is live
local dragTick -- forward declaration: per-tick drag driver (drag section)
local editHint -- "Drag items to rearrange" text, shown in edit mode
local lockNotice -- why the vault is empty when a character can't be identified
local emptyNotice -- two-line "No presets yet" hint on an empty, unlocked vault
local userClosed = false
-- "Open vault window" pressed (settings or ribbon); the X clears it. In
-- memory only, so the window always starts hidden after a load.
local wantOpen = false
local layoutGuard = false -- suppress onToggle while relayout() syncs state
local relayout -- forward declaration

-- ---- time-based UI, driven by the uikit heartbeat ----------------------------
-- Tooltips and the drag ghost run off uikit's single Event.Logic
-- subscription; uikit.Now() is the timebase (~50 ticks/s).
uikit.AddTicker("pvWindowDrag", function()
  if dragTick then dragTick() end
end)

-- ---- drag plumbing -----------------------------------------------------------
local function ensureGhost()
  if ghost then return ghost end
  ghost = prettyui.SimpleButton.new(host, "x", nil,
    { width = 120, height = 26, categoryID = "auto" })
  ghost.root.clickthrough = true
  ghost.root.enabled = false
  ghost.root.hidden = true
  pcall(function() ghost.root.alpha = 0.5 end)
  pcall(function()
    for _, part in pairs(ghost.parts) do part.alpha = 0.5 end
    ghost.content.alpha = 0.5
  end)
  return ghost
end

-- The mouse's Y in scrolled CONTENT coords (what drop zones are recorded in),
-- or nil when the cursor is outside the content column.
local function contentMouseY()
  local m = Mouse.GetPosition()
  if not m or not win then return nil end
  local mx = m.x - (win.root.x + BORDER)
  if mx < 0 or mx > USABLE + SCROLLBAR_W then return nil end
  local scrollY = (win._scroll and win._scroll.scrollY) or 0
  return m.y - (win.root.y + TITLE_H) + scrollY
end

-- The category band under the mouse.
local function zoneAtMouse()
  local my = contentMouseY()
  if my == nil then return nil end
  for _, z in ipairs(dropZones) do
    if my >= z.y0 and my < z.y1 then return z end
  end
  return nil
end

-- True when the mouse currently sits inside a slot's own band (content
-- coords) - the release-side "was this actually a click ON the thing" test.
local function mouseOnSurf(slot)
  local my = contentMouseY()
  if my == nil then return false end
  local m = Mouse.GetPosition()
  local mx = m.x - (win.root.x + BORDER)
  return mx >= (slot.surfX or 0)
    and mx <= (slot.surfX or 0) + (slot.surfW or 0)
    and my >= (slot.surfY or 0)
    and my < (slot.surfY or 0) + (slot.surfH or 0)
end

-- True while the pointer sits over one of the vault's own satellite windows
-- (icon picker, detail, share, import) - the edit-mode surfaces ignore the
-- press stream then.
local function mouseOverSatellite()
  local m = Mouse.GetPosition()
  if m == nil then return false end
  local function over(w)
    if not w then return false end
    local hit = false
    pcall(function()
      local r = w.root
      if r == nil or r.hidden then return end
      hit = m.x >= r.x and m.x < r.x + r.width
        and m.y >= r.y and m.y < r.y + r.height
    end)
    return hit
  end
  if over(iconwin.Window()) then return true end
  if over(detailwin.Window()) then return true end
  local shareW, importW = sharewin.Windows()
  return over(shareW) or over(importW)
end

-- The preset row under the mouse, for drag-to-reorder. Rows sit inside
-- category bands, so a drop can resolve to both a zone and a row.
local function rowAtMouse()
  local my = contentMouseY()
  if my == nil then return nil end
  for _, r in ipairs(rowZones) do
    if my >= r.y0 and my < r.y1 then return r end
  end
  return nil
end

-- Hold-and-MOVE to drag. Each slot has an INVISIBLE drag surface
-- (ui.Layer) over its button, shown in edit mode only, which owns press
-- and hold there. Headers stay openable without leaving edit mode, but the
-- CLICK that toggles them is decided by US on ONRELEASE (press ends, no
-- drag started, cursor still on the banner) - native ONCLICK is ignored
-- entirely. Preset buttons get no click at all; in edit mode they are drag
-- handles. After any toggle, a stationary-cursor GRACE window stops the
-- shifted layout being grabbed or re-toggled by the same flurry of
-- presses.
--
-- A press ARMS a drag; it STARTS once the cursor travels DRAG_DEADZONE px
-- while held, so plain clicks stay clicks. On drag start the HELD surface
-- expands over the whole window, and the ghost follows Mouse.GetPosition
-- every Logic tick.
local DRAG_DEADZONE = 6 -- px of travel while held before a drag starts
local armed = nil -- { slot, x, y, tick }: press waiting to cross the deadzone
local lastDragEnd = -10 -- uikit.Now() when the last drag finished (click suppression)
-- After a toggle the rows shift under the cursor. While the cursor stays
-- PARKED where it toggled, the drag surfaces neither arm a drag nor toggle
-- again - so the press that caused the shift cannot cascade onto whatever
-- slid into its place. Moving the cursor to aim ends the grace at once.
local TOGGLE_GRACE_TICKS = 30 -- ~0.6s
local TOGGLE_GRACE_R2 = 144 -- 12px radius, squared
local toggleGrace = -100 -- uikit.Now() of the last edit-mode toggle
local togglePos = nil -- mouse position at that toggle
local function inToggleGrace()
  if (uikit.Now() - toggleGrace) >= TOGGLE_GRACE_TICKS then return false end
  if togglePos == nil then return true end
  local m = Mouse.GetPosition()
  if m == nil then return true end
  local dx, dy = m.x - togglePos.x, m.y - togglePos.y
  return dx * dx + dy * dy < TOGGLE_GRACE_R2
end
local finishDrag -- forward declaration

-- restore a slot's drag surface to the geometry relayout gave it
local function restoreSurf(slot)
  if not slot.dragSurf then return end
  slot.dragSurf:SetPos(slot.surfX or 0, slot.surfY or 0)
  slot.dragSurf:SetSize(slot.surfW or 10, slot.surfH or 10)
end

finishDrag = function(commit)
  armed = nil
  if not drag then return end
  local d = drag
  drag = nil
  lastDragEnd = uikit.Now()
  if ghost then ghost.root.hidden = true end
  pcall(function() restoreSurf(d.slot) end)
  if commit then
    local ok, err = pcall(function()
      -- Resolve BOTH: a drop can change a preset's category and its position
      -- in one gesture. Header slots ignore the row.
      local z = zoneAtMouse()
      if z and d.slot.onDrop then d.slot.onDrop(z, rowAtMouse()) end
    end)
    if not ok then log(formatStr("[PV] drop failed: {}", tostring(err))) end
  end
end

local function cancelDrag()
  finishDrag(false)
end

local function startDrag(slot)
  drag = { slot = slot }
  local g = ensureGhost()
  local text = slot.dragText or ""
  g.content.content = text
  local w = 120
  pcall(function() w = math.min(prettyui.SimpleButton.getSize(text), 220) end)
  g.root:SetSize(w, 26)
  g.root.hidden = false
  -- expand the HELD surface over the window content (capture trick)
  slot.dragSurf:SetPos(0, 0)
  slot.dragSurf:SetSize(USABLE + SCROLLBAR_W, math.max(win.contentHeight or 0, WIN_H))
  pcall(function() slot.dragSurf:MoveToFront() end)
  pcall(function() g.root:MoveToFront() end) -- ghost above the capture
end

-- Per-tick while a drag is live; called from the pvTipTick Logic handler.
dragTick = function()
  if not drag then return end
  pcall(function()
    local m = Mouse.GetPosition()
    if m and ghost then ghost.root:SetPos(m.x + 14, m.y - 13) end
  end)
end

-- Build + wire a slot's drag surface (parent = the window content). Reads
-- slot.dragText / slot.onDrop / slot.noDrag / slot.header at event time, so
-- one wiring serves whatever the pooled slot currently displays.
local function attachDrag(slot, parent)
  local surf = ui.Layer.new(parent)
  surf.clickthrough = false
  surf.hidden = true
  slot.dragSurf = surf
  -- forward wheel events to the window scroll instead of swallowing them
  pcall(function() surf:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", win._onScrollWheel) end)

  surf:Subscribe(ui.Hook.ONHOLD, function()
    local ok, err = pcall(function()
      if drag then return end
      -- within the post-toggle grace the layout just moved: don't arm
      if inToggleGrace() then return end
      -- a press inside an overlapping satellite window is not ours
      if mouseOverSatellite() then return end
      local m = Mouse.GetPosition()
      if not m then return end
      -- ONHOLD streams roughly every tick while held; a LONG gap means the
      -- previous press ended without ONRELEASE (cursor slid off the
      -- surface) - treat this hold as a FRESH press or stale coords would
      -- instant-drag it.
      if not armed or armed.slot ~= slot or (uikit.Now() - (armed.tick or 0)) > 10 then
        armed = { slot = slot, x = m.x, y = m.y, tick = uikit.Now() }
        return
      end
      armed.tick = uikit.Now()
      if slot.noDrag then return end
      local dx, dy = m.x - armed.x, m.y - armed.y
      if dx * dx + dy * dy >= DRAG_DEADZONE * DRAG_DEADZONE then
        armed = nil
        startDrag(slot)
      end
    end)
    if not ok then log(formatStr("[PV] drag failed: {}", tostring(err))) end
  end)
  -- The CLICK is decided here, on ONRELEASE - never from ui.Hook.ONCLICK.
  -- A header toggles only when the press ends with NO drag started and the
  -- cursor is still over the header's band. Preset slots have no
  -- slot.header, so their release does nothing and their clicks die with
  -- the surface.
  local function onRelease()
    armed = nil
    if drag ~= nil then
      if drag.slot == slot then finishDrag(true) end
      return -- a release during someone's drag is never a click
    end
    if slot.header == nil then return end
    local ok, err = pcall(function()
      if (uikit.Now() - lastDragEnd) < 2 then return end
      if inToggleGrace() then return end
      if not mouseOnSurf(slot) then return end
      -- a release inside an overlapping satellite window is not a click here
      if mouseOverSatellite() then return end
      toggleGrace = uikit.Now()
      togglePos = Mouse.GetPosition()
      local h = slot.header
      h:SetExpanded(not h.expanded)
      if h.onToggle then h.onToggle(h, h.expanded) end
    end)
    if not ok then log(formatStr("[PV] header toggle failed: {}", tostring(err))) end
  end
  surf:Subscribe(ui.Hook.ONRELEASE, onRelease)
  -- ONDRAGCOMPLETE gets a drag-only variant: if both events fire for one
  -- release, the toggle must not run twice.
  pcall(function()
    surf:Subscribe(ui.Hook.ONDRAGCOMPLETE, function()
      armed = nil
      if drag and drag.slot == slot then finishDrag(true) end
    end)
  end)
  -- Hover forwarding: the surface sits over the slot's own hover target, so
  -- the row look would otherwise go dead in edit mode.
  surf:Subscribe(ui.Hook.ONMOUSEOVER, function()
    if drag then return end
    if slot.header then pcall(function() slot.header:SetHovered(true) end)
    elseif slot.setHovered then pcall(function() slot.setHovered(true) end) end
  end)
  surf:Subscribe(ui.Hook.ONMOUSELEAVE, function()
    if slot.header then pcall(function() slot.header:SetHovered(false) end)
    elseif slot.setHovered then pcall(function() slot.setHovered(false) end) end
  end)
end

-- ---- list pools ----------------------------------------------------------------
-- A preset row: zebra band with hover and selected fills, a gold border
-- while its bank view is live, optional icon and name. The band is a rect;
-- an invisible ui.Button over it takes the click and the hover.
local function applyRowLook(s)
  pcall(function()
    local fill = s.base or ROW_ODD
    if s.active then
      fill = ROW_SELECTED
    elseif s.hovered then
      fill = ROW_HOVER
    end
    s.bg.rgba = fill
    s.border.hidden = not s.active
  end)
end

local function ensureRowSlot(i)
  local s = rowPool[i]
  if s then return s end
  local body = win.content
  s = {}
  rowPool[i] = s

  s.bg = ui.Rectangle.new(body)
  s.bg.fill = true
  s.bg.clickthrough = true
  s.bg.hidden = true
  -- the thin far-left strip uniting a category's rows with their header
  s.accent = ui.Rectangle.new(body)
  s.accent.fill = true
  s.accent.rgba = ACCENT_RGBA
  s.accent.clickthrough = true
  s.accent.hidden = true
  s.border = ui.Rectangle.new(body)
  s.border.fill = false
  pcall(function() s.border.outlineThickness = 1 end)
  s.border.rgba = SELECTED_BORDER
  s.border.clickthrough = true
  s.border.hidden = true

  s.icon = ui.Sprite.new(body)
  s.icon:SetSize(24, 24)
  s.icon.clickthrough = true
  s.icon.hidden = true

  s.text = ui.Text.new(body)
  s.text.font = LIST_FONT
  s.text.rgba = ROW_TEXT_RGBA
  pcall(function() s.text.alignVertical = ui.AlignMode.CENTRE end)
  s.text.maxLines = 1
  s.text.clickthrough = true
  s.text.hidden = true

  -- hover state forwarded from the edit-mode drag surface overlaying the row
  s.setHovered = function(hov)
    s.hovered = hov == true
    applyRowLook(s)
  end

  -- The invisible click target: toggles the bank preset view (the headline
  -- act); the row stays visually active while this preset owns the bank.
  s.btn = ui.Button.new(body)
  s.btn.alpha = 0
  s.btn.text.content = ""
  s.btn.hidden = true
  s.btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
    s.setHovered(true)
    return true
  end)
  s.btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
    s.setHovered(false)
    return true
  end)
  s.btn:Subscribe(ui.Hook.ONCLICK, function()
    -- Edit mode: the drag surface overlays the row, so this only fires for
    -- clicks landing right of the surface's span - never toggle from there.
    if editMode then return end
    -- Bank views only work on an open bank: block the click with an instant,
    -- self-dismissing hint instead of letting Show() fail quietly.
    if not bankpage.IsBankOpen() then
      playSfx(BLOCKED_SFX)
      uikit.ShowInstantTip(s.btn, "Bank not in view", nil,
        uikit.TIP_BLOCKED_TICKS)
      return
    end
    local ok, err = pcall(function()
      if not s.preset then return end
      -- With Core registered the row drives a Core view instead of
      -- our panel engine. This is the ONLY place a view is opened, so the
      -- two engines are mutually exclusive by routing.
      if bankutil.IsActive() then
        if bankutil.ActivePresetId() == s.preset.id then
          bankutil.Hide()
          playRandomSfx(BANKVIEW_OFF_SFX)
        else
          local shown, why = bankutil.ShowPreset(s.preset)
          if shown then
            playRandomSfx(BANKVIEW_ON_SFX)
          elseif why == "not_all_items" then
            -- same treatment as the panel engine's wrong-tab refusal
            bankpage.FlashWrongTab()
          else
            -- bank_closed / preset_open / busy / failed: Core shows no
            -- notice of its own, so chime + name the reason briefly
            playSfx(BLOCKED_SFX)
            uikit.ShowInstantTip(s.btn,
              why == "preset_open" and "Close the bank's preset panel first"
              or "Bank view unavailable (" .. tostring(why) .. ")",
              nil, uikit.TIP_BLOCKED_TICKS)
          end
        end
        relayout() -- refresh the active highlight
        return
      end
      -- activePresetId alone decides the toggle.
      if bankpage.activePresetId == s.preset.id then
        bankpage.Restore()
        playRandomSfx(BANKVIEW_OFF_SFX)
      else
        -- Show plays its OWN refusal chime (wrong tab) - only chime the
        -- click when it actually opened, or the two sounds overlap.
        if bankpage.Show(s.preset) ~= false then playRandomSfx(BANKVIEW_ON_SFX) end
      end
      relayout() -- refresh the active highlight
    end)
    if not ok then log(formatStr("[PV] bank toggle failed: {}", tostring(err))) end
  end)
  -- forward wheel events to the window scroll instead of swallowing them
  pcall(function() s.btn:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", win._onScrollWheel) end)
  -- hover: normal delayed tooltip only while the bank is open; with it closed
  -- the hover shows nothing - the "Bank not in view" hint is click-only
  attachDelayedTooltip(s.btn, function()
    if not bankpage.IsBankOpen() then return nil end
    return "Toggle this preset's bank view"
  end)
  attachDrag(s, body) -- edit-mode drag surface, overlays the row

  -- The bare eye opens/closes the preset preview (detail window) - a plain
  -- sprite like the pencil and bin, no button frame. The hover art doubles
  -- as the open-preview state (_pvActive holds it).
  s.eyeBtn = prettyui.SpriteButton.new(body, "PENCIL", function()
    -- behaviour shared with the BankUtil column's eye (M.ToggleDetail)
    M.ToggleDetail(s.preset)
  end, { size = 22, _onScrollWheel = win._onScrollWheel })
  setButtonSprites(s.eyeBtn, 21346, 21347) -- RS3_WORLDMAP_ICON_OVERVIEW NML/OVR
  attachDelayedTooltip(s.eyeBtn.root, "Preview this preset's contents")

  s.delBtn = prettyui.SpriteButton.new(body, "TRASH", function()
    playSfx(CLICK_SFX)
    local ok, err = pcall(function()
      if not s.preset then return end
      store.Delete(s.preset.id)
      if selectedId == s.preset.id then
        selectedId = nil
        detailwin.Hide()
      end
      relayout()
    end)
    if not ok then log(formatStr("[PV] delete failed: {}", tostring(err))) end
  end, { size = 20, _onScrollWheel = win._onScrollWheel })
  setButtonSprites(s.delBtn, 36552)
  attachDelayedTooltip(s.delBtn.root, "Delete preset")

  return s
end

local function hideRowSlot(s)
  s.preset = nil
  s.hovered = false
  s.active = false
  s.dragSurf.hidden = true
  s.bg.hidden = true
  s.accent.hidden = true
  s.border.hidden = true
  s.icon.hidden = true
  s.text.hidden = true
  s.btn.hidden = true
  s.eyeBtn.root.hidden = true
  s.delBtn.root.hidden = true
end

-- Category header: a flat row - zebra band when collapsed, soft gold with
-- the accent strip when expanded, hover lifting the fill either way, the
-- rotating chevron far right, and an optional category icon before the name.
-- Call-compatible with prettyui.CollapseButton (.root, :SetText,
-- :SetExpanded), but SetExpanded here is SILENT - onToggle fires on user
-- clicks only.
local function makeSectionHeader(parent)
  local h = { expanded = true, hovered = false, base = ROW_ODD }

  h.root = ui.Layer.new(parent)
  h.root:SetSize(100, ROW_H) -- relayout re-sizes per pass
  h.root.clickthrough = false

  h.bg = ui.Rectangle.new(h.root)
  h.bg.fill = true
  h.bg:SetSize(0, ROW_H, 1.0) -- full root width; rows are a fixed height
  h.bg.clickthrough = true
  h.accent = ui.Rectangle.new(h.root)
  h.accent.fill = true
  h.accent.rgba = ACCENT_RGBA
  h.accent:SetSize(ACCENT_W, ROW_H)
  h.accent.clickthrough = true
  h.accent.hidden = true

  h.icon = ui.Sprite.new(h.root)
  h.icon:SetSize(24, 24)
  h.icon:SetPos(4, 5) -- eye-tuned: a touch below centred
  h.icon.clickthrough = true
  h.icon.hidden = true

  h.label = ui.Text.new(h.root)
  h.label.font = LIST_FONT
  h.label.rgba = HEADING_TEXT
  h.label.alignVertical = ui.AlignMode.CENTRE
  h.label.maxLines = 1
  h.label.clickthrough = true

  h.arrow = ui.Sprite.new(h.root)
  h.arrow:SetSize(ARROW_SIZE, ARROW_SIZE) -- square: rotation-pivot-proof
  h.arrow.spriteID = ARROW_SPRITE
  h.arrow:SetPos(-ARROW_SIZE - ARROW_PAD,
    math.floor((ROW_H - ARROW_SIZE) / 2), 1.0)
  h.arrow.clickthrough = true

  local function updateState()
    pcall(function()
      local fill
      if h.expanded then
        fill = h.hovered and HEADING_EXPANDED_HOVER or HEADING_EXPANDED
      else
        fill = h.hovered and ROW_HOVER or h.base
      end
      h.bg.rgba = fill
      h.accent.hidden = not h.expanded
      h.arrow.rotationDegrees = h.expanded and ARROW_EXPANDED_DEG
        or ARROW_COLLAPSED_DEG
    end)
  end

  function h.SetText(_, text) h.label.content = tostring(text or "") end

  -- The category icon, or nil for none; the name shifts to hug the row's
  -- left edge when there is no icon.
  function h.SetIcon(_, spriteId)
    local nameX = 6
    if spriteId ~= nil then
      h.icon.hidden = false
      pcall(function() h.icon.spriteID = spriteId end)
      nameX = 32 -- 24px icon at x 4 + a small gap
    else
      h.icon.hidden = true
    end
    h.label:SetPos(nameX, 0)
    h.label:SetSize(-nameX - ARROW_SIZE - ARROW_PAD - 6, ROW_H, 1.0)
  end

  function h.SetExpanded(_, expanded)
    h.expanded = expanded == true
    updateState()
  end

  -- hover forwarded from the edit-mode drag surface overlaying this header
  function h.SetHovered(_, hov)
    h.hovered = hov == true
    updateState()
  end

  h.root:Subscribe(ui.Hook.ONMOUSEOVER, function()
    h.hovered = true
    updateState()
  end)
  h.root:Subscribe(ui.Hook.ONMOUSELEAVE, function()
    h.hovered = false
    updateState()
  end)
  -- Edit mode ignores this: toggling belongs to the drag surface then.
  h.root:Subscribe(ui.Hook.ONCLICK, function()
    if editMode then return end
    local ok, err = pcall(function()
      h:SetExpanded(not h.expanded)
      if h.onToggle then h.onToggle(h, h.expanded) end
    end)
    if not ok then log(formatStr("[PV] header toggle failed: {}", tostring(err))) end
  end)
  -- forward wheel events to the window scroll instead of swallowing them
  pcall(function() h.root:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", win._onScrollWheel) end)

  h:SetIcon(nil)
  updateState()
  return h
end

local function ensureHeaderSlot(i)
  local s = headerPool[i]
  if s then return s end
  local body = win.content
  s = {}
  headerPool[i] = s

  s.header = makeSectionHeader(body)
  attachDrag(s, body) -- edit-mode drag surface, overlays the banner
  -- onToggle fires on USER clicks only (programmatic SetExpanded is silent,
  -- and layoutGuard covers relayout), so the chime can live here.
  s.header.onToggle = function(_, expanded)
    if layoutGuard then return end
    playSfx(CATEGORY_TOGGLE_SFX)
    local ok, err = pcall(function()
      if s.cat then setCollapsed(s.cat, not expanded) end
      relayout()
    end)
    if not ok then log(formatStr("[PV] collapse failed: {}", tostring(err))) end
  end

  s.renameBtn = prettyui.SpriteButton.new(body, "PENCIL", function()
    playSfx(CLICK_SFX)
    if s.cat then
      editingCat = s.cat
      pcall(relayout)
    end
  end, { size = 20, _onScrollWheel = win._onScrollWheel })
  setButtonSprites(s.renameBtn, 20983, 20984)
  attachDelayedTooltip(s.renameBtn.root, "Rename category")

  -- Opens the icon picker for this category; same sprite as the detail
  -- window's icon button.
  s.iconBtn = prettyui.SpriteButton.new(body, "SWAP", function()
    playSfx(CLICK_SFX)
    local ok, err = pcall(function()
      if s.cat then
        iconwin.OpenForCategory(s.cat, win and win.root.x, win and win.root.y)
      end
    end)
    if not ok then log(formatStr("[PV] icon picker failed: {}", tostring(err))) end
  end, { size = 24, _onScrollWheel = win._onScrollWheel })
  setButtonSprites(s.iconBtn, 36153)
  attachDelayedTooltip(s.iconBtn.root, "Choose an icon for this category")

  s.delBtn = prettyui.SpriteButton.new(body, "TRASH", function()
    playSfx(CLICK_SFX)
    local ok, err = pcall(function()
      if not s.cat then return end
      store.DeleteCategory(s.cat) -- presets fall back to Uncategorised
      if editingCat == s.cat then editingCat = nil end
      relayout()
    end)
    if not ok then log(formatStr("[PV] delete category failed: {}", tostring(err))) end
  end, { size = 20, _onScrollWheel = win._onScrollWheel })
  setButtonSprites(s.delBtn, 36552)
  attachDelayedTooltip(s.delBtn.root, "Delete category (presets kept)")

  return s
end

local function hideHeaderSlot(s)
  s.cat = nil
  s.dragSurf.hidden = true
  s.header.root.hidden = true
  s.renameBtn.root.hidden = true
  s.iconBtn.root.hidden = true
  s.delBtn.root.hidden = true
end

-- Card separators: pooled 1px lines (see CARD_SEP_RGBA). MoveToFront on
-- every placement: a pooled separator can be OLDER than a header bg the
-- pool grew later, and siblings render in creation order.
local function ensureSep(i)
  local sp = sepPool[i]
  if sp then return sp end
  sp = ui.Rectangle.new(win.content)
  sp.fill = true
  sp.rgba = CARD_SEP_RGBA
  sp.clickthrough = true
  sepPool[i] = sp
  return sp
end

-- The "(drag presets here)" hint of an empty category: a full row in the
-- zebra flow - band, accent strip and the muted text.
local function ensureHint(i)
  local hint = hintPool[i]
  if hint then return hint end
  hint = {}
  hint.bg = ui.Rectangle.new(win.content)
  hint.bg.fill = true
  hint.bg.clickthrough = true
  hint.accent = ui.Rectangle.new(win.content)
  hint.accent.fill = true
  hint.accent.rgba = ACCENT_RGBA
  hint.accent.clickthrough = true
  hint.text = prettyui.Text.new(win.content, {
    text = "(drag presets here)",
    x = 20, y = 0,
    height = 16,
    colour = 0x8A7B5C99,
    _onScrollWheel = win._onScrollWheel,
  })
  hintPool[i] = hint
  return hint
end

local function hideHint(hint)
  hint.bg.hidden = true
  hint.accent.hidden = true
  hint.text.hidden = true
end

local function ensureRenamePair()
  if renameField then return end
  local body = win.content
  local function commit()
    local ok, err = pcall(function()
      local old = editingCat
      editingCat = nil
      if old then
        local newName = renameField:GetText()
        if newName ~= nil and newName ~= "" and newName ~= old then
          setCollapsed(newName, isCollapsed(old)) -- carry this session's state
          store.RenameCategory(old, newName)
        end
      end
      relayout()
    end)
    if not ok then log(formatStr("[PV] rename category failed: {}", tostring(err))) end
  end
  commitRename = commit
  renameField = prettyui.TextField.new(body, {
    x = 0, y = 0,
    width = USABLE - 62, -- room for OK on the right
    height = 26,
    maxLength = 25,
    placeholder = "Category name",
    onSubmit = commit,
    _onScrollWheel = win._onScrollWheel,
  })
  renameField.root.hidden = true
  renameOk = prettyui.SimpleButton.new(body, "OK", function()
    playSfx(CLICK_SFX)
    commit()
  end, {
    x = USABLE - 56, y = 0, width = 56, height = 24,
    _onScrollWheel = win._onScrollWheel,
  })
  renameOk.root.hidden = true
end

-- ---- layout --------------------------------------------------------------------
relayout = function()
  if not win then return end
  layoutGuard = true
  hideTip()
  cancelDrag()
  ensureRenamePair()
  renameField.root.hidden = true
  renameOk.root.hidden = true

  -- Group presets by category: Uncategorised pinned first, then stored order.
  local groups, order = {}, {}
  groups[UNCAT] = {}
  local catIcons = {} -- header icons by name, read off the same records
  for _, c in ipairs(store.Categories()) do
    if groups[c.name] == nil then
      order[#order + 1] = c.name
      groups[c.name] = {}
      catIcons[c.name] = c.icon
    end
  end
  local filtering = searchQuery ~= ""
  for _, p in ipairs(store.All()) do
    if matchesSearch(p.name) then
      local cat = p.category or UNCAT
      if groups[cat] == nil then
        order[#order + 1] = cat
        groups[cat] = {}
      end
      groups[cat][#groups[cat] + 1] = p
    end
  end
  -- Uncategorised hides entirely when empty - except in edit mode, where it
  -- must stay visible as the drop target that CLEARS a preset's category.
  -- (Named categories always show, even empty.)
  if #groups[UNCAT] > 0 or editMode then
    table.insert(order, 1, UNCAT)
  end
  -- While searching, drop sections with no matches: a bare header over
  -- nothing is noise, and so is the edit-mode "(drag presets here)" hint.
  if filtering then
    local kept = {}
    for _, cat in ipairs(order) do
      if #(groups[cat] or {}) > 0 then kept[#kept + 1] = cat end
    end
    order = kept
  end

  -- Categories off: one undivided list. Category DATA is untouched - we
  -- only stop grouping by it - so switching back on restores every bucket.
  local flatMode = PersistentDB:GetBool("ui.noCategories") == true
  if flatMode then
    local all = {}
    for _, cat in ipairs(order) do
      for _, p in ipairs(groups[cat] or {}) do all[#all + 1] = p end
    end
    groups, order = { [FLAT] = all }, { FLAT }
  end
  if plusBtn then plusBtn.root.hidden = flatMode end -- nothing to add it to
  -- Import slides left when "+" is hidden.
  if importBtn then
    pcall(function()
      importBtn.root:SetPos(
        topBtnX(flatMode and TOP_SLOT_PLUS or TOP_SLOT_IMPORT), TOP_Y)
    end)
  end
  -- Within a category: the user's manual arrangement, unless "Lock preset
  -- order alphabetically" is on - which IGNORES the stored order rather
  -- than destroying it, so unticking brings the arrangement back.
  local orderIdx = nil
  if PersistentDB:GetBool("ui.lockAlpha") ~= true then
    orderIdx = store.PresetOrderIndex()
  end
  for _, g in pairs(groups) do
    table.sort(g, function(a, b)
      if orderIdx ~= nil then
        local ai, bi = orderIdx[a.id], orderIdx[b.id]
        if ai ~= nil and bi ~= nil then
          if ai ~= bi then return ai < bi end
        elseif ai ~= nil then return true   -- ordered entries before unknowns
        elseif bi ~= nil then return false
        end
      end
      return store.NameOrder(a, b)
    end)
  end

  -- Edit-mode banner: dragging lives on the buttons themselves now (no
  -- visible handles), so edit mode announces it, centred under the top bar.
  if editHint == nil then
    editHint = ui.Text.new(win.content)
    editHint:SetPos(0, LIST_Y - 10) -- snug under the top bar
    -- same span as the Save button, so the text centres WITH Save rather
    -- than with the whole window
    editHint:SetSize(USABLE - TOP_BTNS_W, 16)
    editHint.font = id.Font.MUSEO_SANS_15PT_REGULAR
    editHint.rgba = 0xB8A169CC
    editHint.alignHorizontal = ui.AlignMode.CENTRE
    editHint.content = "Drag items to rearrange"
    editHint.clickthrough = true
  end
  -- Per-character vaults: while the character's identity is unknown there is
  -- no vault to open, and store.All() is deliberately empty. Say why, rather
  -- than rendering what looks like a vault that has lost all its presets.
  local lockState = store.Locked() and store.IdentityState() or nil
  -- One Text per line (see lockLines), centred on the window's full usable
  -- width - the lines start below the top button row, so nothing collides.
  if lockNotice == nil then
    lockNotice = {}
    for i = 1, NOTICE_LINES do
      local t = ui.Text.new(win.content)
      t:SetPos(0, LIST_Y - 10 + (i - 1) * 19)
      t:SetSize(USABLE, 16)
      t.font = id.Font.MUSEO_SANS_15PT_REGULAR
      t.rgba = (i == 1) and 0xE0B050FF or 0xB8A169CC -- reason gold, hint muted
      t.alignHorizontal = ui.AlignMode.CENTRE
      t.clickthrough = true
      lockNotice[i] = t
    end
  end
  local lines = lockLines(lockState)
  for i = 1, NOTICE_LINES do
    lockNotice[i].content = lines[i] or ""
    lockNotice[i].hidden = lines[i] == nil
  end
  editHint.hidden = not editMode or lockState ~= nil

  -- Two-line empty-vault hint, mirroring the BankUtil column's. Visibility
  -- is decided AFTER the layout loop (needs to know nothing rendered); the
  -- components are just built here, hidden, beside the lock notice.
  if emptyNotice == nil then
    emptyNotice = {}
    for i = 1, 2 do
      local t = ui.Text.new(win.content)
      t:SetPos(0, LIST_Y - 10 + (i - 1) * 19)
      t:SetSize(USABLE - TOP_BTNS_W, 16)
      t.font = id.Font.MUSEO_SANS_15PT_REGULAR
      t.rgba = 0xB8A169CC
      t.alignHorizontal = ui.AlignMode.CENTRE
      t.clickthrough = true
      t.hidden = true
      emptyNotice[i] = t
    end
  end

  -- Row width is decided BEFORE layout: count the rows this pass will
  -- show, and stop them short of the scrollbar lane only when the list
  -- will actually overflow into a scrollbar.
  local totalRows = 0
  for _, cat in ipairs(order) do
    local isFlat = (cat == FLAT)
    local freeStanding = isFlat or (cat == UNCAT
      and PersistentDB:GetBool("ui.noUncatBucket") == true)
    local collapsed = (not filtering) and isCollapsed(cat)
    if freeStanding then collapsed = false end
    if not freeStanding then totalRows = totalRows + 1 end
    if not collapsed then
      totalRows = totalRows + #groups[cat]
      if #groups[cat] == 0 and not isFlat then totalRows = totalRows + 1 end
    end
  end
  local listTop = LIST_Y + (editMode and 20 or 0)
  local viewH = nil
  pcall(function() viewH = win._scroll.height end)
  if viewH == nil or viewH <= 1 then
    viewH = (win.root.height or WIN_H) - TITLE_H - BORDER
  end
  local barVisible = (listTop + totalRows * ROW_H + 8) > viewH
  local listW = barVisible and USABLE or (USABLE + SCROLLBAR_W)

  dropZones = {}
  rowZones = {}
  local y = listTop
  local hIdx, rIdx, tIdx, sIdx = 0, 0, 0, 0
  -- ONE continuous zebra from top to bottom - headers count in the
  -- alternation like any other row, and nothing leaves gaps. The list
  -- should read as one cohesive, connected surface.
  local band = 0
  local prevExpandedCard = false

  for _, cat in ipairs(order) do
    local isUncat = (cat == UNCAT)
    local isFlat = (cat == FLAT)
    local zoneStart = y
    -- Searching force-expands: a match hidden inside a collapsed section
    -- would look like no result at all. The session collapse state is read
    -- past, not written, so sections snap back when the search clears.
    local collapsed = (not filtering) and isCollapsed(cat)
    -- Free-standing rows: no header, never collapsible. Used both by "No
    -- Uncategorised section" and by flat mode. The drop zone still covers
    -- the rows, and the edit-mode hint still marks it when empty.
    local freeStanding = isFlat
      or (isUncat and PersistentDB:GetBool("ui.noUncatBucket") == true)
    if freeStanding then collapsed = false end

    if freeStanding then
      -- no header row at all
    else
      -- The previous card ended here: a 1px line marks the boundary, or two
      -- expanded sections back to back would merge their accent strips.
      if prevExpandedCard then
        sIdx = sIdx + 1
        local sp = ensureSep(sIdx)
        sp.hidden = false
        sp:SetPos(0, y)
        sp:SetSize(listW, 1)
        pcall(function() sp:MoveToFront() end)
      end
      if editingCat == cat then
        band = band + 1 -- the rename row keeps its place in the alternation
        renameField.root:SetPos(0, y + 2)
        renameField:SetText(cat)
        renameField.root.hidden = false
        renameOk.root:SetPos(listW - 56, y + 3)
        renameOk.root.hidden = false
      else
        hIdx = hIdx + 1
        local s = ensureHeaderSlot(hIdx)
        s.cat = cat
        s.dragText = cat
        s.onDrop = function(z)
          if z.cat ~= s.cat then
            store.ReorderCategory(s.cat, z.cat) -- "" target = first position
            playSfx(DROP_SFX)
            relayout()
          end
        end
        s.noDrag = isUncat -- Uncategorised is pinned first, never reorderable
        band = band + 1
        s.header.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
        s.header.root.hidden = false
        s.header.root:SetPos(0, y)
        s.header.root:SetSize(listW, ROW_H)
        s.surfX, s.surfY = 0, y
        s.surfW, s.surfH = listW - 88, ROW_H -- clear of the button cluster
        s.dragSurf.hidden = not editMode
        if editMode then restoreSurf(s) end
        s.header:SetText(cat)
        s.header:SetIcon(catIcons[cat])
        -- the chevron's corner belongs to the pencil and bin while editing
        s.header.arrow.hidden = editMode
        s.header:SetExpanded(not collapsed)
        s.renameBtn.root.hidden = isUncat or not editMode
        s.iconBtn.root.hidden = isUncat or not editMode
        s.delBtn.root.hidden = isUncat or not editMode
        if not s.renameBtn.root.hidden then
          -- rename, icon, then - after a wider misclick buffer - the bin,
          -- whose slot matches the rows' so the right column still aligns
          s.renameBtn.root:SetPos(listW - 84, y + 6) -- pencil art reads 1px high
          s.iconBtn.root:SetPos(listW - 60, y + 3) -- 24px: pulled back 2 to centre
          s.delBtn.root:SetPos(listW - 26, y + 5)
        end
      end
      y = y + ROW_H
    end

    if not collapsed then
      for _, p in ipairs(groups[cat]) do
        rIdx = rIdx + 1
        local s = ensureRowSlot(rIdx)
        s.preset = p
        s.dragText = p.name
        s.onDrop = function(z, row)
          if not s.preset then return end
          -- A drop can do two things at once: move the preset to another
          -- category AND place it at a position. Both are no-ops when nothing
          -- actually changes, so a drop back where it started stays silent
          -- and skips the pointless store write + relayout.
          local changed = false
          if not z.flat and (s.preset.category or "") ~= z.cat then
            store.SetCategory(s.preset.id, z.cat) -- "" clears the category
            changed = true
          end
          -- Reordering is the only part the alphabetical lock disables;
          -- dragging between categories stays available either way.
          if PersistentDB:GetBool("ui.lockAlpha") ~= true
            and row ~= nil and row.id ~= s.preset.id then
            store.ReorderPreset(s.preset.id, row.id)
            changed = true
          end
          if changed then
            playSfx(DROP_SFX)
            relayout()
          end
        end
        band = band + 1
        s.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
        s.bg.hidden = false
        s.bg:SetPos(0, y)
        s.bg:SetSize(listW, ROW_H)
        -- the strip only unites HEADED sections with their header; flat
        -- mode and free-standing Uncategorised rows go without
        s.accent.hidden = freeStanding
        if not freeStanding then
          s.accent:SetPos(0, y)
          s.accent:SetSize(ACCENT_W, ROW_H)
        end
        s.border:SetPos(0, y)
        s.border:SetSize(listW, ROW_H)
        -- Rows under a header take an extra indent, icon included.
        local indent = freeStanding and 0 or CAT_INDENT
        local nameX = 10 + indent
        if p.icon then
          s.icon.hidden = false
          -- 24px icon in a 30px row: x pulled to 4 so a 2px gap stays
          -- before the name at 30, y 3 keeps it centred
          s.icon:SetPos(4 + indent, y + 3)
          pcall(function() s.icon.spriteID = p.icon end)
          nameX = 35 + indent
        else
          s.icon.hidden = true
          -- Align no-icon names: iconless rows take the same indent as
          -- icon'd ones, so every name lines up.
          if PersistentDB:GetBool("ui.alignNamesOff") ~= true then
            nameX = 35 + indent
          end
        end

        -- Right-side reserve: just the eye normally, eye + bin in edit mode.
        local reserve = editMode and 64 or 30
        s.text.hidden = false
        s.text:SetPos(nameX, y)
        s.text:SetSize(math.max(40, listW - nameX - reserve), ROW_H)
        s.text.content = p.name
        s.btn.hidden = false
        s.btn:SetPos(0, y)
        s.btn:SetSize(listW - reserve, ROW_H) -- clear of the buttons
        s.surfX, s.surfY = 0, y
        s.surfW, s.surfH = listW - reserve, ROW_H
        s.dragSurf.hidden = not editMode
        if editMode then restoreSurf(s) end
        -- whichever engine owns the bank view supplies the highlight
        s.active = (bankutil.IsActive()
          and bankutil.ActivePresetId()
          or bankpage.activePresetId) == p.id
        applyRowLook(s)

        s.eyeBtn.root.hidden = false
        -- The eye takes the row's corner slot; edit mode slides it left to
        -- make way for the bin. 22px, placed so its centre matches the
        -- neighbouring 20px and 24px button columns.
        s.eyeBtn.root:SetPos(editMode and (listW - 59) or (listW - 27), y + 4)
        s.eyeBtn._pvActive = selectedId == p.id -- bright while its preview is open
        pcall(function() s.eyeBtn:_UpdateState() end)
        s.delBtn.root.hidden = not editMode
        if editMode then s.delBtn.root:SetPos(listW - 26, y + 5) end
        -- Reorder target: the band this row occupies, in the same scrolled
        -- content coords as dropZones.
        rowZones[#rowZones + 1] = { id = p.id, y0 = y, y1 = y + ROW_H }
        y = y + ROW_H
      end
      -- Empty categories always show the hint; flat mode never does.
      if #groups[cat] == 0 and not isFlat then
        tIdx = tIdx + 1
        local t = ensureHint(tIdx)
        band = band + 1
        t.bg.rgba = (band % 2 == 1) and ROW_ODD or ROW_EVEN
        t.bg.hidden = false
        t.bg:SetPos(0, y)
        t.bg:SetSize(listW, ROW_H)
        t.accent.hidden = freeStanding
        if not freeStanding then
          t.accent:SetPos(0, y)
          t.accent:SetSize(ACCENT_W, ROW_H)
        end
        t.text:SetPos(12 + CAT_INDENT, y + 7)
        t.text.hidden = false
        y = y + ROW_H
      end
    end
    -- `flat` marks the zone as reorder-only: with categories switched off a
    -- drop must not rewrite the preset's stored category, or toggling the
    -- setting back on would find the buckets quietly emptied.
    dropZones[#dropZones + 1] = {
      cat = isUncat and "" or cat, y0 = zoneStart, y1 = y, flat = isFlat,
    }
    prevExpandedCard = not freeStanding and not collapsed
  end

  for i = rIdx + 1, #rowPool do hideRowSlot(rowPool[i]) end
  for i = hIdx + 1, #headerPool do hideHeaderSlot(headerPool[i]) end
  for i = tIdx + 1, #hintPool do hideHint(hintPool[i]) end
  for i = sIdx + 1, #sepPool do sepPool[i].hidden = true end
  -- Re-front the shown separators AFTER the layout loop: on a pool-growing
  -- pass a separator can be older than a header bg created later, and
  -- siblings render in creation order.
  for i = 1, sIdx do pcall(function() sepPool[i]:MoveToFront() end) end

  -- Empty-vault hint: nothing rendered at all (no rows, no category
  -- headers), vault not locked, not mid-search. Matches the column's rule -
  -- empty categories still count as "shown", so this is a truly empty vault.
  local showEmpty = rIdx == 0 and hIdx == 0 and lockState == nil and not filtering
  local eLines = showEmpty and { "No presets yet", "Press Save Preset" } or {}
  for i = 1, 2 do
    emptyNotice[i].content = eLines[i] or ""
    emptyNotice[i].hidden = eLines[i] == nil
  end

  pcall(function() win:SetContentHeight(y + 8) end)
  layoutGuard = false
  -- The BankUtil sidebar column mirrors this list. One hook at the end of
  -- every relayout covers every mutation that redraws the window (saves,
  -- renames, deletes, drags, imports, collapse, identity changes).
  if M.OnListChanged then pcall(M.OnListChanged) end
end

-- Bank-page view changes that originate outside this window's own buttons
-- (tab redirect, bank close, internal rebuilds) refresh the row states here
-- - e.g. the active banner un-toggles when a deposit force-switches tabs.
bankpage.OnViewChanged = function()
  if win and not layoutGuard then pcall(relayout) end
end
-- The Core-backed view dies outside our buttons too (native tab click,
-- another plugin's page, bank close) - same refresh, via Core's callbacks.
bankutil.OnViewChanged = bankpage.OnViewChanged

-- ---- window lifecycle ------------------------------------------------------------
M.Destroy = function()
  if editingCat and commitRename then pcall(commitRename) end -- keep typed rename
  cancelDrag()
  hideTip()
  layoutGuard = true
  iconwin.Destroy()
  detailwin.Destroy()
  if ghost then
    pcall(function() ghost:Destroy() end)
    ghost = nil
  end
  uikit.DestroyTips()
  if win then
    pcall(function() win:Destroy() end)
    win = nil
  end
  rowPool, headerPool, hintPool, sepPool = {}, {}, {}, {}
  renameField, renameOk, commitRename = nil, nil, nil
  layoutGuard = false
end

local function buildWindow(parent, x, y)
  M.Destroy()
  host = parent
  if prettyui == nil then
    log("[PV] prettyui dependency missing - cannot build UI")
    return
  end
  local ok, err = pcall(function()
    win = prettyui.Window.new(parent, {
      categoryID = "auto",
      title = "Preset Vault",
      x = x, y = y,
      width = WIN_W, height = WIN_H,
      minWidth = WIN_W, minHeight = 220,
      onClose = function()
        -- Mid-rename close (X or bank closing): keep whatever was typed.
        if editingCat and commitRename then pcall(commitRename) end
        userClosed = true -- stay hidden until the bank closes
        wantOpen = false -- an opened-on-demand window is dismissed by its X
        -- closing the vault also cancels any active preset bank view, so the
        -- bank unlocks without hunting for the preset's own B button
        -- (both calls no-op when no view is active; only one can ever be)
        pcall(bankpage.Restore)
        pcall(bankutil.Hide)
        detailwin.Hide()
        -- Fires for BOTH the X and a programmatic win:Close() (bank closing),
        -- so this is the single place transient view state is dropped.
        resetTransientModes()
      end,
    })
    centreTitle(win)
    -- Tooltips with no explicit parent land in this window's content.
    uikit.SetDefaultTipParent(win.content)
    -- Hand each satellite module what it needs of ours (one-directional:
    -- none of them require pvwin back, or the cycle would hand one side a
    -- half-initialised module).
    sharewin.Configure({
      host = host,
      relayout = function() pcall(relayout) end,
      expandUncat = function() setCollapsed(UNCAT, false) end,
      shareAnchor = function() return detailwin.Position() end,
      importAnchor = function()
        if win then return win.root.x, win.root.y end
      end,
    })
    iconwin.Configure({
      host = host,
      relayout = function() pcall(relayout) end,
    })
    detailwin.Configure({
      host = host,
      relayout = function() pcall(relayout) end,
      -- the detail window opens parked against the vault window's right edge
      anchor = function()
        if win then return win.root.x + win.root.width + 6, win.root.y end
      end,
      -- fires on the detail window's X and any programmatic Close
      onClosed = function()
        selectedId = nil
        if not layoutGuard then pcall(relayout) end
      end,
      -- a rename in the detail window updates the visible row label in place
      renameRow = function(id, name)
        for _, s in ipairs(rowPool) do
          if s.preset and s.preset.id == id and not s.text.hidden then
            s.preset.name = name
            s.text.content = name
            s.dragText = name
          end
        end
      end,
    })

    -- Centred between the left border and the top-right cluster; the
    -- search field reuses saveX/saveW so it lands in the button's exact
    -- footprint.
    --
    -- The LABEL is fitted to the button, longest-that-fits, because the
    -- button cannot be fitted to the label.
    local saveAvail = USABLE - TOP_BTNS_W - TOP_BTN_GAP
    local saveLabel, saveW
    for _, candidate in ipairs({ "Save Preset", "Save" }) do
      saveLabel = candidate
      saveW = prettyui.FancyButton.getSize(candidate)
      if saveW <= saveAvail then break end
    end
    local saveX = math.max(0, math.floor((saveAvail - saveW) / 2))
    -- The behaviour lives in M.SaveCurrentGear (shared with the BankUtil
    -- sidebar column, which has its own Save button).
    saveBtn = prettyui.FancyButton.new(win.content, saveLabel, function()
      M.SaveCurrentGear()
    end, { x = saveX, y = TOP_Y, variant = "positive" })
    -- Spells out what a shortened label drops. Always attached, so the text
    -- is the same whichever label the fit loop picked.
    attachDelayedTooltip(saveBtn.root,
      "Save your current gear and backpack as a new preset")

    -- Search field occupies the Save button's exact slot - same x, same width.
    -- The two are never shown together. Built once (component budget), hidden
    -- until search is on.
    searchField = prettyui.TextField.new(win.content, {
      x = saveX, y = TOP_Y,
      width = saveW,
      height = 26,
      maxLength = 25,
      placeholder = "Search...",
      -- Wider right margin so the text scrolls before it reaches the
      -- clear icon parked in the field's right edge.
      contentMargin = ui.Margin.new(8, 3, 26, 0),
      onChange = function(f)
        -- Read the field, NOT the callback's content arg.
        searchQuery = f:GetText() or ""
        pcall(function() searchClear.SetVisible(searchQuery ~= "") end)
        pcall(relayout)
      end,
      _onScrollWheel = win._onScrollWheel,
    })
    searchField.root.hidden = true
    -- Clear icon inside the field's right edge; wipes the query in place.
    searchClear = uikit.AttachClearButton(win.content, function()
      searchQuery = ""
      pcall(function() searchField:SetText("") end) -- no callback: hide by hand
      searchClear.SetVisible(false)
      pcall(relayout)
    end)
    searchClear.root:SetPos(saveX + saveW - 21, TOP_Y + 5)

    plusBtn = prettyui.SimpleButton.new(win.content,
      prettyui.Sprites.SPRITE_BUTTONS.PLUS.neutral, function()
        playSfx(CLICK_SFX)
        local okC, errC = pcall(function()
          local name = store.AddCategory()
          editingCat = name -- open the fresh bucket straight in rename mode
          relayout()
        end)
        if not okC then log(formatStr("[PV] new category failed: {}", tostring(errC))) end
      end, { x = topBtnX(TOP_SLOT_PLUS), y = TOP_Y, size = TOP_BTN, iconSize = 14 })
    attachDelayedTooltip(plusBtn.root, "New category")

    -- Edit-mode toggle: one mode for all editing - shows/hides the rename +
    -- delete buttons and enables hold-and-move dragging. In-memory only:
    -- the local survives in-place rebuilds; closing the window drops it.
    editBtn = prettyui.SimpleButton.new(win.content,
      prettyui.Sprites.SPRITE_BUTTONS.PENCIL.neutral, function(_, active)
        playSfx(CLICK_SFX)
        local okE, errE = pcall(function()
          editMode = active == true
          relayout()
        end)
        if not okE then log(formatStr("[PV] edit toggle failed: {}", tostring(errE))) end
      end, {
        x = topBtnX(TOP_SLOT_EDIT), y = TOP_Y, size = TOP_BTN, iconSize = 14,
        toggleable = true, active = editMode,
      })

    -- Search toggle, rightmost. Swaps Save for the search field; turning it
    -- off clears the query so the list is never left silently filtered.
    searchBtn = prettyui.SimpleButton.new(win.content, 25230,
      function(_, active)
        playSfx(CLICK_SFX)
        local okF, errF = pcall(function()
          local on = active == true
          if not on then
            searchQuery = ""
            pcall(function() searchField:SetText("") end)
          end
          -- Both directions start with an empty query, so the clear icon
          -- hides either way; typing brings it back.
          pcall(function() searchClear.SetVisible(false) end)
          searchField.root.hidden = not on
          saveBtn.root.hidden = on
          relayout()
        end)
        if not okF then log(formatStr("[PV] search toggle failed: {}", tostring(errF))) end
      end, {
        x = topBtnX(TOP_SLOT_SEARCH), y = TOP_Y, size = TOP_BTN, iconSize = 14,
        toggleable = true, active = false,
      })
    attachDelayedTooltip(searchBtn.root, "Search presets")

    -- Import: far right of the cluster. Opens a box to paste a share code
    -- into; the decoded preset lands in this vault keeping its own name,
    -- category and icon (store.Import).
    importBtn = prettyui.SimpleButton.new(win.content, IMPORT_SPRITE, function()
      playSfx(CLICK_SFX)
      local okI, errI = pcall(sharewin.OpenImport)
      if not okI then log(formatStr("[PV] import open failed: {}", tostring(errI))) end
    end, { x = topBtnX(TOP_SLOT_IMPORT), y = TOP_Y, size = TOP_BTN,
      -- 16, not the cluster's 14: the 29456 art reads small at 14, and
      -- the BankUtil column draws the same icon at 16
      iconSize = 16 })
    attachDelayedTooltip(importBtn.root, "Import a preset from a share code")
    -- no icon hover variant needed: the button backdrop has its own hover
    attachDelayedTooltip(editBtn.root,
      "Toggle edit mode (rename, delete, drag to reorder)")

    relayout()
  end)
  if not ok then log(formatStr("[PV] UI build failed: {}", tostring(err))) end
end

-- The floating vault window in the game-world layer.
local function rebuild()
  local gameArea = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__PLUGIN_BUILD_LAYER_TOP)
  if not gameArea then
    log("[PV] plugin build layer not available yet")
    return
  end
  buildWindow(gameArea, 80, 140)
end

M.EnsureBuilt = function()
  if win == nil then rebuild() end
end

-- Show/hide with the bank. Respect a user X-close until the bank closes.
M.SetHidden = function(hidden)
  if win == nil then return end
  if hidden then
    if win.root and not win.root.hidden then
      pcall(function() win:Close() end)
      detailwin.Hide()
    end
    userClosed = false
  elseif not userClosed then
    if win.root and win.root.hidden then
      pcall(function() win:Show() end)
      pcall(relayout) -- bank-close resets any active bank view
    end
  end
end

-- Identity changed - login, logout, a permission grant or revoke, or the ID
-- finally arriving. The vault may now resolve to a different key, or to
-- none at all, so the list is redrawn.
M.OnIdentityChanged = function()
  if win then pcall(relayout) end
end

-- Relayouts if the window is up, and notifies the column either way.
M.Relayout = function()
  if win then
    pcall(relayout) -- fires M.OnListChanged at its end
  elseif M.OnListChanged then
    pcall(M.OnListChanged)
  end
end

-- The current vault is no longer the one on screen (multi-character toggled,
-- the shared-vault picker switched, or a vault was reset): drop everything
-- that referenced it. The caller restores the bank view (bankpage.Restore)
-- itself - this is only the window side.
M.OnVaultChanged = function()
  pcall(detailwin.Hide)
  selectedId = nil
  editingCat = nil
  editMode = false
  if win then
    pcall(relayout) -- fires M.OnListChanged at its end
  elseif M.OnListChanged then
    -- the BankUtil column can be up with this window never built
    pcall(M.OnListChanged)
  end
end

-- "Open vault window" button (settings + ribbon): FORCE the window open
-- regardless of bank state - never closes it (dismiss via the window's own
-- X). Auto mode honours wantOpen until the bank next closes (main.lua
-- clears it then); manual mode honours it until the X.
M.ForceOpen = function()
  -- Refuses while integrated, with the BLOCKED chime.
  if bankutil.HasColumn() then
    playSfx(BLOCKED_SFX)
    log("[PV] BankUtils Integration is on - presets live in the bank's sidebar")
    return
  end
  wantOpen = true
  userClosed = false
  M.EnsureBuilt()
  M.SetHidden(false)
end

-- main.lua's visibility rule reads this each pass; the X and (in auto
-- mode) a bank close clear it.
M.WantOpen = function() return wantOpen end
M.ClearWantOpen = function() wantOpen = false end

-- ---- BankUtil column bridge -------------------------------------------------
-- The sidebar column reuses this window's behaviour rather than duplicating
-- it, through these exports. List changes flow back out via
-- M.OnListChanged, assigned by bucolumn and fired at relayout's end.

M.OnListChanged = nil
M.UNCAT = UNCAT
M.IsCollapsed = isCollapsed
M.SetCollapsed = setCollapsed
M.LockLines = lockLines
M.NOTICE_LINES = NOTICE_LINES

-- The Save button's behaviour, callable from the column. Plays its own
-- confirm/refusal sounds; returns true when a preset was stored.
M.SaveCurrentGear = function()
  local saved = false
  local okS, errS = pcall(function()
    local cap = snapshot.Capture()
    -- Both refusals are silent to the eye - the list just doesn't change -
    -- so they get the same BLOCKED chime the bank page uses for a wrong-tab
    -- refusal. Without it a locked vault reads as a dead button.
    if not cap then
      playSfx(BLOCKED_SFX)
      log("[PV] could not read gear/backpack")
      return
    end
    local p = store.Add(cap)
    if p == nil then -- vault locked: no identified character to save under
      playSfx(BLOCKED_SFX)
      log("[PV] cannot save - character not identified")
      return
    end
    log(formatStr("[PV] preset saved ({} worn, {} inv)", #p.equipment, #p.backpack))
    -- New presets land in Uncategorised; if that section is collapsed the
    -- save would be invisible (sound only). Expand it so the change shows.
    -- (Free-standing mode has no section and is always visible.)
    setCollapsed(UNCAT, false)
    if win then
      pcall(relayout) -- fires M.OnListChanged for the column
    elseif M.OnListChanged then
      pcall(M.OnListChanged) -- saved from the column, window never built
    end
    playSfx(SAVE_SFX)
    saved = true
  end)
  if not okS then log(formatStr("[PV] save failed: {}", tostring(errS))) end
  return saved
end

-- Builds the window host on demand for the satellites that parent to it
-- (detail window, icon picker, share and import windows), and immediately
-- re-hides a FRESHLY built one.
local function ensureHost()
  local wasBuilt = win ~= nil
  M.EnsureBuilt()
  if win == nil then return false end
  if not wasBuilt then M.SetHidden(true) end
  return true
end

-- The row eye button's behaviour: open or close a preset's detail window.
M.ToggleDetail = function(preset)
  if preset == nil then return end
  if not ensureHost() then return end
  playRandomSfx(EYE_SFX)
  local ok, err = pcall(function()
    if selectedId == preset.id then
      selectedId = nil
      detailwin.Hide()
    else
      selectedId = preset.id
      detailwin.Show(preset)
    end
    pcall(relayout)
  end)
  if not ok then log(formatStr("[PV] preview failed: {}", tostring(err))) end
end

-- Column-facing openers: the window-owned satellites the column's
-- right-click actions summon.
M.OpenIconPicker = function(preset)
  if preset == nil then return end
  if not ensureHost() then return end
  local ok, err = pcall(function()
    iconwin.OpenForPreset(preset, detailwin.Position())
  end)
  if not ok then log(formatStr("[PV] icon picker failed: {}", tostring(err))) end
end

M.OpenCategoryIconPicker = function(name)
  if name == nil or name == UNCAT then return end
  if not ensureHost() then return end
  local ok, err = pcall(function()
    iconwin.OpenForCategory(name, win and win.root.x, win and win.root.y)
  end)
  if not ok then log(formatStr("[PV] icon picker failed: {}", tostring(err))) end
end

M.OpenShare = function(preset)
  if preset == nil then return end
  if not ensureHost() then return end
  sharewin.OpenShare(preset)
end

M.OpenImport = function()
  if not ensureHost() then return end
  sharewin.OpenImport()
end

-- The bank-view toggle sounds and the category accordion, exported so the
-- column's clicks sound identical to the window's.
M.PlayBankViewSfx = function(on)
  playRandomSfx(on and BANKVIEW_ON_SFX or BANKVIEW_OFF_SFX)
end
M.PlayCategorySfx = function()
  playSfx(CATEGORY_TOGGLE_SFX)
end

return M
