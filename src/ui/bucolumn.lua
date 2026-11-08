-- The BankUtil Core sidebar column: a search field, a scrolling list of
-- category and preset rows, and Save / new-category / import buttons.
-- While integration is active this IS the vault UI.
--
-- Left-clicking a row toggles its Core-backed bank view; everything else is
-- on the right-click menus. This file only draws - the behaviour it
-- triggers lives in pvwin.lua exports and the core modules.
--
-- LIFECYCLE: Core DESTROYS these layers on every bank close, column switch
-- and dispose, so mount() rebuilds from nothing and nothing may be cached
-- across mounts. Components are pooled WITHIN a mount.
local M = {}

local store = require("core/store")
local bankutil = require("core/bankutil")
local uikit = require("ui/uikit")
local bankpage = require("ui/bankpage")
local window = require("ui/pvwin")

local PAD = 8
local SAVE_H = 28
local SEARCH_H = 28 -- the always-visible filter field at the top
-- Column layout: search across the top, the framed list between, one row of
-- buttons at the foot.
local VIEW_Y = PAD + SEARCH_H + 10 -- top of the framed section
local LIST_BOTTOM_BUFFER = 40
local SIDE_BTN_W = 28 -- the square new-category / import buttons
-- Rows fill the framed section EDGE TO EDGE: no inner padding at the top,
-- sides or bottom - the zebra runs flush against the frame.
local LIST_TOP = 0 -- first row's y INSIDE the scrolling content
local ROW_H = 30 -- headings use the same height: they are rows in the flow
local CAT_INDENT = 8 -- extra left indent on rows sitting under a heading

-- Core's bank theme. Zebra bands are 80% alpha; fills are opaque.
local ROW_ODD = 0x211E1BCC
local ROW_EVEN = 0x2A2622CC
local ROW_HOVER = 0x403728FF
local ROW_SELECTED = 0x49371FFF
local ROW_TEXT_RGBA = 0xD7D0BFFF -- preset names
local SELECTED_BORDER = 0xD2A84DFF
local HEADING_TEXT = 0xD1BF9AFF -- category names

-- The frame around the whole list section: a muted grey-brown, quiet enough
-- that the active preset's gold border stays the loudest thing on screen.
local LIST_FRAME_RGBA = 0x726551FF

-- An EXPANDED heading's fill: a very soft gold, well under ROW_SELECTED so
-- the active preset still owns the strong gold.
local HEADING_EXPANDED = 0x3B3222FF
local HEADING_EXPANDED_HOVER = 0x463A26FF

-- The thin strip down the far left of an expanded heading and its rows -
-- the "selected card" tab that unites a section.
local ACCENT_W = 2
local ACCENT_RGBA = 0xD2A84D90
-- 1px separator, drawn only where a heading sits below an EXPANDED card.
local CARD_SEP_RGBA = 0x756C60FF

-- Heading collapse chevron, far right of the row.
local ARROW_SPRITE = 8085
local ARROW_COLLAPSED_DEG = 270 -- anticlockwise 270 = 90 clockwise: up -> right
local ARROW_EXPANDED_DEG = 180 -- half turn: up -> down
local ARROW_SIZE = 16 -- 8085's art reads big; 24 overwhelmed the 30px row
local ARROW_PAD = 4 -- chevron inset from a row's right edge

-- The scrollbar's lane. Rows stop short of it when the list overflows, and
-- span the full width when it fits.
local SCROLLBAR_W = 18

-- Core's headings use the smallest available MUSEO face (uikit probes it;
-- a missing font enum resolves to -1, not nil, so names cannot be trusted
-- blind).
local HEADING_FONT = (uikit.SmallFont())
-- Preset rows share the headings' small face - and its fallback. There is no
-- reason for a row to out-size the category it sits under.
local ROW_FONT = HEADING_FONT

local col = nil -- { ctx, view, frame, saveBtn, search, plusBtn, impBtn,
-- emptyHint, notice, rows, headers, editingCat, editingPreset, renameFor }
local hoveredRow = nil -- the preset row under the pointer; the menu's target
local hoveredHeader = nil -- the category row under the pointer, likewise

-- ---- search -------------------------------------------------------------------
-- Case-insensitive substring; `*` switches to an anchored wildcard. The
-- matcher itself is shared with the window (uikit.MatchesSearch).
local searchQuery = ""
local function matchesSearch(name)
  return uikit.MatchesSearch(name, searchQuery)
end

-- The scrolling view's size inside the frame (which matches the save
-- button's width: x PAD, width - PAD*2), from the column's bounds.
local function viewBounds(ctx)
  local vw = ctx.width - PAD * 2 - 2
  local vh = math.max(60, ctx.height - VIEW_Y - LIST_BOTTOM_BUFFER - 4)
  return vw, vh
end

-- ---- deferred render --------------------------------------------------------
-- Every trigger funnels through one per-tick flag.
local renderPending = false
local function scheduleRender()
  renderPending = true
end
M.OnIdentityChanged = scheduleRender

-- Defined under "actions" below; the menu callbacks above them need the
-- names (a later `local function` is invisible to an earlier closure).
local toggleView, toggleCollapse

local render -- forward declaration

uikit.AddTicker("pvColumnRender", function()
  if not renderPending then return end
  renderPending = false
  if col ~= nil then pcall(render) end
end)

-- The window mirrors list changes out through this hook (fired at the end of
-- every relayout, and from OnVaultChanged when the window was never built).
window.OnListChanged = scheduleRender
-- pvwin.lua already points bankutil.OnViewChanged at its own relayout;
-- wrap rather than replace it, so both surfaces refresh their highlights
-- when the Core-backed view dies outside our buttons.
local prevViewHook = bankutil.OnViewChanged
bankutil.OnViewChanged = function()
  if prevViewHook then pcall(prevViewHook) end
  scheduleRender()
end

-- ---- right-click menu entries -------------------------------------------------
-- Entries are added during Event.MiniMenuReady, targeting whichever row the
-- pointer is on. Only the preset ID crosses into a callback - never a
-- component handle or a row table.
--
-- The subscription lives for the plugin's life, guarded on a mounted
-- column.
local function presetById(id)
  for _, p in ipairs(store.All()) do
    if p.id == id then return p end
  end
  return nil
end

-- Preset rename = the same inline field the categories use, over the row.
local function onRenameEntry(presetId)
  if col == nil or presetId == nil then return end
  col.editingPreset = presetId
  col.editingCat = nil
  col.renameFor = nil
  scheduleRender()
end

local function onIconEntry(presetId)
  pcall(function()
    local p = presetById(presetId)
    if p ~= nil then window.OpenIconPicker(p) end
  end)
end

local function onShareEntry(presetId)
  pcall(function()
    local p = presetById(presetId)
    if p ~= nil then window.OpenShare(p) end
  end)
end

-- "Move to >" submenu child: recategorise the preset. `false` stands in for
-- Uncategorised - a real nil in the arguments table would truncate it.
local function onMoveEntry(presetId, cat)
  pcall(function()
    store.SetCategory(presetId, cat ~= false and cat or nil)
    window.Relayout()
  end)
  -- same chime as the window's drag-and-drop: one gesture, one sound
  uikit.PlaySfx(uikit.DROP_SFX)
  scheduleRender()
end

-- Both deletes fire on one pick, same as the window's edit-mode trash
-- buttons: reaching a named entry inside a right-click menu is deliberate
-- enough on its own.
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
    store.DeleteCategory(cat) -- presets fall back to Uncategorised
    window.Relayout()
  end)
  if not ok then
    log(formatStr("[PV Bankcore] column delete category failed: {}", tostring(err)))
  end
  uikit.PlaySfx(uikit.CLICK_SFX)
  scheduleRender()
end

-- Category rename = an inline rename field over the heading row (render
-- shows it; commitRename below stores it). Set by the menu entry.
local function onEditCategory(cat)
  if col == nil or cat == nil then return end
  col.editingCat = cat
  col.editingPreset = nil
  col.renameFor = nil
  scheduleRender()
end

-- "Set Icon" on a heading: the window-owned picker, same flow as a preset's.
local function onIconCategory(cat)
  if cat == nil then return end
  pcall(function() window.OpenCategoryIconPicker(cat) end)
end

-- "Move above >" / "Move below >" submenu child: slot this category
-- directly above or below the picked one.
local function onMoveCategory(cat, target, below)
  pcall(function()
    store.MoveCategory(cat, target, below == true)
    window.Relayout() -- shared data: the standalone window follows along
  end)
  -- same chime as every other reorder gesture
  uikit.PlaySfx(uikit.DROP_SFX)
  scheduleRender()
end

-- displayed text is MARKUP: escape user-typed names in one pass
local function escapeMarkup(s)
  return (tostring(s or ""):gsub("[<>]", { ["<"] = "<lt>", [">"] = "<gt>" }))
end

-- Wraps a target name in the menus' gold span.
local function menuTarget(name)
  return "<col=e7c878>" .. escapeMarkup(name) .. "</col>"
end

-- Adds an entry and Swaps it up to the HIGH-INDEX end, which is the visual
-- TOP. The new entry is found by holding the pre-Add handles and taking the
-- one that is == to none of them.
local function addMenuEntryFront(menu, label, fn, arg)
  local count = nil
  pcall(function() count = menu.entryCount end)
  if count == nil or count <= 0 then count = #menu.entries end
  local before = {}
  for i = 1, count do before[#before + 1] = menu.entries[i] end
  menu:Add(label, fn, arg)
  pcall(function() count = menu.entryCount end)
  if count == nil or count <= 0 then count = #menu.entries end
  for i = count, 1, -1 do
    local e = menu.entries[i]
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

-- Promotes an entry found by an `overrideText` prefix. No-op when there is
-- none, as in flat mode.
local function promoteByOverridePrefix(menu, prefix)
  local count = nil
  pcall(function() count = menu.entryCount end)
  if count == nil or count <= 0 then count = #menu.entries end
  for i = count, 1, -1 do
    local hit = false
    pcall(function()
      local t = menu.entries[i].overrideText
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

-- The menu IS the action pipeline: the rows carry NO button handlers of
-- their own, so a click cannot double-fire.
local function onViewEntry(presetId)
  pcall(function()
    local p = presetById(presetId)
    if p ~= nil then toggleView(p) end
  end)
end

local function onToggleCatEntry(cat)
  pcall(function() toggleCollapse(cat) end)
end

Event.MiniMenuReady.Subscribe("pvColumnMenu", function(event)
  pcall(function()
    if col == nil then return end
    if hoveredRow ~= nil and hoveredRow.preset ~= nil then
      local p = hoveredRow.preset
      -- "Move to >" goes FIRST, on the still-virgin menu, and only when
      -- categories are on with somewhere to move to. Child labels are
      -- escaped display markup; the arguments carry the RAW category name.
      if PersistentDB:GetBool("ui.noCategories") ~= true then
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
      -- The rest build BOTTOM-UP, with the Move-to parent text-promoted at
      -- its slot. Final order: Load/Hide, Move to, Rename, Set Icon,
      -- Share, Remove, Cancel. Only the TOP entry carries the name.
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
      -- Uncategorised is a pinned pseudo-bucket, not a real category, so
      -- it gets open/close but not rename, icon, remove or reorder. Order:
      -- Open/Close, Move above >, Move below >, Rename, Set Icon, Remove,
      -- Cancel, name on the top entry only.
      if cat ~= window.UNCAT then
        -- Category reordering, menu-driven: pick the category to slot this
        -- one above or below. The column has no drag, so this is its whole
        -- reorder story.
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

-- ---- data -------------------------------------------------------------------
local function orderedPresets()
  local list = {}
  for _, p in ipairs(store.All()) do list[#list + 1] = p end
  if PersistentDB:GetBool("ui.lockAlpha") == true then
    -- "Lock preset order alphabetically" IGNORES the stored order (same
    -- rule as the window: the arrangement survives underneath).
    table.sort(list, store.NameOrder)
  else
    local idx = store.PresetOrderIndex()
    table.sort(list, function(a, b)
      return (idx[a.id] or 0) < (idx[b.id] or 0)
    end)
  end
  return list
end

-- Groups in display order: { header = categoryName|nil, items = {presets} },
-- search-filtered first.
local function buildGroups()
  local presets = {}
  for _, p in ipairs(orderedPresets()) do
    if matchesSearch(p.name) then presets[#presets + 1] = p end
  end
  if PersistentDB:GetBool("ui.noCategories") == true then
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
  if PersistentDB:GetBool("ui.noUncatBucket") == true then
    -- bucket off: uncategorised presets render free-standing at the top
    if #uncat > 0 then groups[#groups + 1] = { header = nil, items = uncat } end
  else
    -- An empty Uncategorised hides entirely, matching the window's rule.
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
  -- While searching, categories with no matches vanish entirely (the pinned
  -- Uncategorised bucket included) - a header over nothing reads as a
  -- failed search, same rule as the window.
  if searchQuery ~= "" then
    local kept = {}
    for _, g in ipairs(groups) do
      if #g.items > 0 then kept[#kept + 1] = g end
    end
    return kept
  end
  return groups
end

-- ---- actions ----------------------------------------------------------------
-- The B behaviour: identical routing to the window's name button, minus the
-- panel-engine branch - this column only exists while integration is active.
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
        bankpage.FlashWrongTab() -- gold pulse + chime, same as everywhere
      else
        uikit.PlaySfx(uikit.BLOCKED_SFX)
        log(formatStr("[PV Bankcore] column: bank view unavailable ({})", tostring(why)))
      end
    end
  end)
  if not ok then log(formatStr("[PV Bankcore] column toggle failed: {}", tostring(err))) end
  scheduleRender() -- highlight refresh (the view hook fires too; coalesced)
end

toggleCollapse = function(cat)
  if cat == nil then return end
  pcall(function()
    window.SetCollapsed(cat, not window.IsCollapsed(cat))
    window.PlayCategorySfx()
  end)
  scheduleRender()
  window.Relayout() -- shared keys: the window's section follows along
end

-- ---- pooled parts (per mount - Core destroys them with the column) ----------
-- A heading row: band or soft-gold fill, gold text, chevron, accent strip.
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
    h.arrow:SetSize(ARROW_SIZE, ARROW_SIZE) -- square: rotation-pivot-proof
    h.arrow.spriteID = ARROW_SPRITE
    h.arrow.clickthrough = true
    h.btn = ui.Button.new(body)
    h.btn.alpha = 0
    h.btn.text.content = ""
    -- no press handler: the left click executes the menu's top entry
    -- (Open/Close Category) - a handler here would double-fire
    h.btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
      h.hovered = true
      hoveredHeader = h -- the right-click Rename entry targets this category
      applyHeaderLook(h)
      return true
    end)
    h.btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
      h.hovered = false
      if hoveredHeader == h then hoveredHeader = nil end
      applyHeaderLook(h)
      return true
    end)
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

-- A preset row: band with hover and selected fills, a gold border while its
-- bank view is live, optional icon and name. The band is a rect; an
-- invisible ui.Button over it takes the click and the hover.
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
    -- the thin far-left strip uniting a category's rows with their heading
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
    -- no press handler: the left click executes the menu's top entry
    -- (Load/Hide Preset) - a handler here would double-fire
    r.btn:Subscribe(ui.Hook.ONMOUSEOVER, function()
      r.hovered = true
      hoveredRow = r -- the right-click Open entry targets this row
      applyRowLook(r)
      return true
    end)
    r.btn:Subscribe(ui.Hook.ONMOUSELEAVE, function()
      r.hovered = false
      if hoveredRow == r then hoveredRow = nil end
      applyRowLook(r)
      return true
    end)
  end)
  if not okB then col.rows[i] = nil return nil end
  return r
end

-- Card separators: pooled 1px lines (see CARD_SEP_RGBA). MoveToFront on
-- every placement: a pooled separator can be OLDER than a heading bg the
-- pool grew later, and siblings render in creation order.
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

-- ---- render -----------------------------------------------------------------
render = function()
  if col == nil then return end
  local vw, vh = viewBounds(col.ctx)

  -- The "+" button only means something while categories exist to add to;
  -- flat mode hides it (the settings toggle relayouts, which lands here).
  pcall(function()
    col.plusBtn.root.hidden = PersistentDB:GetBool("ui.noCategories") == true
  end)

  -- Lock notice: the same states and copy as the window - a locked vault is
  -- deliberately empty, and that has to be said rather than shown.
  local lockState = store.Locked() and store.IdentityState() or nil

  -- Row width is decided BEFORE layout: count the rows this pass will
  -- show, and stop them short of the scrollbar lane if they overflow.
  -- Collapse state is read once here and reused by the layout loop.
  local groups = (lockState == nil) and buildGroups() or {}
  local total = 0
  for _, group in ipairs(groups) do
    if group.header ~= nil then
      total = total + 1
      -- Collapsed sections FORCE-EXPAND while searching (a match hidden in
      -- a collapsed category reads as no result); the session collapse state
      -- is read past, never written - the window's rule.
      group.collapsed = searchQuery == "" and
        window.IsCollapsed(group.header)
      if not group.collapsed then total = total + #group.items end
    else
      total = total + #group.items
    end
  end
  local inner = (total * ROW_H > vh) and (vw - SCROLLBAR_W) or vw
  -- The lines live in pvwin.lua (LockLines) so both surfaces always say
  -- the same thing.
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
  -- default-hidden each pass; the matching header's branch shows it
  pcall(function()
    col.rename.root.hidden = true
    col.renameOk.root.hidden = true
  end)

  if lockState == nil then
    local activeId = bankutil.ActivePresetId()
    -- ONE continuous zebra from top to bottom - headings count in the
    -- alternation like any other row, and nothing leaves gaps. The list
    -- should read as one cohesive, connected surface.
    local band = 0
    local prevExpandedCard = false
    for _, group in ipairs(groups) do
      local collapsed = false
      if group.header ~= nil then
        -- the previous card ended here: mark the boundary
        if prevExpandedCard then
          sIdx = sIdx + 1
          local sp = ensureSep(sIdx)
          if sp ~= nil then
            pcall(function()
              sp.hidden = false
              sp:SetPos(0, y)
              sp:SetSize(inner, 1)
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
            -- Category icon before the name; the name shifts left to the
            -- edge when there is none. Explicitly hidden otherwise - the
            -- pooled-ghost rule, same as the preset rows' icons.
            local textX = 6
            if group.icon ~= nil then
              h.icon.hidden = false
              -- 24px icon in the 30px row, a touch lower than centred
              h.icon:SetPos(4, y + 5)
              pcall(function() h.icon.spriteID = group.icon end)
              textX = 32
            else
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
            -- inline rename takes the heading row over (field + OK sit
            -- above the pooled parts via MoveToFront - created earlier,
            -- so sibling order alone would bury them)
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
            -- An iconless name hugs the left; an icon'd row indents only
            -- as far as the icon needs. Rows under a heading take an extra
            -- indent, icon included; free-standing and flat rows stay
            -- flush.
            local indent = (group.header ~= nil) and CAT_INDENT or 0
            local nameX = ((p.icon ~= nil) and 35 or 10) + indent
            pcall(function()
              r.bg.hidden = false
              r.bg:SetPos(0, y)
              r.bg:SetSize(inner, ROW_H)
              -- the strip only unites HEADED sections with their heading;
              -- flat mode and free-standing uncategorised rows go without
              r.accent.hidden = group.header == nil
              r.accent:SetPos(0, y)
              r.accent:SetSize(ACCENT_W, ROW_H)
              r.border:SetPos(0, y)
              r.border:SetSize(inner, ROW_H)
              -- Icon shown only when this preset has one, and explicitly
              -- HIDDEN otherwise.
              if p.icon ~= nil then
                r.icon.hidden = false
                -- 24px icon in a 30px row: x pulled to 4 so a 2px gap
                -- stays before the name at 30, y 3 keeps it centred
                r.icon:SetPos(4 + indent, y + 3)
                pcall(function() r.icon.spriteID = p.icon end)
              else
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
              -- Inline preset rename: the same pooled field + OK pair the
              -- category headings use, drawn over this row.
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
            y = y + ROW_H
            empty = false
          end
        end
      end
      prevExpandedCard = group.header ~= nil and not collapsed
    end
  end

  for i = hIdx + 1, #col.headers do hideHeader(col.headers[i]) end
  for i = rIdx + 1, #col.rows do hideRow(col.rows[i]) end
  for i = sIdx + 1, #col.seps do
    pcall(function() col.seps[i].hidden = true end)
  end
  -- Re-front the shown separators AFTER the layout loop.
  for i = 1, sIdx do
    pcall(function() col.seps[i]:MoveToFront() end)
  end
  pcall(function()
    local showEmpty = empty and lockState == nil
    local searching = searchQuery ~= ""
    -- line 1: the state; line 2: the call to action (empty vault only, not
    -- when a search just found nothing)
    local eLines = (not showEmpty) and {}
      or (searching and { "No matching presets" })
      or { "No presets yet", "Press Save Preset" }
    for i = 1, 2 do
      col.emptyHint[i].content = eLines[i] or ""
      col.emptyHint[i].hidden = eLines[i] == nil
      col.emptyHint[i]:SetSize(inner, 16)
    end
  end)
  pcall(function() col.view:SetContentHeight(y) end)
end

-- ---- Core column callbacks ----------------------------------------------------
-- The frame + view + save-button geometry, shared by mount and resize.
local function placeChrome(ctx)
  local vw, vh = viewBounds(ctx)
  -- Flush against the rows: the border line sits ONE pixel outside the
  -- view, no standoff (the earlier 4px inset read as a stray buffer).
  pcall(function()
    col.frame:SetPos(PAD, VIEW_Y - 1)
    col.frame:SetSize(ctx.width - PAD * 2, vh + 2)
  end)
  pcall(function()
    col.view.root:SetPos(PAD + 1, VIEW_Y)
    col.view:SetSize(vw, vh)
  end)
  -- Top row: search with the square new-category and import buttons on its
  -- right. They share this row so the bottom row belongs to Save alone -
  -- being text-sized in CINZEL, it needs every pixel for its label.
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
  -- Bottom row: Save centred in the full width (never resized - a
  -- FancyButton's width is intrinsic).
  local btnY = ctx.height - LIST_BOTTOM_BUFFER
    + math.floor((LIST_BOTTOM_BUFFER - SAVE_H) / 2)
  pcall(function()
    col.saveBtn.root:SetPos(PAD + math.max(0,
      math.floor((ctx.width - PAD * 2 - (col.saveW or 0)) / 2)), btnY)
  end)
end

local function mount(ctx)
  col = { ctx = ctx, rows = {}, headers = {}, seps = {}, notice = {} }
  searchQuery = "" -- transient, like the window's: every mount starts clean
  -- The search field, Save row and the list frame live OUTSIDE the
  -- scrolling view, on the column layer itself.
  col.search = prettyui.TextField.new(ctx.parent, {
    categoryID = "auto",
    x = PAD, y = PAD, width = ctx.width - PAD * 2, height = SEARCH_H,
    maxLength = 25, placeholder = "Search...",
    -- Wider side margins: text starts after the decorative search icon on
    -- the left and scrolls before the clear icon on the right.
    contentMargin = ui.Margin.new(26, 3, 26, 0),
    onChange = function()
      -- Read GetText, never the callback's content arg, and compare to
      -- the last seen text so the focus-loss echo cannot trigger a
      -- pointless re-render.
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
  -- Decorative search icon in the field's left edge; purely visual.
  col.searchIcon = ui.Sprite.new(ctx.parent)
  col.searchIcon:SetSize(16, 16)
  col.searchIcon.spriteID = 25230
  col.searchIcon.clickthrough = true

  -- Clear icon inside the field's right edge; wipes the query in place.
  col.clear = uikit.AttachClearButton(ctx.parent, function()
    searchQuery = ""
    pcall(function() col.search:SetText("") end) -- no callback: hide by hand
    col.clear.SetVisible(false)
    scheduleRender()
  end)
  -- Save: a positive-variant FancyButton, label-fitted, centred by
  -- placeChrome.
  local saveAvail = ctx.width - PAD * 2 -- the whole bottom row is Save's
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
      pcall(window.SaveCurrentGear) -- plays its own confirm/refusal sounds
    end, { variant = "positive", categoryID = "auto" })
  -- spells out what a shortened label drops (the window's rule + wording)
  uikit.AttachDelayedTooltip(col.saveBtn.root,
    "Save your current gear and backpack as a new preset", ctx.parent)
  -- "+" creates a category and opens it straight into the inline rename.
  col.plusBtn = prettyui.SimpleButton.new(ctx.parent,
    prettyui.Sprites.SPRITE_BUTTONS.PLUS.neutral, function()
    local ok, err = pcall(function()
      local name = store.AddCategory()
      if name == nil then -- locked vault refuses, same chime as Save
        uikit.PlaySfx(uikit.BLOCKED_SFX)
        return
      end
      uikit.PlaySfx(uikit.CLICK_SFX)
      col.editingPreset = nil
      col.editingCat = name
      col.renameFor = nil
      window.Relayout() -- shared data: the standalone window follows along
    end)
    if not ok then
      log(formatStr("[PV Bankcore] column add category failed: {}", tostring(err)))
    end
    scheduleRender()
  end, { size = SIDE_BTN_W, iconSize = 14, categoryID = "auto" })
  -- Tooltips share uikit's one-tip-per-content system; the column's
  -- components live on Core's layer, so THAT is the tip's parent (same
  -- coordinate space - uikit's rule). The window's wording, verbatim.
  uikit.AttachDelayedTooltip(col.plusBtn.root, "New category", ctx.parent)
  -- Import keeps its WINDOW (the "Import category as well" checkbox lives
  -- there) - the one deliberate window in the integrated UI. Icon 29456,
  -- the same art as the standalone window's import button.
  col.impBtn = prettyui.SimpleButton.new(ctx.parent, 29456, function()
    pcall(window.OpenImport)
  end, { size = SIDE_BTN_W, iconSize = 16, categoryID = "auto" })
  uikit.AttachDelayedTooltip(col.impBtn.root,
    "Import share code", ctx.parent) -- terser than the window's wording:
    -- the column is a tighter space
  -- The border around the list section.
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
  -- The scrollbar keeps its STOCK art: now that rows stop short of the
  -- bar's lane rather than running beneath it, the track covers no content,
  -- so there is nothing to restyle around.
  local body = col.view.content
  for i = 1, window.NOTICE_LINES do
    local t = ui.Text.new(body)
    t:SetPos(0, 8 + (i - 1) * 19)
    t:SetSize(vw, 16)
    t.font = id.Font.MUSEO_SANS_15PT_REGULAR
    t.rgba = (i == 1) and 0xE0B050FF or 0xB8A169CC -- reason gold, hint muted
    t.alignHorizontal = ui.AlignMode.CENTRE
    t.clickthrough = true
    t.hidden = true
    col.notice[i] = t
  end
  -- Two-line empty hint: "No presets yet" / "Press Save Preset". Two Texts
  -- rather than one wrapped line, matching the lock-notice approach (the
  -- single line overran the narrow column).
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
  -- Inline rename for categories AND presets: one pooled field + OK pair,
  -- shown over the edited row by render.
  local function commitRename()
    if col == nil then return end
    local oldCat = col.editingCat
    local presetId = col.editingPreset
    col.editingCat = nil
    col.editingPreset = nil
    col.renameFor = nil
    if oldCat ~= nil then
      pcall(function()
        local newName = col.rename:GetText()
        if newName ~= nil and newName ~= "" and newName ~= oldCat then
          -- carry this session's collapse state (pvwin.lua's rule)
          window.SetCollapsed(newName, window.IsCollapsed(oldCat))
          store.RenameCategory(oldCat, newName)
        end
      end)
    elseif presetId ~= nil then
      pcall(function()
        local newName = col.rename:GetText()
        -- blank falls back to "Untitled" - the window's rename rule
        if newName == nil or newName == "" then newName = "Untitled" end
        store.Rename(presetId, newName)
      end)
    end
    scheduleRender()
    window.Relayout()
  end
  col.rename = prettyui.TextField.new(body, {
    x = 4, y = 0, width = vw - 70, height = 26,
    maxLength = 25, placeholder = "Name", -- dual duty: categories + presets
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
  -- Core destroys both layers, and everything in them, right after this -
  -- so every reference is dropped rather than cached.
  col = nil
  hoveredRow = nil
  hoveredHeader = nil
end

-- Handed to core/bankutil (main.lua wires it before Connect): core/ cannot
-- require ui/, so the column callbacks arrive by injection.
M.Provider = {
  mount = function(ctx)
    local ok, err = pcall(mount, ctx)
    if not ok then
      col = nil
      log(formatStr("[PV Bankcore] column mount failed: {}", tostring(err)))
      error(err, 0) -- let Core show its column error state
    end
  end,
  resize = function(ctx) pcall(resize, ctx) end,
  unmount = function() unmount() end,
}

return M
