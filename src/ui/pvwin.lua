-- The main Preset Vault window: the standalone vault UI, built on PrettyUI.
-- It configures the satellite windows (ui/detailwin, ui/iconwin,
-- ui/sharewin); none of them may require this module back.
local M = {}
local prefs = require("core/prefs")

local store = require("core/store")
local snapshot = require("core/snapshot")
local bankpage = require("ui/bankpage")
local bankutil = require("core/bankutil")
local uikit = require("ui/uikit")
local sharewin = require("ui/sharewin")
local iconwin = require("ui/iconwin")
local detailwin = require("ui/detailwin")

local playSfx, playRandomSfx = uikit.PlaySfx, uikit.PlayRandomSfx
local centreTitle, syncWindowChrome = uikit.CentreTitle, uikit.SyncWindowChrome
local setButtonSprites = uikit.SetButtonSprites
local attachDelayedTooltip, hideTip = uikit.AttachDelayedTooltip, uikit.HideTip
local BLOCKED_SFX = uikit.BLOCKED_SFX

local CLICK_SFX = uikit.CLICK_SFX
local SAVE_SFX = 20223
local BANKVIEW_ON_SFX = { 59077, 59078, 59079, 59080, 59081, 59082 }
local BANKVIEW_OFF_SFX = { 59073, 59074, 59075, 59076 }
local CATEGORY_TOGGLE_SFX = 25537
local EYE_SFX = { 59087, 59088, 59089, 59090, 59091 }
local DROP_SFX = uikit.DROP_SFX

local ROW_ODD = 0x211E1BCC
local ROW_EVEN = 0x2A2622CC
local ROW_HOVER = 0x403728FF
local ROW_SELECTED = 0x49371FFF
local ROW_TEXT_RGBA = 0xD7D0BFFF
local SELECTED_BORDER = 0xD2A84DFF
local HEADING_TEXT = 0xD1BF9AFF
local HEADING_EXPANDED = 0x3B3222FF
local HEADING_EXPANDED_HOVER = 0x463A26FF
local ACCENT_W = 2
local ACCENT_RGBA = 0xD2A84D90
local CARD_SEP_RGBA = 0x756C60FF
-- The sprite faces up. rotationDegrees is anticlockwise-positive and a
-- negative angle does not rotate.
local ARROW_SPRITE = 8085
local ARROW_COLLAPSED_DEG = 270
local ARROW_EXPANDED_DEG = 180
local ARROW_SIZE = 16
local ARROW_PAD = 4
local VIEW_CELL_W = 30
local VIEW_DIV_INSET = 0
local VIEW_DIV_RGBA = 0xD7D0BF26
local VIEW_HOVER_RGBA = 0xD7D0BF1E
local VIEW_OPEN_RGBA = 0xD2A84D40
local VIEW_GLYPH_SIZE = 20
local VIEW_SPRITE, VIEW_SPRITE_LIT = 6247, 6247
local VIEW_GLYPH_DIM = 0.78
-- A missing font enum reads -1, never nil.
local LIST_FONT = (function()
  local f = nil
  pcall(function() f = id.Font.MUSEO_SANS_13PT_REGULAR end)
  if type(f) == "number" and f >= 0 then return f end
  return (uikit.SmallFont())
end)()

local WIN_W, WIN_H = 360, 440
local BORDER, TITLE_H = 8, 32
local SCROLLBAR_W = 18
local USABLE = WIN_W - BORDER * 2 - SCROLLBAR_W
local TOP_Y = 8
local TOP_BTN, TOP_BTN_GAP = 26, 6
local TOP_BTN_COUNT = 4
local TOP_BTNS_W = TOP_BTN_COUNT * (TOP_BTN + TOP_BTN_GAP) - TOP_BTN_GAP
-- Slot 1 is the far-right button.
local function topBtnX(slotFromRight)
  return USABLE - slotFromRight * (TOP_BTN + TOP_BTN_GAP) + TOP_BTN_GAP
end
local TOP_SLOT_IMPORT, TOP_SLOT_PLUS, TOP_SLOT_EDIT, TOP_SLOT_SEARCH = 1, 2, 3, 4
local IMPORT_SPRITE = 29456
local LIST_Y = 50
local ROW_H = 30
local CAT_INDENT = 8
local UNCAT = "Uncategorised"
-- The group holding every preset in flat mode; "\0" cannot be typed into a
-- category name.
local FLAT = "\0flat"

-- Session-only: absent = collapsed, true = expanded.
local expandedCats = {}
local function isCollapsed(cat)
  return expandedCats[cat] ~= true
end
local function setCollapsed(cat, collapsed)
  if cat == nil then return end
  expandedCats[cat] = (not collapsed) or nil
end

-- Shared with the Bank Core column, whose lines fit about 30 characters.
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

local host
local win
local list -- prettyui.SimpleView; every list item is a child of list.content
local rowPool = {}
local headerPool = {}
local hintPool = {}
local sepPool = {}
local renameField, renameOk
local commitRename
local ghost
local selectedId = nil -- preset whose detail window is open
local editingCat = nil
local editMode = false
-- One per category band, top to bottom: { cat, y0, y1, flat, headed, rows },
-- rows = { id, y0, y1 } per rendered preset row. All in list content coords.
local dropZones = {}
local dragOrderIdx = {} -- store.PresetOrderIndex() as of the last relayout
local dropLine
local lastListW = 0
local saveBtn, searchField -- exactly one of the two is visible
local searchClear
local editBtn, searchBtn
local plusBtn
local importBtn
local searchQuery = ""

local function matchesSearch(name)
  return uikit.MatchesSearch(name, searchQuery)
end

local function resetTransientModes()
  editMode = false
  searchQuery = ""
  pcall(function() editBtn:SetActive(false) end)
  pcall(function() searchBtn:SetActive(false) end)
  pcall(function() searchField:SetText("") end) -- SetText fires no onChange
  pcall(function() searchClear.SetVisible(false) end)
  pcall(function() searchField.root.hidden = true end)
  pcall(function() saveBtn.root.hidden = false end)
  pcall(sharewin.CloseImport)
end
local drag = nil -- { slot } while a drag is live
local dragTick
local editHint
local lockNotice
local emptyNotice
local userClosed = false
local wantOpen = false
local layoutGuard = false -- true while relayout runs; callbacks must not re-enter
local relayout

uikit.AddTicker("pvWindowDrag", function()
  if dragTick then dragTick() end
end)

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

-- The mouse's Y in the list's scrolled content coords (what drop zones are
-- recorded in), or nil when the cursor is outside the visible list.
local function contentMouseY()
  local m = uikit.MousePos()
  if not m or not win or not list then return nil end
  local mx = m.x - (win.root.x + BORDER)
  if mx < 0 or mx > USABLE + SCROLLBAR_W then return nil end
  local ly = m.y - (win.root.y + TITLE_H + (list.root.y or 0))
  if ly < 0 or ly >= (list.root.height or 0) then return nil end
  return ly + (list.scrollY or 0)
end

-- Where a drop of `slot` would land, or nil when it would change nothing.
-- A category: { cat, below, lineY }. A preset: { setCat, target, lineY }.
-- lineY is in list content coords.
local function resolveDrop(slot)
  local my = contentMouseY()
  if my == nil then return nil end
  local zi, z
  for i, zone in ipairs(dropZones) do
    if my >= zone.y0 and my < zone.y1 then
      zi, z = i, zone
      break
    end
  end
  if z == nil then return nil end
  if slot.header ~= nil then
    local own = (slot.cat == UNCAT) and "" or slot.cat
    if z.flat or z.cat == own then return nil end
    local oi
    for i, zone in ipairs(dropZones) do
      if zone.cat == own then oi = i end
    end
    -- Uncategorised is pinned first, so a drop on it means "first after it".
    local below = z.cat == "" or my >= (z.y0 + z.y1) / 2
    if oi ~= nil and ((below and zi == oi - 1)
      or (not below and zi == oi + 1)) then
      return nil
    end
    return { cat = z.cat, below = below, lineY = below and z.y1 or z.y0 }
  end
  local p = slot.preset
  if p == nil then return nil end
  local catChange = not z.flat and (p.category or "") ~= z.cat
  local underHeader = z.headed and (z.y0 + ROW_H) or z.y0
  local gap = nil
  if prefs.GetBool("ui.lockAlpha") ~= true then
    gap = uikit.GapAt(z.rows, my)
  end
  if gap == nil then
    if not catChange then return nil end
    return { setCat = z.cat, lineY = underHeader }
  end
  local aboveId = gap.above and gap.above.id or nil
  local belowId = gap.below and gap.below.id or nil
  if aboveId == p.id or belowId == p.id then return nil end
  local target = uikit.GapTarget(dragOrderIdx, p.id, aboveId, belowId)
  if target == nil and not catChange then return nil end
  return { setCat = catChange and z.cat or nil, target = target,
    lineY = gap.lineY }
end

local function applyDrop(slot, t)
  if slot.header ~= nil then
    if t.cat == "" then
      store.ReorderCategory(slot.cat, "") -- "" target = first position
    else
      store.MoveCategory(slot.cat, t.cat, t.below)
    end
  else
    if t.setCat ~= nil then
      store.SetCategory(slot.preset.id, t.setCat) -- "" clears the category
    end
    if t.target ~= nil then store.ReorderPreset(slot.preset.id, t.target) end
  end
  playSfx(DROP_SFX)
  relayout()
end

local function ensureDropLine()
  if dropLine then return dropLine end
  dropLine = ui.Rectangle.new(list.content)
  dropLine:SetSize(math.max(1, lastListW), 2)
  dropLine.fill = true
  dropLine.rgba = SELECTED_BORDER
  dropLine.clickthrough = true
  dropLine.hidden = true
  return dropLine
end

local EDGE_PX, EDGE_TICKS = 16, 6
local lastEdgeScroll = -100
local function edgeScroll(m)
  if not m or not win or not list then return end
  if (uikit.Now() - lastEdgeScroll) < EDGE_TICKS then return end
  local mx = m.x - (win.root.x + BORDER)
  if mx < 0 or mx > USABLE + SCROLLBAR_W then return end
  local ly = m.y - (win.root.y + TITLE_H + (list.root.y or 0))
  local h = list.root.height or 0
  local dir = 0
  if ly >= 0 and ly < EDGE_PX then
    dir = -1
  elseif ly >= h - EDGE_PX and ly < h then
    dir = 1
  end
  if dir ~= 0 then
    lastEdgeScroll = uikit.Now()
    list:ScrollBy(dir * ROW_H)
  end
end

local function mouseOnSurf(slot)
  local my = contentMouseY()
  if my == nil then return false end
  local m = uikit.MousePos()
  local mx = m.x - (win.root.x + BORDER)
  return mx >= (slot.surfX or 0)
    and mx <= (slot.surfX or 0) + (slot.surfW or 0)
    and my >= (slot.surfY or 0)
    and my < (slot.surfY or 0) + (slot.surfH or 0)
end

-- ONHOLD and ONRELEASE reach a drag surface by geometry, even when another
-- plugin window overlaps it.
local function mouseOverSatellite()
  local m = uikit.MousePos()
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

local DRAG_DEADZONE = 6 -- px
local armed = nil -- { slot, x, y, tick }: a press that has not crossed the deadzone
local lastDragEnd = -10
-- After a toggle the rows shift under the pointer; while it stays parked
-- there, surfaces neither arm nor toggle.
local TOGGLE_GRACE_TICKS = 30
local TOGGLE_GRACE_R2 = 144 -- 12px radius, squared
local toggleGrace = -100
local togglePos = nil
local function inToggleGrace()
  if (uikit.Now() - toggleGrace) >= TOGGLE_GRACE_TICKS then return false end
  if togglePos == nil then return true end
  local m = uikit.MousePos()
  if m == nil then return true end
  local dx, dy = m.x - togglePos.x, m.y - togglePos.y
  return dx * dx + dy * dy < TOGGLE_GRACE_R2
end
local finishDrag

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
  if dropLine then pcall(function() dropLine.hidden = true end) end
  pcall(function() restoreSurf(d.slot) end)
  if commit then
    local ok, err = pcall(function()
      local t = resolveDrop(d.slot)
      if t ~= nil then applyDrop(d.slot, t) end
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
  -- Only the pressed surface keeps the hold stream and gets ONRELEASE, so it
  -- is stretched over the list; a separate capture layer misses the release.
  slot.dragSurf:SetPos(0, 0)
  slot.dragSurf:SetSize(USABLE + SCROLLBAR_W, math.max(list.contentHeight or 0, WIN_H))
  pcall(function() slot.dragSurf:MoveToFront() end)
  pcall(function() ensureDropLine():MoveToFront() end)
  pcall(function() g.root:MoveToFront() end)
end

dragTick = function()
  if not drag then return end
  local ok, err = pcall(function()
    local m = uikit.MousePos()
    if m and ghost then ghost.root:SetPos(m.x + 14, m.y - 13) end
    edgeScroll(m)
    local t = resolveDrop(drag.slot)
    local line = ensureDropLine()
    line.hidden = t == nil
    if t ~= nil then
      line:SetPos(0, math.max(0, t.lineY - 1))
      line:SetSize(lastListW, 2)
      line:MoveToFront()
    end
  end)
  if not ok then uikit.ReportOnce("drag tick", err) end
end

-- The handlers read slot.dragText / noDrag / header / preset at event time,
-- because slots are pooled.
local function attachDrag(slot, parent)
  local surf = ui.Layer.new(parent)
  surf.clickthrough = false
  surf.hidden = true
  slot.dragSurf = surf
  -- without this the surface swallows the wheel
  pcall(function() surf:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", list._onScrollWheel) end)

  surf:Subscribe(ui.Hook.ONHOLD, function(c, hx, hy)
    local ok, err = pcall(function()
      if drag then return end
      uikit.CalibratePointer(c, hx, hy)
      if inToggleGrace() then return end
      if mouseOverSatellite() then return end
      local m = uikit.MousePos()
      if not m then return end
      -- A gap over 10 ticks means the last press ended without ONRELEASE, so
      -- this is a fresh press. A tighter tolerance re-anchors on every hitch
      -- and the drag never starts.
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
  -- The header click is decided here, never on ONCLICK, which appears to
  -- fire at press time, before a drag can arm.
  local function onRelease()
    armed = nil
    if drag ~= nil then
      if drag.slot == slot then finishDrag(true) end
      return
    end
    if slot.header == nil then return end
    local ok, err = pcall(function()
      if (uikit.Now() - lastDragEnd) < 2 then return end
      if inToggleGrace() then return end
      if not mouseOnSurf(slot) then return end
      if mouseOverSatellite() then return end
      toggleGrace = uikit.Now()
      togglePos = uikit.MousePos()
      local h = slot.header
      h:SetExpanded(not h.expanded)
      if h.onToggle then h.onToggle(h, h.expanded) end
    end)
    if not ok then log(formatStr("[PV] header toggle failed: {}", tostring(err))) end
  end
  surf:Subscribe(ui.Hook.ONRELEASE, onRelease)
  -- Drag-only: if this and ONRELEASE both fire, the toggle must not run twice.
  pcall(function()
    surf:Subscribe(ui.Hook.ONDRAGCOMPLETE, function()
      armed = nil
      if drag and drag.slot == slot then finishDrag(true) end
    end)
  end)
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

local function applyRowLook(s)
  pcall(function()
    local fill = s.base or ROW_ODD
    if s.active then
      fill = ROW_SELECTED
    elseif s.hovered or s.viewHovered then
      fill = ROW_HOVER
    end
    s.bg.rgba = fill
    s.border.hidden = not s.active
  end)
end

local function applyViewLook(s)
  pcall(function()
    local open = s.preset ~= nil and selectedId == s.preset.id
    local lit = open or s.viewHovered == true
    s.viewFill.rgba = open and VIEW_OPEN_RGBA or VIEW_HOVER_RGBA
    s.viewFill.hidden = not lit
    s.viewGlyph.spriteID = lit and VIEW_SPRITE_LIT or VIEW_SPRITE
    s.viewGlyph.alpha = lit and 1.0 or VIEW_GLYPH_DIM
  end)
end

local function ensureRowSlot(i)
  local s = rowPool[i]
  if s then return s end
  local body = list.content
  s = {}
  rowPool[i] = s

  s.bg = ui.Rectangle.new(body)
  s.bg.fill = true
  s.bg.clickthrough = true
  s.bg.hidden = true
  s.viewFill = ui.Rectangle.new(body)
  s.viewFill.fill = true
  s.viewFill.clickthrough = true
  s.viewFill.hidden = true
  s.viewDiv = ui.Rectangle.new(body)
  s.viewDiv.fill = true
  s.viewDiv.rgba = VIEW_DIV_RGBA
  s.viewDiv.clickthrough = true
  s.viewDiv.hidden = true
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

  s.setHovered = function(hov)
    s.hovered = hov == true
    applyRowLook(s)
  end

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
    -- Load-bearing: the drag surface stops short of the row's buttons, so a
    -- click in the gap lands here.
    if editMode then return end
    if not bankpage.IsBankOpen() then
      playSfx(BLOCKED_SFX)
      uikit.ShowInstantTip(s.btn, "Bank not in view", body,
        uikit.TIP_BLOCKED_TICKS)
      return
    end
    local ok, err = pcall(function()
      if not s.preset then return end
      -- The only place a view is opened, so the two engines are mutually
      -- exclusive.
      if bankutil.IsActive() then
        if bankutil.ActivePresetId() == s.preset.id then
          bankutil.Hide()
          playRandomSfx(BANKVIEW_OFF_SFX)
        else
          local shown, why = bankutil.ShowPreset(s.preset)
          if shown then
            playRandomSfx(BANKVIEW_ON_SFX)
          elseif why == "not_all_items" then
            bankpage.FlashWrongTab()
          else
            playSfx(BLOCKED_SFX)
            uikit.ShowInstantTip(s.btn,
              why == "preset_open" and "Close the bank's preset panel first"
              or "Bank view unavailable (" .. tostring(why) .. ")",
              body, uikit.TIP_BLOCKED_TICKS)
          end
        end
        relayout()
        return
      end
      -- Not IsApplied(): an empty preset moves no items, so its view could
      -- never be turned off.
      if bankpage.activePresetId == s.preset.id then
        bankpage.Restore()
        playRandomSfx(BANKVIEW_OFF_SFX)
      else
        -- Show plays its own refusal sound
        if bankpage.Show(s.preset) ~= false then playRandomSfx(BANKVIEW_ON_SFX) end
      end
      relayout()
    end)
    if not ok then log(formatStr("[PV] bank toggle failed: {}", tostring(err))) end
  end)
  pcall(function() s.btn:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", list._onScrollWheel) end)
  attachDelayedTooltip(s.btn, function()
    if not bankpage.IsBankOpen() then return nil end
    return "Toggle this preset's bank view"
  end, body)
  attachDrag(s, body)

  s.viewGlyph = ui.Sprite.new(body)
  s.viewGlyph:SetSize(VIEW_GLYPH_SIZE, VIEW_GLYPH_SIZE)
  s.viewGlyph.spriteID = VIEW_SPRITE
  s.viewGlyph.clickthrough = true
  s.viewGlyph.hidden = true
  s.viewBtn = ui.Button.new(body)
  s.viewBtn.alpha = 0
  s.viewBtn.text.content = ""
  s.viewBtn.hidden = true
  s.viewBtn:Subscribe(ui.Hook.ONMOUSEOVER, function()
    s.viewHovered = true
    applyViewLook(s)
    applyRowLook(s)
    return true
  end)
  s.viewBtn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
    s.viewHovered = false
    applyViewLook(s)
    applyRowLook(s)
    return true
  end)
  s.viewBtn:Subscribe(ui.Hook.ONCLICK, function()
    M.ToggleDetail(s.preset)
  end)
  pcall(function() s.viewBtn:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", list._onScrollWheel) end)
  attachDelayedTooltip(s.viewBtn, "Preview contents", body)

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
  end, { size = 20, _onScrollWheel = list._onScrollWheel })
  setButtonSprites(s.delBtn, 36552)
  attachDelayedTooltip(s.delBtn.root, "Delete preset", body)

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
  s.viewHovered = false
  s.viewFill.hidden = true
  s.viewDiv.hidden = true
  s.viewGlyph.hidden = true
  s.viewBtn.hidden = true
  s.delBtn.root.hidden = true
end

-- Call-compatible with prettyui.CollapseButton (.root, :SetText,
-- :SetExpanded), except that SetExpanded is silent: onToggle fires on user
-- clicks only.
local function makeSectionHeader(parent)
  local h = { expanded = true, hovered = false, base = ROW_ODD }

  h.root = ui.Layer.new(parent)
  h.root:SetSize(100, ROW_H)
  h.root.clickthrough = false

  h.bg = ui.Rectangle.new(h.root)
  h.bg.fill = true
  h.bg:SetSize(0, ROW_H, 1.0)
  h.bg.clickthrough = true
  h.accent = ui.Rectangle.new(h.root)
  h.accent.fill = true
  h.accent.rgba = ACCENT_RGBA
  h.accent:SetSize(ACCENT_W, ROW_H)
  h.accent.clickthrough = true
  h.accent.hidden = true

  h.icon = ui.Sprite.new(h.root)
  h.icon:SetSize(24, 24)
  h.icon:SetPos(4, 5)
  h.icon.clickthrough = true
  h.icon.hidden = true

  h.label = ui.Text.new(h.root)
  h.label.font = LIST_FONT
  h.label.rgba = HEADING_TEXT
  h.label.alignVertical = ui.AlignMode.CENTRE
  h.label.maxLines = 1
  h.label.clickthrough = true

  h.arrow = ui.Sprite.new(h.root)
  h.arrow:SetSize(ARROW_SIZE, ARROW_SIZE) -- must stay square: rotated art clips otherwise
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

  function h.SetIcon(_, spriteId)
    local nameX = 6
    if spriteId ~= nil then
      h.icon.hidden = false
      pcall(function() h.icon.spriteID = spriteId end)
      nameX = 32
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
  h.root:Subscribe(ui.Hook.ONCLICK, function()
    -- Load-bearing: the drag surface decides the toggle in edit mode but
    -- stops short of the buttons, so a click in the gap lands here.
    if editMode then return end
    local ok, err = pcall(function()
      h:SetExpanded(not h.expanded)
      if h.onToggle then h.onToggle(h, h.expanded) end
    end)
    if not ok then log(formatStr("[PV] header toggle failed: {}", tostring(err))) end
  end)
  pcall(function() h.root:Subscribe(ui.Hook.ONSCROLLWHEEL, "pvWheel", list._onScrollWheel) end)

  h:SetIcon(nil)
  updateState()
  return h
end

local function ensureHeaderSlot(i)
  local s = headerPool[i]
  if s then return s end
  local body = list.content
  s = {}
  headerPool[i] = s

  s.header = makeSectionHeader(body)
  attachDrag(s, body)
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
  end, { size = 20, _onScrollWheel = list._onScrollWheel })
  setButtonSprites(s.renameBtn, 20983, 20984)
  attachDelayedTooltip(s.renameBtn.root, "Rename category", body)

  s.iconBtn = prettyui.SpriteButton.new(body, "SWAP", function()
    playSfx(CLICK_SFX)
    local ok, err = pcall(function()
      if s.cat then
        iconwin.OpenForCategory(s.cat, win and win.root.x, win and win.root.y)
      end
    end)
    if not ok then log(formatStr("[PV] icon picker failed: {}", tostring(err))) end
  end, { size = 24, _onScrollWheel = list._onScrollWheel })
  setButtonSprites(s.iconBtn, 36153)
  attachDelayedTooltip(s.iconBtn.root, "Choose an icon for this category",
    body)

  s.delBtn = prettyui.SpriteButton.new(body, "TRASH", function()
    playSfx(CLICK_SFX)
    local ok, err = pcall(function()
      if not s.cat then return end
      store.DeleteCategory(s.cat)
      if editingCat == s.cat then editingCat = nil end
      relayout()
    end)
    if not ok then log(formatStr("[PV] delete category failed: {}", tostring(err))) end
  end, { size = 20, _onScrollWheel = list._onScrollWheel })
  setButtonSprites(s.delBtn, 36552)
  attachDelayedTooltip(s.delBtn.root, "Delete category (presets kept)", body)

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

local function ensureSep(i)
  local sp = sepPool[i]
  if sp then return sp end
  sp = ui.Rectangle.new(list.content)
  sp.fill = true
  sp.rgba = CARD_SEP_RGBA
  sp.clickthrough = true
  sepPool[i] = sp
  return sp
end

local function ensureHint(i)
  local hint = hintPool[i]
  if hint then return hint end
  hint = {}
  hint.bg = ui.Rectangle.new(list.content)
  hint.bg.fill = true
  hint.bg.clickthrough = true
  hint.accent = ui.Rectangle.new(list.content)
  hint.accent.fill = true
  hint.accent.rgba = ACCENT_RGBA
  hint.accent.clickthrough = true
  hint.text = prettyui.Text.new(list.content, {
    text = "(edit mode then drag presets here)",
    x = 20, y = 0,
    height = 16,
    colour = 0x8A7B5C99,
    _onScrollWheel = list._onScrollWheel,
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
  local body = list.content
  local function commit()
    local ok, err = pcall(function()
      local old = editingCat
      editingCat = nil
      if old then
        local newName = store.CleanName(renameField:GetText())
        if newName ~= "" and newName ~= old then
          setCollapsed(newName, isCollapsed(old))
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
    width = USABLE - 62,
    height = 26,
    maxLength = 25,
    placeholder = "Category name",
    onSubmit = commit,
    _onScrollWheel = list._onScrollWheel,
  })
  renameField.root.hidden = true
  renameOk = prettyui.SimpleButton.new(body, "OK", function()
    playSfx(CLICK_SFX)
    commit()
  end, {
    x = USABLE - 56, y = 0, width = 56, height = 24,
    _onScrollWheel = list._onScrollWheel,
  })
  renameOk.root.hidden = true
end

relayout = function()
  if not win then return end
  layoutGuard = true
  hideTip()
  cancelDrag()
  ensureRenamePair()
  renameField.root.hidden = true
  renameOk.root.hidden = true

  local groups, order = {}, {}
  groups[UNCAT] = {}
  local catIcons = {}
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
  -- Edit mode keeps an empty Uncategorised: it is the drop target that
  -- clears a preset's category.
  if #groups[UNCAT] > 0 or editMode then
    table.insert(order, 1, UNCAT)
  end
  if filtering then
    local kept = {}
    for _, cat in ipairs(order) do
      if #(groups[cat] or {}) > 0 then kept[#kept + 1] = cat end
    end
    order = kept
  end

  -- Flattened before the sort, so both views share the one stored order.
  local flatMode = prefs.GetBool("ui.noCategories") == true
  if flatMode then
    local all = {}
    for _, cat in ipairs(order) do
      for _, p in ipairs(groups[cat] or {}) do all[#all + 1] = p end
    end
    groups, order = { [FLAT] = all }, { FLAT }
  end
  if plusBtn then plusBtn.root.hidden = flatMode end
  if importBtn then
    pcall(function()
      importBtn.root:SetPos(
        topBtnX(flatMode and TOP_SLOT_PLUS or TOP_SLOT_IMPORT), TOP_Y)
    end)
  end
  -- lockAlpha ignores the stored order; it never rewrites it.
  local orderIdx = nil
  if prefs.GetBool("ui.lockAlpha") ~= true then
    orderIdx = store.PresetOrderIndex()
  end
  dragOrderIdx = orderIdx or {}
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

  if editHint == nil then
    editHint = ui.Text.new(win.content)
    editHint:SetPos(0, LIST_Y - 10)
    editHint:SetSize(USABLE - TOP_BTNS_W, 16)
    editHint.font = id.Font.MUSEO_SANS_15PT_REGULAR
    editHint.rgba = 0xB8A169CC
    editHint.alignHorizontal = ui.AlignMode.CENTRE
    editHint.content = "Drag items to rearrange"
    editHint.clickthrough = true
  end
  -- A locked vault reads as empty by design; the notice says why.
  local lockState = store.Locked() and store.IdentityState() or nil
  if lockNotice == nil then
    lockNotice = {}
    for i = 1, NOTICE_LINES do
      local t = ui.Text.new(win.content)
      t:SetPos(0, LIST_Y - 10 + (i - 1) * 19)
      t:SetSize(USABLE, 16)
      t.font = id.Font.MUSEO_SANS_15PT_REGULAR
      t.rgba = (i == 1) and 0xE0B050FF or 0xB8A169CC
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

  -- This count must mirror the layout loop below exactly, or rows clip under
  -- the scrollbar or leave an empty lane for one that is not there.
  local totalRows = 0
  for _, cat in ipairs(order) do
    local isFlat = (cat == FLAT)
    local freeStanding = isFlat or (cat == UNCAT
      and prefs.GetBool("ui.noUncatBucket") == true)
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
  local listH = math.max(1, viewH - listTop)
  list.root:SetPos(0, listTop)
  list:SetSize(USABLE + SCROLLBAR_W, listH)
  local barVisible = (totalRows * ROW_H + 8) > listH
  local listW = barVisible and USABLE or (USABLE + SCROLLBAR_W)

  dropZones = {}
  lastListW = listW
  local y = 0
  local hIdx, rIdx, tIdx, sIdx = 0, 0, 0, 0
  local band = 0
  local prevExpandedCard = false

  for _, cat in ipairs(order) do
    local isUncat = (cat == UNCAT)
    local isFlat = (cat == FLAT)
    local zoneStart = y
    local zoneRows = {}
    -- Searching force-expands without writing the collapse state.
    local collapsed = (not filtering) and isCollapsed(cat)
    local freeStanding = isFlat
      or (isUncat and prefs.GetBool("ui.noUncatBucket") == true)
    if freeStanding then collapsed = false end

    if freeStanding then
      -- no header row at all
    else
      if prevExpandedCard then
        sIdx = sIdx + 1
        local sp = ensureSep(sIdx)
        sp.hidden = false
        sp:SetPos(0, y)
        sp:SetSize(listW, 1)
        pcall(function() sp:MoveToFront() end)
      end
      if editingCat == cat then
        band = band + 1
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
        s.noDrag = isUncat
        band = band + 1
        s.header.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
        s.header.root.hidden = false
        s.header.root:SetPos(0, y)
        s.header.root:SetSize(listW, ROW_H)
        s.surfX, s.surfY = 0, y
        s.surfW, s.surfH = listW - 88, ROW_H
        s.dragSurf.hidden = not editMode
        if editMode then restoreSurf(s) end
        s.header:SetText(cat)
        s.header:SetIcon(catIcons[cat])
        s.header.arrow.hidden = editMode
        s.header:SetExpanded(not collapsed)
        s.renameBtn.root.hidden = isUncat or not editMode
        s.iconBtn.root.hidden = isUncat or not editMode
        s.delBtn.root.hidden = isUncat or not editMode
        if not s.renameBtn.root.hidden then
          s.renameBtn.root:SetPos(listW - 84, y + 6)
          s.iconBtn.root:SetPos(listW - 60, y + 3)
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
        band = band + 1
        s.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
        s.bg.hidden = false
        s.bg:SetPos(0, y)
        s.bg:SetSize(listW, ROW_H)
        s.accent.hidden = freeStanding
        if not freeStanding then
          s.accent:SetPos(0, y)
          s.accent:SetSize(ACCENT_W, ROW_H)
        end
        s.border:SetPos(0, y)
        s.border:SetSize(listW, ROW_H)
        local indent = freeStanding and 0 or CAT_INDENT
        local nameX = 10 + indent
        if p.icon then
          s.icon.hidden = false
          s.icon:SetPos(4 + indent, y + 3)
          pcall(function() s.icon.spriteID = p.icon end)
          nameX = 35 + indent
        else
          s.icon.hidden = true
          if prefs.GetBool("ui.alignNamesOff") ~= true then
            nameX = 35 + indent
          end
        end

        local reserve = editMode and (VIEW_CELL_W + 28) or VIEW_CELL_W
        s.text.hidden = false
        s.text:SetPos(nameX, y)
        s.text:SetSize(math.max(40, listW - nameX - reserve), ROW_H)
        s.text.content = p.name
        s.btn.hidden = false
        s.btn:SetPos(0, y)
        s.btn:SetSize(listW - reserve, ROW_H)
        s.surfX, s.surfY = 0, y
        s.surfW, s.surfH = listW - reserve, ROW_H
        s.dragSurf.hidden = not editMode
        if editMode then restoreSurf(s) end
        s.active = (bankutil.IsActive()
          and bankutil.ActivePresetId()
          or bankpage.activePresetId) == p.id
        applyRowLook(s)

        local cellX = listW - VIEW_CELL_W
        s.viewDiv.hidden = false
        s.viewDiv:SetPos(cellX, y + VIEW_DIV_INSET)
        s.viewDiv:SetSize(1, ROW_H - VIEW_DIV_INSET * 2)
        s.viewFill:SetPos(cellX + 1, y)
        s.viewFill:SetSize(VIEW_CELL_W - 1, ROW_H)
        s.viewGlyph.hidden = false
        s.viewGlyph:SetPos(
          cellX + 1 + math.floor((VIEW_CELL_W - 1 - VIEW_GLYPH_SIZE) / 2),
          y + math.floor((ROW_H - VIEW_GLYPH_SIZE) / 2))
        s.viewBtn.hidden = false
        s.viewBtn:SetPos(cellX, y)
        s.viewBtn:SetSize(VIEW_CELL_W, ROW_H)
        applyViewLook(s)
        s.delBtn.root.hidden = not editMode
        if editMode then s.delBtn.root:SetPos(cellX - 24, y + 5) end
        zoneRows[#zoneRows + 1] = { id = p.id, y0 = y, y1 = y + ROW_H }
        y = y + ROW_H
      end
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
    -- A flat zone is reorder-only: a drop there must never rewrite the
    -- preset's stored category.
    dropZones[#dropZones + 1] = {
      cat = isUncat and "" or cat, y0 = zoneStart, y1 = y, flat = isFlat,
      headed = not freeStanding, rows = zoneRows,
    }
    prevExpandedCard = not freeStanding and not collapsed
  end

  for i = rIdx + 1, #rowPool do hideRowSlot(rowPool[i]) end
  for i = hIdx + 1, #headerPool do hideHeaderSlot(headerPool[i]) end
  for i = tIdx + 1, #hintPool do hideHint(hintPool[i]) end
  for i = sIdx + 1, #sepPool do sepPool[i].hidden = true end
  -- Siblings render in creation order, and a pooled separator can be older
  -- than a header created on this pass.
  for i = 1, sIdx do pcall(function() sepPool[i]:MoveToFront() end) end

  -- An empty category still renders a header, so it does not count as empty.
  local showEmpty = rIdx == 0 and hIdx == 0 and lockState == nil and not filtering
  local eLines = showEmpty and { "No presets yet", "Press Save Preset" } or {}
  for i = 1, 2 do
    emptyNotice[i].content = eLines[i] or ""
    emptyNotice[i].hidden = eLines[i] == nil
  end

  pcall(function() list:SetContentHeight(y + 8) end)
  layoutGuard = false
  if M.OnListChanged then pcall(M.OnListChanged) end
end

bankpage.OnViewChanged = function()
  if win and not layoutGuard then pcall(relayout) end
end
bankutil.OnViewChanged = bankpage.OnViewChanged

M.Destroy = function()
  if editingCat and commitRename then pcall(commitRename) end
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
  if list then
    pcall(function() list:Destroy() end)
    list = nil
  end
  if win then
    pcall(function() win:Destroy() end)
    win = nil
  end
  rowPool, headerPool, hintPool, sepPool = {}, {}, {}, {}
  dropLine = nil
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
      scrollable = false,
      -- Runs for the X and for a programmatic Close alike.
      onClose = function()
        if editingCat and commitRename then pcall(commitRename) end
        userClosed = true -- stay hidden until the bank closes
        wantOpen = false
        pcall(bankpage.Restore)
        pcall(bankutil.Hide)
        detailwin.Hide()
        resetTransientModes()
      end,
    })
    centreTitle(win)
    uikit.SetDefaultTipParent(win.content)
    -- The window itself must not scroll. List items are children of
    -- list.content, in list-local coords, and pass it as their tooltip parent.
    list = prettyui.SimpleView.new(win.content, {
      x = 0, y = LIST_Y,
      width = USABLE + SCROLLBAR_W,
      height = WIN_H - TITLE_H - BORDER - LIST_Y,
      scrollable = true, scrollStep = ROW_H,
    })
    -- One-directional: a satellite that requires pvwin back gets a
    -- half-initialised module from the cycle.
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
      anchor = function()
        if win then return win.root.x + win.root.width + 6, win.root.y end
      end,
      onClosed = function()
        selectedId = nil
        if not layoutGuard then pcall(relayout) end
      end,
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

    -- FancyButton is text-sized and options.width is only a minimum, so the
    -- label is fitted to the space.
    local saveAvail = USABLE - TOP_BTNS_W - TOP_BTN_GAP
    local saveLabel, saveW
    for _, candidate in ipairs({ "Save Preset", "Save" }) do
      saveLabel = candidate
      saveW = prettyui.FancyButton.getSize(candidate)
      if saveW <= saveAvail then break end
    end
    local saveX = math.max(0, math.floor((saveAvail - saveW) / 2))
    saveBtn = prettyui.FancyButton.new(win.content, saveLabel, function()
      M.SaveCurrentGear()
    end, { x = saveX, y = TOP_Y, variant = "positive" })
    attachDelayedTooltip(saveBtn.root,
      "Save your current gear and backpack as a new preset")

    searchField = prettyui.TextField.new(win.content, {
      x = saveX, y = TOP_Y,
      width = saveW,
      height = 26,
      maxLength = 25,
      placeholder = "Search...",
      contentMargin = ui.Margin.new(8, 3, 26, 0),
      onChange = function(f)
        -- the callback's content argument is unreliable; read the field
        searchQuery = f:GetText() or ""
        pcall(function() searchClear.SetVisible(searchQuery ~= "") end)
        pcall(relayout)
      end,
      _onScrollWheel = list._onScrollWheel,
    })
    searchField.root.hidden = true
    searchClear = uikit.AttachClearButton(win.content, function()
      searchQuery = ""
      pcall(function() searchField:SetText("") end) -- SetText fires no onChange
      searchClear.SetVisible(false)
      pcall(relayout)
    end)
    searchClear.root:SetPos(saveX + saveW - 21, TOP_Y + 5)

    plusBtn = prettyui.SimpleButton.new(win.content,
      prettyui.Sprites.SPRITE_BUTTONS.PLUS.neutral, function()
        playSfx(CLICK_SFX)
        local okC, errC = pcall(function()
          local name = store.AddCategory()
          editingCat = name
          relayout()
        end)
        if not okC then log(formatStr("[PV] new category failed: {}", tostring(errC))) end
      end, { x = topBtnX(TOP_SLOT_PLUS), y = TOP_Y, size = TOP_BTN, iconSize = 14 })
    attachDelayedTooltip(plusBtn.root, "New category")

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

    searchBtn = prettyui.SimpleButton.new(win.content, 25230,
      function(_, active)
        playSfx(CLICK_SFX)
        local okF, errF = pcall(function()
          local on = active == true
          if not on then
            searchQuery = ""
            pcall(function() searchField:SetText("") end)
          end
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

    importBtn = prettyui.SimpleButton.new(win.content, IMPORT_SPRITE, function()
      playSfx(CLICK_SFX)
      local okI, errI = pcall(sharewin.OpenImport)
      if not okI then log(formatStr("[PV] import open failed: {}", tostring(errI))) end
    end, { x = topBtnX(TOP_SLOT_IMPORT), y = TOP_Y, size = TOP_BTN,
      iconSize = 16 })
    attachDelayedTooltip(importBtn.root, "Import a preset from a share code")
    attachDelayedTooltip(editBtn.root,
      "Toggle edit mode (rename, delete, drag to reorder)")

    relayout()
  end)
  if not ok then log(formatStr("[PV] UI build failed: {}", tostring(err))) end
end

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

M.SetHidden = function(hidden)
  if win == nil then return end
  if hidden then
    if win.root and not win.root.hidden then
      pcall(function() win:Close() end)
      detailwin.Hide()
    end
    -- Close ran onClose, which set userClosed
    userClosed = false
  elseif not userClosed then
    if win.root and win.root.hidden then
      pcall(function() win:Show() end)
      pcall(relayout)
    end
  end
end

M.OnIdentityChanged = function()
  if win then pcall(relayout) end
end

-- While integrated the window is never built, and the column still has to
-- be told: relayout calls M.OnListChanged only when there is a window.
M.Relayout = function()
  if win then
    pcall(relayout)
  elseif M.OnListChanged then
    pcall(M.OnListChanged)
  end
end

-- Window side only: the caller restores the bank view itself.
M.OnVaultChanged = function()
  pcall(detailwin.Hide)
  selectedId = nil
  editingCat = nil
  editMode = false
  if win then
    pcall(relayout)
  elseif M.OnListChanged then
    pcall(M.OnListChanged)
  end
end

M.ForceOpen = function()
  if bankutil.HasColumn() then
    playSfx(BLOCKED_SFX)
    log("[PV] Bank Core Integration is on - presets live in the bank's sidebar")
    return
  end
  wantOpen = true
  userClosed = false
  M.EnsureBuilt()
  M.SetHidden(false)
end

M.WantOpen = function() return wantOpen end
M.ClearWantOpen = function() wantOpen = false end

-- Assigned by ui/bucolumn, which requires this module; requiring it back
-- from here would be a cycle.
M.OnListChanged = nil
M.UNCAT = UNCAT
M.IsCollapsed = isCollapsed
M.SetCollapsed = setCollapsed
M.LockLines = lockLines
M.NOTICE_LINES = NOTICE_LINES

-- Plays its own sounds; returns true when a preset was stored.
M.SaveCurrentGear = function()
  local saved = false
  local okS, errS = pcall(function()
    local cap = snapshot.Capture()
    if not cap then
      playSfx(BLOCKED_SFX)
      log("[PV] could not read gear/backpack")
      return
    end
    local p = store.Add(cap)
    if p == nil then -- the vault is locked
      playSfx(BLOCKED_SFX)
      log("[PV] cannot save - character not identified")
      return
    end
    log(formatStr("[PV] preset saved ({} worn, {} inv)", #p.equipment, #p.backpack))
    -- the new preset lands in Uncategorised, which may be collapsed
    setCollapsed(UNCAT, false)
    if win then
      pcall(relayout)
    elseif M.OnListChanged then
      pcall(M.OnListChanged)
    end
    playSfx(SAVE_SFX)
    saved = true
  end)
  if not okS then log(formatStr("[PV] save failed: {}", tostring(errS))) end
  return saved
end

-- Hides a freshly built window at once: hiding it later would close the
-- satellite being opened along with it.
local function ensureHost()
  local wasBuilt = win ~= nil
  M.EnsureBuilt()
  if win == nil then return false end
  if not wasBuilt then M.SetHidden(true) end
  return true
end

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

-- The satellites only work once buildWindow has configured them, hence
-- ensureHost in each opener below.
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

M.PlayBankViewSfx = function(on)
  playRandomSfx(on and BANKVIEW_ON_SFX or BANKVIEW_OFF_SFX)
end
M.PlayCategorySfx = function()
  playSfx(CATEGORY_TOGGLE_SFX)
end

return M
