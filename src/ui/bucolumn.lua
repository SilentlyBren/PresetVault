-- The Bank Core sidebar column: search, the category and preset list, and
-- the Save / new-category / import buttons. Core destroys its layers on
-- every unmount, so no component may be held across mounts.
local M = {}
local prefs = require("core/prefs")

local store = require("core/store")
local bankutil = require("core/bankutil")
local uikit = require("ui/uikit")
local bankpage = require("ui/bankpage")
local window = require("ui/pvwin")

local PAD = 8
local SAVE_H = 28
local SEARCH_H = 28
local VIEW_Y = PAD + SEARCH_H + 10
local LIST_BOTTOM_BUFFER = 40
local SIDE_BTN_W = 28
local LIST_TOP = 0 -- y inside the scrolling content
local ROW_H = 30
local CAT_INDENT = 8

local ROW_ODD = 0x211E1BCC
local ROW_EVEN = 0x2A2622CC
local ROW_HOVER = 0x403728FF
local ROW_SELECTED = 0x49371FFF
local ROW_TEXT_RGBA = 0xD7D0BFFF
local SELECTED_BORDER = 0xD2A84DFF
local HEADING_TEXT = 0xD1BF9AFF

local LIST_FRAME_RGBA = 0x726551FF

local HEADING_EXPANDED = 0x3B3222FF
local HEADING_EXPANDED_HOVER = 0x463A26FF

local ACCENT_W = 2
local ACCENT_RGBA = 0xD2A84D90
local CARD_SEP_RGBA = 0x756C60FF

-- The sprite faces up. Rotation is anticlockwise-positive and a negative
-- angle does not rotate at all.
local ARROW_SPRITE = 8085
local ARROW_COLLAPSED_DEG = 270
local ARROW_EXPANDED_DEG = 180
local ARROW_SIZE = 16
local ARROW_PAD = 4

-- PrettyUI narrows its scroll content by this much when the bar shows
local SCROLLBAR_W = 18

local HEADING_FONT = (uikit.SmallFont())
local ROW_FONT = HEADING_FONT

local col = nil -- everything built by mount; nil while unmounted
local hoveredRow = nil -- the menu's target
local hoveredHeader = nil

local searchQuery = ""
local function matchesSearch(name)
  return uikit.MatchesSearch(name, searchQuery)
end

local function viewBounds(ctx)
  local vw = ctx.width - PAD * 2 - 2
  local vh = math.max(60, ctx.height - VIEW_Y - LIST_BOTTOM_BUFFER - 4)
  return vw, vh
end

-- Renders are coalesced to one per tick: triggers arrive from inside
-- callbacks of the very buttons a render would rebuild.
local renderPending = false
local function scheduleRender()
  renderPending = true
end
M.OnIdentityChanged = scheduleRender

-- forward declarations: closures defined before these functions use them
local toggleView, toggleCollapse, deferClick

local render

local dragging
uikit.AddTicker("pvColumnRender", function()
  if not renderPending then return end
  -- a render would hand the held button back its row geometry mid-drag
  if dragging() then return end
  renderPending = false
  if col ~= nil then pcall(render) end
end)

window.OnListChanged = scheduleRender
-- wrapped, not replaced: pvwin already points this hook at its own relayout
local prevViewHook = bankutil.OnViewChanged
bankutil.OnViewChanged = function()
  if prevViewHook then pcall(prevViewHook) end
  scheduleRender()
end

-- Menu callbacks receive only a preset id or category name: a row or
-- component can be gone by the time an entry is picked.
local function presetById(id)
  for _, p in ipairs(store.All()) do
    if p.id == id then return p end
  end
  return nil
end

local function onRenameEntry(presetId)
  if col == nil or presetId == nil then return end
  uikit.PlaySfx(uikit.CLICK_SFX)
  col.editingPreset = presetId
  col.editingCat = nil
  col.renameFor = nil
  scheduleRender()
end

local function onIconEntry(presetId)
  uikit.PlaySfx(uikit.CLICK_SFX)
  pcall(function()
    local p = presetById(presetId)
    if p ~= nil then window.OpenIconPicker(p) end
  end)
end

local function onShareEntry(presetId)
  uikit.PlaySfx(uikit.CLICK_SFX)
  pcall(function()
    local p = presetById(presetId)
    if p ~= nil then window.OpenShare(p) end
  end)
end

-- `cat` is false for Uncategorised: a nil in a submenu's arguments table
-- would truncate it.
local function onMoveEntry(presetId, cat)
  pcall(function()
    store.SetCategory(presetId, cat ~= false and cat or nil)
    window.Relayout()
  end)
  uikit.PlaySfx(uikit.DROP_SFX)
  scheduleRender()
end

local function onDeleteEntry(presetId)
  if presetId == nil then return end
  local ok, err = pcall(function()
    if bankutil.ActivePresetId() == presetId then bankutil.Hide() end
    store.Delete(presetId)
    window.Relayout()
  end)
  if not ok then
    log(formatStr("[PV Bankcore] column delete failed: {}", tostring(err)))
  end
  uikit.PlaySfx(uikit.CLICK_SFX)
  scheduleRender()
end

local function onDeleteCategory(cat)
  if cat == nil then return end
  local ok, err = pcall(function()
    if col ~= nil and col.editingCat == cat then col.editingCat = nil end
    store.DeleteCategory(cat)
    window.Relayout()
  end)
  if not ok then
    log(formatStr("[PV Bankcore] column delete category failed: {}", tostring(err)))
  end
  uikit.PlaySfx(uikit.CLICK_SFX)
  scheduleRender()
end

local function onEditCategory(cat)
  if col == nil or cat == nil then return end
  uikit.PlaySfx(uikit.CLICK_SFX)
  col.editingCat = cat
  col.editingPreset = nil
  col.renameFor = nil
  scheduleRender()
end

local function onIconCategory(cat)
  if cat == nil then return end
  uikit.PlaySfx(uikit.CLICK_SFX)
  pcall(function() window.OpenCategoryIconPicker(cat) end)
end

local function onMoveCategory(cat, target, below)
  pcall(function()
    store.MoveCategory(cat, target, below == true)
    window.Relayout()
  end)
  uikit.PlaySfx(uikit.DROP_SFX)
  scheduleRender()
end

-- menu labels are markup
local function escapeMarkup(s)
  return (tostring(s or ""):gsub("[<>]", { ["<"] = "<lt>", [">"] = "<gt>" }))
end

local function menuTarget(name)
  return "<col=e7c878>" .. escapeMarkup(name) .. "</col>"
end

local function entryCount(menu, entries)
  local count = nil
  pcall(function() count = menu.entryCount end)
  if count == nil or count <= 0 then count = #entries end
  return count
end

-- Adds an entry and swaps it to the high-index end, the visual top. The new
-- entry is the one == to no pre-Add handle: handles are fresh userdata on
-- every read, and plugin entries read back with no text.
local function addMenuEntryFront(menu, label, fn, arg)
  -- each read of menu.entries builds a new list; the handles are copied
  -- out before the Add in case that list is a live view
  local list = menu.entries
  local before = {}
  for i = 1, entryCount(menu, list) do before[#before + 1] = list[i] end
  menu:Add(label, fn, arg)
  local after = menu.entries
  local count = entryCount(menu, after)
  for i = count, 1, -1 do
    local e = after[i]
    local known = false
    for _, b in ipairs(before) do
      if e == b then
        known = true
        break
      end
    end
    if not known then
      for current = i, count - 1 do
        menu:Swap(current, current + 1)
      end
      return
    end
  end
  log(formatStr("[PV Bankcore] column: added menu entry not found: {}", label))
end

-- For PrettyUI's submenu parents: overrideText is the one text field a
-- plugin entry reads back.
local function promoteByOverridePrefix(menu, prefix)
  local entries = menu.entries
  local count = entryCount(menu, entries)
  for i = count, 1, -1 do
    local hit = false
    pcall(function()
      local t = entries[i].overrideText
      hit = t ~= nil and string.sub(t, 1, #prefix) == prefix
    end)
    if hit then
      for current = i, count - 1 do
        menu:Swap(current, current + 1)
      end
      return true
    end
  end
  return false
end

-- A left click on a row runs the menu's top entry, so these two are the
-- rows' click handlers.
local function onViewEntry(presetId)
  pcall(deferClick, "p", presetId)
end

local function onToggleCatEntry(cat)
  pcall(deferClick, "c", cat)
end

Event.MiniMenuReady.Subscribe("pvColumnMenu", function(event)
  pcall(function()
    if col == nil then return end
    if hoveredRow ~= nil and hoveredRow.preset ~= nil then
      local p = hoveredRow.preset
      -- AddSubmenu must run first, while the menu is still just Cancel: its
      -- own positioning misplaces entries on a menu already reordered.
      if prefs.GetBool("ui.noCategories") ~= true then
        local current = (p.category ~= nil and p.category ~= "")
          and p.category or nil
        local children = {}
        if current ~= nil then
          children[#children + 1] = { label = "Uncategorised",
            action = onMoveEntry, arguments = { p.id, false } }
        end
        for _, c in ipairs(store.Categories()) do
          if c.name ~= window.UNCAT and c.name ~= current then
            children[#children + 1] = { label = escapeMarkup(c.name),
              action = onMoveEntry, arguments = { p.id, c.name } }
          end
        end
        if #children > 0 then
          pcall(function()
            prettyui.MiniMenu.AddSubmenu(event.miniMenu, "Move to",
              children, { title = "Move to" })
          end)
        end
      end
      -- added bottom-up: the last entry added is the top one, which is
      -- what a left click runs
      addMenuEntryFront(event.miniMenu, "<col=c0564a>Remove</col>",
        onDeleteEntry, p.id)
      addMenuEntryFront(event.miniMenu, "Share", onShareEntry, p.id)
      addMenuEntryFront(event.miniMenu, "Set Icon", onIconEntry, p.id)
      addMenuEntryFront(event.miniMenu, "Rename", onRenameEntry, p.id)
      promoteByOverridePrefix(event.miniMenu, "Move to")
      local viewing = bankutil.ActivePresetId() == p.id
      addMenuEntryFront(event.miniMenu,
        (viewing and "Hide " or "Load ") .. menuTarget(p.name),
        onViewEntry, p.id)
    elseif hoveredHeader ~= nil and hoveredHeader.cat ~= nil then
      local cat = hoveredHeader.cat
      if cat ~= window.UNCAT then
        local others = {}
        for _, c in ipairs(store.Categories()) do
          if c.name ~= window.UNCAT and c.name ~= cat then
            others[#others + 1] = c.name
          end
        end
        if #others > 0 then
          local above, below = {}, {}
          for _, c in ipairs(others) do
            above[#above + 1] = { label = escapeMarkup(c),
              action = onMoveCategory, arguments = { cat, c, false } }
            below[#below + 1] = { label = escapeMarkup(c),
              action = onMoveCategory, arguments = { cat, c, true } }
          end
          pcall(function()
            prettyui.MiniMenu.AddSubmenu(event.miniMenu, "Move above",
              above, { title = "Move above" })
            prettyui.MiniMenu.AddSubmenu(event.miniMenu, "Move below",
              below, { title = "Move below" })
          end)
        end
        addMenuEntryFront(event.miniMenu, "<col=c0564a>Remove</col>",
          onDeleteCategory, cat)
        addMenuEntryFront(event.miniMenu, "Set Icon", onIconCategory, cat)
        addMenuEntryFront(event.miniMenu, "Rename", onEditCategory, cat)
        promoteByOverridePrefix(event.miniMenu, "Move below")
        promoteByOverridePrefix(event.miniMenu, "Move above")
      end
      addMenuEntryFront(event.miniMenu,
        (hoveredHeader.expanded and "Close " or "Open ") .. menuTarget(cat),
        onToggleCatEntry, cat)
    end
  end)
end)

M.Shutdown = function()
  pcall(function() Event.MiniMenuReady.Unsubscribe("pvColumnMenu") end)
  col = nil
  hoveredRow = nil
  hoveredHeader = nil
end

local function orderedPresets()
  local list = {}
  for _, p in ipairs(store.All()) do list[#list + 1] = p end
  if prefs.GetBool("ui.lockAlpha") == true then
    table.sort(list, store.NameOrder)
  else
    local idx = store.PresetOrderIndex()
    table.sort(list, function(a, b)
      return (idx[a.id] or 0) < (idx[b.id] or 0)
    end)
  end
  return list
end

-- Returns groups in display order: { header = name|nil, icon, items }.
local function buildGroups()
  local presets = {}
  for _, p in ipairs(orderedPresets()) do
    if matchesSearch(p.name) then presets[#presets + 1] = p end
  end
  if prefs.GetBool("ui.noCategories") == true then
    return { { header = nil, items = presets } }
  end
  local byCat = {}
  for _, p in ipairs(presets) do
    local c = (p.category ~= nil and p.category ~= "") and p.category
      or window.UNCAT
    if byCat[c] == nil then byCat[c] = {} end
    byCat[c][#byCat[c] + 1] = p
  end
  local groups = {}
  local uncat = byCat[window.UNCAT] or {}
  if prefs.GetBool("ui.noUncatBucket") == true then
    if #uncat > 0 then groups[#groups + 1] = { header = nil, items = uncat } end
  else
    if #uncat > 0 then
      groups[#groups + 1] = { header = window.UNCAT, items = uncat }
    end
  end
  for _, c in ipairs(store.Categories()) do
    if c.name ~= window.UNCAT then
      groups[#groups + 1] = { header = c.name, icon = c.icon,
        items = byCat[c.name] or {} }
    end
  end
  if searchQuery ~= "" then
    local kept = {}
    for _, g in ipairs(groups) do
      if #g.items > 0 then kept[#kept + 1] = g end
    end
    return kept
  end
  return groups
end

toggleView = function(p)
  if p == nil or col == nil then return end
  local ok, err = pcall(function()
    if bankutil.ActivePresetId() == p.id then
      bankutil.Hide()
      window.PlayBankViewSfx(false)
    else
      local shown, why = bankutil.ShowPreset(p)
      if shown then
        window.PlayBankViewSfx(true)
      elseif why == "not_all_items" then
        bankpage.FlashWrongTab()
      else
        uikit.PlaySfx(uikit.BLOCKED_SFX)
        log(formatStr("[PV Bankcore] column: bank view unavailable ({})", tostring(why)))
      end
    end
  end)
  if not ok then log(formatStr("[PV Bankcore] column toggle failed: {}", tostring(err))) end
  scheduleRender()
end

toggleCollapse = function(cat)
  if cat == nil then return end
  pcall(function()
    window.SetCollapsed(cat, not window.IsCollapsed(cat))
    window.PlayCategorySfx()
  end)
  scheduleRender()
  window.Relayout()
end

-- Drag to reorder. A row's click is the menu's top entry and arrives
-- independently of the hold stream, in either order, so deferClick parks
-- it: it runs on release, or after CLICK_SETTLE_TICKS if no press claims it.
local DRAG_DEADZONE = 6 -- px
local HOLD_GAP_TICKS = 4 -- a hold stream silent this long counts as a release
local DRAG_DEAD_TICKS = 10 -- the same during a drag, which is then abandoned
local CLICK_SETTLE_TICKS = 3
local EDGE_PX, EDGE_TICKS = 16, 6
local GHOST_FILL = 0x403728E0

-- { part, kind "p"|"c", key, label, preset, x, y, tick, dragging }
local press = nil
local pendingClick = nil -- { kind, key, tick }
local lastDragEnd = -100
local lastEdgeScroll = -100

dragging = function()
  return press ~= nil and press.dragging == true
end

local function runClick(click)
  if click.kind == "p" then
    local p = presetById(click.key)
    if p ~= nil then toggleView(p) end
  else
    toggleCollapse(click.key)
  end
end

deferClick = function(kind, key)
  if dragging() then return end
  if (uikit.Now() - lastDragEnd) < 3 then return end
  pendingClick = { kind = kind, key = key, tick = uikit.Now() }
end

-- The pointer's y in list content coords, its y within the visible list,
-- and the list's height; nil when the pointer is outside the visible list.
local function listPointer()
  if col == nil then return nil end
  local m = uikit.MousePos()
  local origin = nil
  pcall(function() origin = col.view.root.xyGlobal end)
  if m == nil or origin == nil then return nil end
  local vw, vh = viewBounds(col.ctx)
  local lx, ly = m.x - origin.x, m.y - origin.y
  if lx < 0 or lx >= vw or ly < 0 or ly >= vh then return nil end
  return ly + (col.view.scrollY or 0), ly, vh
end

-- Where the held row or heading would land right now, or nil when the drop
-- would change nothing. A heading: { first, cat, below, lineY }. A preset:
-- { setCat, target, lineY }.
local function resolveDrop(pr)
  local y = listPointer()
  if y == nil then return nil end
  local zones = col.zones or {}
  local zi, z
  for i, zone in ipairs(zones) do
    if y >= zone.y0 and y < zone.y1 then
      zi, z = i, zone
      break
    end
  end
  if z == nil then return nil end
  local pinned = z.cat == nil or z.cat == window.UNCAT
  if pr.kind == "c" then
    if z.flat or z.cat == pr.key then return nil end
    local oi
    for i, zone in ipairs(zones) do
      if zone.cat == pr.key then oi = i end
    end
    -- Uncategorised is pinned first, so a drop on it means "first after it".
    local below = pinned or y >= (z.y0 + z.y1) / 2
    if oi ~= nil and ((below and zi == oi - 1)
      or (not below and zi == oi + 1)) then
      return nil
    end
    return { first = pinned, cat = z.cat, below = below,
      lineY = below and z.y1 or z.y0 }
  end
  local p = pr.preset
  local zoneCat = pinned and "" or z.cat
  local catChange = not z.flat and (p.category or "") ~= zoneCat
  local underHeader = z.headed and (z.y0 + ROW_H) or z.y0
  local gap = nil
  if prefs.GetBool("ui.lockAlpha") ~= true then
    gap = uikit.GapAt(z.rows, y)
  end
  if gap == nil then
    if not catChange then return nil end
    return { setCat = zoneCat, lineY = underHeader }
  end
  local aboveId = gap.above and gap.above.id or nil
  local belowId = gap.below and gap.below.id or nil
  if aboveId == p.id or belowId == p.id then return nil end
  local target = uikit.GapTarget(col.orderIdx or {}, p.id, aboveId, belowId)
  if target == nil and not catChange then return nil end
  return { setCat = catChange and zoneCat or nil, target = target,
    lineY = gap.lineY }
end

local function applyDrop(pr, t)
  local ok, err = pcall(function()
    if pr.kind == "c" then
      if t.first then
        store.ReorderCategory(pr.key, "") -- "" target = first position
      else
        store.MoveCategory(pr.key, t.cat, t.below)
      end
    else
      if t.setCat ~= nil then store.SetCategory(pr.key, t.setCat) end
      if t.target ~= nil then store.ReorderPreset(pr.key, t.target) end
    end
    window.Relayout()
  end)
  if not ok then
    log(formatStr("[PV Bankcore] column drop failed: {}", tostring(err)))
  end
  uikit.PlaySfx(uikit.DROP_SFX)
end

local function ensureDragParts()
  if col.ghost ~= nil then return end
  local body = col.view.content
  local g = ui.Layer.new(body)
  g.clickthrough = true
  g.hidden = true
  col.ghostFill = ui.Rectangle.new(g)
  col.ghostFill.fill = true
  col.ghostFill.rgba = GHOST_FILL
  col.ghostFill.clickthrough = true
  col.ghostBorder = ui.Rectangle.new(g)
  col.ghostBorder.fill = false
  pcall(function() col.ghostBorder.outlineThickness = 1 end)
  col.ghostBorder.rgba = SELECTED_BORDER
  col.ghostBorder.clickthrough = true
  col.ghostLabel = ui.Text.new(g)
  col.ghostLabel.font = ROW_FONT
  col.ghostLabel.rgba = ROW_TEXT_RGBA
  pcall(function() col.ghostLabel.alignVertical = ui.AlignMode.CENTRE end)
  col.ghostLabel.maxLines = 1
  col.ghostLabel.clickthrough = true
  col.ghost = g
  col.dropLine = ui.Rectangle.new(body)
  -- sized at creation: the line has failed to draw without it
  col.dropLine:SetSize(math.max(1, col.inner or 1), 2)
  col.dropLine.fill = true
  col.dropLine.rgba = SELECTED_BORDER
  col.dropLine.clickthrough = true
  col.dropLine.hidden = true
end

local function startDrag()
  press.dragging = true
  pendingClick = nil
  pcall(uikit.HideTip)
  ensureDragParts()
  local inner = col.inner or 0
  local _, vh = viewBounds(col.ctx)
  col.ghost:SetSize(inner, ROW_H)
  col.ghostFill:SetSize(inner, ROW_H)
  col.ghostBorder:SetSize(inner, ROW_H)
  col.ghostLabel:SetPos(10, 0)
  col.ghostLabel:SetSize(math.max(1, inner - 16), ROW_H)
  col.ghostLabel.content = press.label or ""
  -- Only the pressed component keeps the hold stream and gets the release,
  -- so the held button itself is stretched over the whole list.
  local btn = press.part.btn
  btn:SetPos(0, 0)
  btn:SetSize(inner, math.max(col.contentH or 0, vh))
  pcall(function() btn:MoveToFront() end)
  pcall(function() col.dropLine:MoveToFront() end)
  pcall(function() col.ghost:MoveToFront() end)
  pcall(function()
    local part = press.part
    part.text.hidden = true
    part.icon.hidden = true
    if part.arrow ~= nil then part.arrow.hidden = true end
  end)
end

local function finishDrag(commit)
  local pr = press
  press = nil
  lastDragEnd = uikit.Now()
  if col == nil or pr == nil then return end
  local t = commit and resolveDrop(pr) or nil
  pcall(function()
    col.ghost.hidden = true
    col.dropLine.hidden = true
  end)
  if t ~= nil then applyDrop(pr, t) end
  scheduleRender() -- the render hands the held button back its row geometry
end

-- Runs every tick of a drag. The ghost and line are re-fronted each time;
-- they have failed to draw without it.
local function dragStep()
  local y, ly, vh = listPointer()
  if y == nil then
    col.dropLine.hidden = true
    return
  end
  local now = uikit.Now()
  if (now - lastEdgeScroll) >= EDGE_TICKS then
    local dir = (ly < EDGE_PX) and -1 or ((ly >= vh - EDGE_PX) and 1 or 0)
    if dir ~= 0 then
      lastEdgeScroll = now
      col.view:ScrollBy(dir * ROW_H)
      y = ly + (col.view.scrollY or 0)
    end
  end
  local top = col.view.scrollY or 0
  col.ghost.hidden = false
  col.ghost:SetPos(0, math.max(top,
    math.min(top + vh - ROW_H, math.floor(y - ROW_H / 2))))
  col.ghost:MoveToFront()
  local t = resolveDrop(press)
  col.dropLine.hidden = t == nil
  if t ~= nil then
    col.dropLine:SetPos(0, math.max(0, t.lineY - 1))
    col.dropLine:SetSize(col.inner or 0, 2)
    col.dropLine:MoveToFront()
  end
end

local function canDrag(pr)
  if col == nil or searchQuery ~= "" then return false end
  if col.editingCat ~= nil or col.editingPreset ~= nil then return false end
  return not (pr.kind == "c" and pr.key == window.UNCAT)
end

local function onHold(part, kind)
  local now = uikit.Now()
  if dragging() then
    press.tick = now
    return
  end
  local m = uikit.MousePos()
  if m == nil then return end
  if press == nil or press.part ~= part
    or (now - press.tick) > HOLD_GAP_TICKS then
    local key, label
    if kind == "p" then
      if part.preset == nil then return end
      key, label = part.preset.id, part.preset.name
    else
      if part.cat == nil then return end
      key, label = part.cat, part.cat
    end
    press = { part = part, kind = kind, key = key, label = label,
      preset = part.preset, x = m.x, y = m.y, tick = now }
    return
  end
  press.tick = now
  if not canDrag(press) then return end
  local dx, dy = m.x - press.x, m.y - press.y
  if dx * dx + dy * dy >= DRAG_DEADZONE * DRAG_DEADZONE then startDrag() end
end

local function onRelease(part)
  if press == nil or press.part ~= part then return end
  if press.dragging then
    finishDrag(true)
    return
  end
  press = nil
  if pendingClick ~= nil then
    local click = pendingClick
    pendingClick = nil
    runClick(click)
  end
end

local function bindDrag(part, kind)
  part.btn:Subscribe(ui.Hook.ONHOLD, function(c, hx, hy)
    if not dragging() then pcall(uikit.CalibratePointer, c, hx, hy) end
    local ok, err = pcall(onHold, part, kind)
    if not ok then uikit.ReportOnce("column hold", err) end
    return true
  end)
  local function release()
    pcall(onRelease, part)
    return true
  end
  part.btn:Subscribe(ui.Hook.ONRELEASE, release)
  pcall(function() part.btn:Subscribe(ui.Hook.ONDRAGCOMPLETE, release) end)
end

uikit.AddTicker("pvColumnDrag", function()
  if col == nil then
    press, pendingClick = nil, nil
    return
  end
  local now = uikit.Now()
  if press ~= nil then
    if press.dragging then
      if (now - press.tick) > DRAG_DEAD_TICKS then
        finishDrag(false)
      else
        local ok, err = pcall(dragStep)
        if not ok then uikit.ReportOnce("column drag", err) end
      end
    elseif (now - press.tick) > HOLD_GAP_TICKS then
      press = nil
    end
  end
  if pendingClick ~= nil and press == nil
    and (now - pendingClick.tick) >= CLICK_SETTLE_TICKS then
    local click = pendingClick
    pendingClick = nil
    pcall(runClick, click)
  end
end)

local function applyHeaderLook(h)
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

local function ensureHeader(i)
  local h = col.headers[i]
  if h then return h end
  h = {}
  col.headers[i] = h
  local body = col.view.content
  local okB = pcall(function()
    h.bg = ui.Rectangle.new(body)
    h.bg.fill = true
    h.bg.clickthrough = true
    h.accent = ui.Rectangle.new(body)
    h.accent.fill = true
    h.accent.rgba = ACCENT_RGBA
    h.accent.clickthrough = true
    h.accent.hidden = true
    h.icon = ui.Sprite.new(body)
    h.icon:SetSize(24, 24)
    h.icon.clickthrough = true
    h.icon.hidden = true
    h.text = ui.Text.new(body)
    h.text.font = HEADING_FONT
    h.text.rgba = HEADING_TEXT
    pcall(function() h.text.alignVertical = ui.AlignMode.CENTRE end)
    h.text.clickthrough = true
    h.arrow = ui.Sprite.new(body)
    -- must stay square: rotated art pivots inside its box and is clipped
    h.arrow:SetSize(ARROW_SIZE, ARROW_SIZE)
    h.arrow.spriteID = ARROW_SPRITE
    h.arrow.clickthrough = true
    h.btn = ui.Button.new(body)
    h.btn.alpha = 0
    h.btn.text.content = ""
    -- no ONCLICK: a left click already runs the menu's top entry
    h.btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
      h.hovered = true
      hoveredHeader = h
      applyHeaderLook(h)
      return true
    end)
    h.btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
      h.hovered = false
      if hoveredHeader == h then hoveredHeader = nil end
      applyHeaderLook(h)
      return true
    end)
    bindDrag(h, "c")
  end)
  if not okB then col.headers[i] = nil return nil end
  return h
end

local function hideHeader(h)
  pcall(function()
    h.bg.hidden = true
    h.accent.hidden = true
    h.icon.hidden = true
    h.text.hidden = true
    h.arrow.hidden = true
    h.btn.hidden = true
  end)
  if hoveredHeader == h then hoveredHeader = nil end
  h.hovered = false
end

local function applyRowLook(r)
  pcall(function()
    local fill = r.base
    if r.active then
      fill = ROW_SELECTED
    elseif r.hovered then
      fill = ROW_HOVER
    end
    r.bg.rgba = fill
    r.border.hidden = not r.active
  end)
end

local function ensureRow(i)
  local r = col.rows[i]
  if r then return r end
  r = {}
  col.rows[i] = r
  local body = col.view.content
  local okB = pcall(function()
    r.bg = ui.Rectangle.new(body)
    r.bg.fill = true
    r.bg.clickthrough = true
    r.accent = ui.Rectangle.new(body)
    r.accent.fill = true
    r.accent.rgba = ACCENT_RGBA
    r.accent.clickthrough = true
    r.accent.hidden = true
    r.border = ui.Rectangle.new(body)
    r.border.fill = false
    pcall(function() r.border.outlineThickness = 1 end)
    r.border.rgba = SELECTED_BORDER
    r.border.clickthrough = true
    r.border.hidden = true
    r.icon = ui.Sprite.new(body)
    r.icon:SetSize(24, 24)
    r.icon.clickthrough = true
    r.icon.hidden = true
    r.text = ui.Text.new(body)
    r.text.font = ROW_FONT
    r.text.rgba = ROW_TEXT_RGBA
    pcall(function() r.text.alignVertical = ui.AlignMode.CENTRE end)
    r.text.clickthrough = true
    r.btn = ui.Button.new(body)
    r.btn.alpha = 0
    r.btn.text.content = ""
    -- no ONCLICK: a left click already runs the menu's top entry
    r.btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
      r.hovered = true
      hoveredRow = r
      applyRowLook(r)
      return true
    end)
    r.btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
      r.hovered = false
      if hoveredRow == r then hoveredRow = nil end
      applyRowLook(r)
      return true
    end)
    bindDrag(r, "p")
  end)
  if not okB then col.rows[i] = nil return nil end
  return r
end

local function ensureSep(i)
  local sp = col.seps[i]
  if sp then return sp end
  local ok = pcall(function()
    sp = ui.Rectangle.new(col.view.content)
    sp.fill = true
    sp.rgba = CARD_SEP_RGBA
    sp.clickthrough = true
  end)
  if not ok then return nil end
  col.seps[i] = sp
  return sp
end

local function hideRow(r)
  pcall(function()
    r.bg.hidden = true
    r.accent.hidden = true
    r.border.hidden = true
    r.icon.hidden = true
    r.text.hidden = true
    r.btn.hidden = true
  end)
  if hoveredRow == r then hoveredRow = nil end
  r.preset = nil
  r.hovered = false
  r.active = false
end

render = function()
  if col == nil then return end
  local vw, vh = viewBounds(col.ctx)

  pcall(function()
    col.plusBtn.root.hidden = prefs.GetBool("ui.noCategories") == true
  end)

  local lockState = store.Locked() and store.IdentityState() or nil

  -- Row width is decided before layout: rows are counted first and stop
  -- short of the scrollbar lane when they overflow.
  local groups = (lockState == nil) and buildGroups() or {}
  local total = 0
  for _, group in ipairs(groups) do
    if group.header ~= nil then
      total = total + 1
      -- a search shows collapsed sections open without writing the state
      group.collapsed = searchQuery == "" and
        window.IsCollapsed(group.header)
      if not group.collapsed then total = total + #group.items end
    else
      total = total + #group.items
    end
  end
  local inner = (total * ROW_H > vh) and (vw - SCROLLBAR_W) or vw
  local lines = window.LockLines(lockState)
  for i = 1, window.NOTICE_LINES do
    pcall(function()
      col.notice[i].content = lines[i] or ""
      col.notice[i].hidden = lines[i] == nil
      col.notice[i]:SetSize(inner, 16)
    end)
  end

  local hIdx, rIdx, sIdx = 0, 0, 0
  local y = LIST_TOP
  local empty = true
  -- col.zones is the drop geometry resolveDrop reads: one zone per group
  local flat = prefs.GetBool("ui.noCategories") == true
  col.zones = {}
  col.inner = inner
  col.orderIdx = nil
  if prefs.GetBool("ui.lockAlpha") ~= true then
    col.orderIdx = store.PresetOrderIndex()
  end
  pcall(function()
    col.rename.root.hidden = true
    col.renameOk.root.hidden = true
  end)

  if lockState == nil then
    local activeId = bankutil.ActivePresetId()
    local band = 0
    local prevExpandedCard = false
    for _, group in ipairs(groups) do
      local collapsed = false
      local zoneStart, zoneRows = y, {}
      if group.header ~= nil then
        if prevExpandedCard then
          sIdx = sIdx + 1
          local sp = ensureSep(sIdx)
          if sp ~= nil then
            pcall(function()
              sp.hidden = false
              sp:SetPos(0, y)
              sp:SetSize(inner, 1)
              -- siblings render in creation order, and a pooled separator
              -- can be older than a heading created later
              sp:MoveToFront()
            end)
          end
        end
        hIdx = hIdx + 1
        local h = ensureHeader(hIdx)
        if h ~= nil then
          h.cat = group.header
          collapsed = group.collapsed == true
          h.expanded = not collapsed
          band = band + 1
          h.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
          pcall(function()
            h.bg.hidden = false
            h.bg:SetPos(0, y)
            h.bg:SetSize(inner, ROW_H)
            h.accent:SetPos(0, y)
            h.accent:SetSize(ACCENT_W, ROW_H)
            local textX = 6
            if group.icon ~= nil then
              h.icon.hidden = false
              h.icon:SetPos(4, y + 5)
              pcall(function() h.icon.spriteID = group.icon end)
              textX = 32
            else
              -- pooled part: without this the previous occupant's icon shows
              h.icon.hidden = true
            end
            h.text.hidden = false
            h.text:SetPos(textX, y)
            h.text:SetSize(inner - textX - ARROW_SIZE - ARROW_PAD - 6, ROW_H)
            h.text.content = group.header
            h.arrow.hidden = false
            h.arrow:SetPos(inner - ARROW_SIZE - ARROW_PAD,
              y + math.floor((ROW_H - ARROW_SIZE) / 2))
            h.btn.hidden = false
            h.btn:SetPos(0, y)
            h.btn:SetSize(inner, ROW_H)
            applyHeaderLook(h)
            -- the rename field and OK are created at mount, before any row,
            -- so they need MoveToFront to sit above the pooled parts
            if col.editingCat == group.header then
              h.text.hidden = true
              h.icon.hidden = true
              h.arrow.hidden = true
              col.rename.root.hidden = false
              col.rename.root:SetPos(4, y + 2)
              col.rename.root:SetSize(inner - 70, 26)
              if col.renameFor ~= "c:" .. group.header then
                col.renameFor = "c:" .. group.header
                col.rename:SetText(group.header)
              end
              col.rename.root:MoveToFront()
              col.renameOk.root.hidden = false
              col.renameOk.root:SetPos(inner - 62, y + 3)
              col.renameOk.root:MoveToFront()
            end
          end)
          y = y + ROW_H
        end
        empty = false
      end
      if not collapsed then
        for _, p in ipairs(group.items) do
          rIdx = rIdx + 1
          local r = ensureRow(rIdx)
          if r ~= nil then
            r.preset = p
            r.active = activeId == p.id
            band = band + 1
            r.base = (band % 2 == 1) and ROW_ODD or ROW_EVEN
            local indent = (group.header ~= nil) and CAT_INDENT or 0
            local nameX = ((p.icon ~= nil) and 35 or 10) + indent
            pcall(function()
              r.bg.hidden = false
              r.bg:SetPos(0, y)
              r.bg:SetSize(inner, ROW_H)
              r.accent.hidden = group.header == nil
              r.accent:SetPos(0, y)
              r.accent:SetSize(ACCENT_W, ROW_H)
              r.border:SetPos(0, y)
              r.border:SetSize(inner, ROW_H)
              if p.icon ~= nil then
                r.icon.hidden = false
                r.icon:SetPos(4 + indent, y + 3)
                pcall(function() r.icon.spriteID = p.icon end)
              else
                -- pooled part: without this the previous occupant's icon shows
                r.icon.hidden = true
              end
              r.text.hidden = false
              r.text:SetPos(nameX, y)
              r.text:SetSize(math.max(40, inner - nameX - 6), ROW_H)
              r.text.content = p.name
              r.btn.hidden = false
              r.btn:SetPos(0, y)
              r.btn:SetSize(inner, ROW_H)
              applyRowLook(r)
              if col.editingPreset == p.id then
                r.text.hidden = true
                r.icon.hidden = true
                col.rename.root.hidden = false
                col.rename.root:SetPos(4, y + 2)
                col.rename.root:SetSize(inner - 70, 26)
                if col.renameFor ~= "p:" .. p.id then
                  col.renameFor = "p:" .. p.id
                  col.rename:SetText(p.name)
                end
                col.rename.root:MoveToFront()
                col.renameOk.root.hidden = false
                col.renameOk.root:SetPos(inner - 62, y + 3)
                col.renameOk.root:MoveToFront()
              end
            end)
            zoneRows[#zoneRows + 1] = { id = p.id, y0 = y, y1 = y + ROW_H }
            y = y + ROW_H
            empty = false
          end
        end
      end
      col.zones[#col.zones + 1] = { cat = group.header,
        headed = group.header ~= nil, flat = flat,
        y0 = zoneStart, y1 = y, rows = zoneRows }
      prevExpandedCard = group.header ~= nil and not collapsed
    end
  end

  for i = hIdx + 1, #col.headers do hideHeader(col.headers[i]) end
  for i = rIdx + 1, #col.rows do hideRow(col.rows[i]) end
  for i = sIdx + 1, #col.seps do
    pcall(function() col.seps[i].hidden = true end)
  end
  -- again after the loop: a heading created during it covers the separator
  for i = 1, sIdx do
    pcall(function() col.seps[i]:MoveToFront() end)
  end
  pcall(function()
    local showEmpty = empty and lockState == nil
    local searching = searchQuery ~= ""
    local eLines = (not showEmpty) and {}
      or (searching and { "No matching presets" })
      or { "No presets yet", "Press Save Preset" }
    for i = 1, 2 do
      col.emptyHint[i].content = eLines[i] or ""
      col.emptyHint[i].hidden = eLines[i] == nil
      col.emptyHint[i]:SetSize(inner, 16)
    end
  end)
  col.contentH = y
  pcall(function() col.view:SetContentHeight(y) end)
end

local function placeChrome(ctx)
  local vw, vh = viewBounds(ctx)
  pcall(function()
    col.frame:SetPos(PAD, VIEW_Y - 1)
    col.frame:SetSize(ctx.width - PAD * 2, vh + 2)
  end)
  pcall(function()
    col.view.root:SetPos(PAD + 1, VIEW_Y)
    col.view:SetSize(vw, vh)
  end)
  local searchW = ctx.width - PAD * 2 - (SIDE_BTN_W + 6) * 2
  pcall(function()
    col.search.root:SetPos(PAD, PAD)
    col.search.root:SetSize(searchW, SEARCH_H)
    col.searchIcon:SetPos(PAD + 6, PAD + 6)
    pcall(function() col.searchIcon:MoveToFront() end)
    col.clear.root:SetPos(PAD + searchW - 21, PAD + 6)
  end)
  pcall(function() col.plusBtn.root:SetPos(PAD + searchW + 6, PAD) end)
  pcall(function()
    col.impBtn.root:SetPos(PAD + searchW + 6 + SIDE_BTN_W + 6, PAD)
  end)
  -- Save is positioned, never resized: a FancyButton's width is intrinsic
  local btnY = ctx.height - LIST_BOTTOM_BUFFER
    + math.floor((LIST_BOTTOM_BUFFER - SAVE_H) / 2)
  pcall(function()
    col.saveBtn.root:SetPos(PAD + math.max(0,
      math.floor((ctx.width - PAD * 2 - (col.saveW or 0)) / 2)), btnY)
  end)
end

local function mount(ctx)
  col = { ctx = ctx, rows = {}, headers = {}, seps = {}, notice = {} }
  searchQuery = ""
  col.search = prettyui.TextField.new(ctx.parent, {
    categoryID = "auto",
    x = PAD, y = PAD, width = ctx.width - PAD * 2, height = SEARCH_H,
    maxLength = 25, placeholder = "Search...",
    contentMargin = ui.Margin.new(26, 3, 26, 0),
    onChange = function()
      -- GetText, not the callback's argument, which is unreliable; onChange
      -- also fires on focus loss, hence the comparison
      pcall(function()
        local q = col.search:GetText() or ""
        pcall(function() col.clear.SetVisible(q ~= "") end)
        if q ~= searchQuery then
          searchQuery = q
          scheduleRender()
        end
      end)
    end,
  })
  col.searchIcon = ui.Sprite.new(ctx.parent)
  col.searchIcon:SetSize(16, 16)
  col.searchIcon.spriteID = 25230
  col.searchIcon.clickthrough = true

  col.clear = uikit.AttachClearButton(ctx.parent, function()
    searchQuery = ""
    pcall(function() col.search:SetText("") end) -- SetText fires no onChange
    col.clear.SetVisible(false)
    scheduleRender()
  end)
  -- the label is fitted to the space: the button cannot be narrowed
  local saveAvail = ctx.width - PAD * 2
  local saveLabel = "Save"
  col.saveW = prettyui.FancyButton.getSize("Save")
  for _, candidate in ipairs({ "Save Preset" }) do
    local cw = prettyui.FancyButton.getSize(candidate)
    if cw <= saveAvail then
      saveLabel, col.saveW = candidate, cw
      break
    end
  end
  col.saveBtn = prettyui.FancyButton.new(ctx.parent, saveLabel,
    function()
      pcall(window.SaveCurrentGear)
    end, { variant = "positive", categoryID = "auto" })
  -- the tip's parent is the layer the button lives on (same coordinates)
  uikit.AttachDelayedTooltip(col.saveBtn.root,
    "Save your current gear and backpack as a new preset", ctx.parent)
  col.plusBtn = prettyui.SimpleButton.new(ctx.parent,
    prettyui.Sprites.SPRITE_BUTTONS.PLUS.neutral, function()
    local ok, err = pcall(function()
      local name = store.AddCategory()
      if name == nil then -- the vault is locked
        uikit.PlaySfx(uikit.BLOCKED_SFX)
        return
      end
      uikit.PlaySfx(uikit.CLICK_SFX)
      col.editingPreset = nil
      col.editingCat = name
      col.renameFor = nil
      window.Relayout()
    end)
    if not ok then
      log(formatStr("[PV Bankcore] column add category failed: {}", tostring(err)))
    end
    scheduleRender()
  end, { size = SIDE_BTN_W, iconSize = 14, categoryID = "auto" })
  uikit.AttachDelayedTooltip(col.plusBtn.root, "New category", ctx.parent)
  col.impBtn = prettyui.SimpleButton.new(ctx.parent, 29456, function()
    uikit.PlaySfx(uikit.CLICK_SFX)
    pcall(window.OpenImport)
  end, { size = SIDE_BTN_W, iconSize = 16, categoryID = "auto" })
  uikit.AttachDelayedTooltip(col.impBtn.root,
    "Import share code", ctx.parent)
  col.frame = ui.Rectangle.new(ctx.parent)
  col.frame.fill = false
  pcall(function() col.frame.outlineThickness = 1 end)
  col.frame.rgba = LIST_FRAME_RGBA
  col.frame.clickthrough = true
  local vw, vh = viewBounds(ctx)
  col.view = prettyui.SimpleView.new(ctx.parent, {
    categoryID = "auto",
    x = PAD + 1, y = VIEW_Y,
    width = vw, height = vh,
    scrollable = true, scrollStep = ROW_H,
  })
  placeChrome(ctx)
  local body = col.view.content
  for i = 1, window.NOTICE_LINES do
    local t = ui.Text.new(body)
    t:SetPos(0, 8 + (i - 1) * 19)
    t:SetSize(vw, 16)
    t.font = id.Font.MUSEO_SANS_15PT_REGULAR
    t.rgba = (i == 1) and 0xE0B050FF or 0xB8A169CC
    t.alignHorizontal = ui.AlignMode.CENTRE
    t.clickthrough = true
    t.hidden = true
    col.notice[i] = t
  end
  col.emptyHint = {}
  for i = 1, 2 do
    local t = ui.Text.new(body)
    t:SetPos(0, 8 + (i - 1) * 19)
    t:SetSize(vw, 16)
    t.font = id.Font.MUSEO_SANS_15PT_REGULAR
    t.rgba = 0xB8A169CC
    t.alignHorizontal = ui.AlignMode.CENTRE
    t.clickthrough = true
    t.hidden = true
    col.emptyHint[i] = t
  end
  -- One rename field serves headings and rows. There is no API to focus
  -- it; the user has to click it.
  local function commitRename()
    if col == nil then return end
    local oldCat = col.editingCat
    local presetId = col.editingPreset
    col.editingCat = nil
    col.editingPreset = nil
    col.renameFor = nil
    if oldCat ~= nil then
      pcall(function()
        local newName = store.CleanName(col.rename:GetText())
        if newName ~= "" and newName ~= oldCat then
          window.SetCollapsed(newName, window.IsCollapsed(oldCat))
          store.RenameCategory(oldCat, newName)
        end
      end)
    elseif presetId ~= nil then
      pcall(function()
        local newName = store.CleanName(col.rename:GetText())
        if newName == "" then newName = "Untitled" end
        store.Rename(presetId, newName)
      end)
    end
    scheduleRender()
    window.Relayout()
  end
  col.rename = prettyui.TextField.new(body, {
    x = 4, y = 0, width = vw - 70, height = 26,
    maxLength = 25, placeholder = "Name",
    onSubmit = commitRename,
    _onScrollWheel = col.view._onScrollWheel,
  })
  col.rename.root.hidden = true
  col.renameOk = prettyui.SimpleButton.new(body, "OK", function()
    commitRename()
  end, { x = vw - 62, y = 0, width = 54, height = 24,
    _onScrollWheel = col.view._onScrollWheel })
  col.renameOk.root.hidden = true
  render()
end

local function resize(ctx)
  if col == nil then return end
  col.ctx = ctx
  placeChrome(ctx)
  render()
end

local function unmount()
  -- Core destroys both layers after this; a handle held past it stays
  -- responsive but never renders again
  col = nil
  hoveredRow = nil
  hoveredHeader = nil
  press, pendingClick = nil, nil
end

M.Provider = {
  mount = function(ctx)
    local ok, err = pcall(mount, ctx)
    if not ok then
      col = nil
      log(formatStr("[PV Bankcore] column mount failed: {}", tostring(err)))
      error(err, 0) -- rethrown so Core shows its column error state
    end
  end,
  resize = function(ctx) pcall(resize, ctx) end,
  unmount = function() unmount() end,
}

return M
