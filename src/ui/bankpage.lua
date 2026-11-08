-- The preset bank view, standalone "panel model" engine.
--
-- While the bank is open on the All Items tab, every native bank slot is
-- HIDDEN and the preset is drawn in its place: pooled ui.Sprite cells over
-- canvas chrome (panel, titled dividers, worn doll, backdrops, tints).
--
-- Hovering a cell parks the one claimed bank child underneath it - visible
-- to the engine, but masked behind the opaque canvas - and opens a
-- click-through hole. The click, menu and tooltip are therefore all the
-- game's own. Nothing is ever moved en masse.
--
-- RULES THIS ENGINE LIVES BY:
--   * EVERY grid iteration must skip our own dynamicIDs (ownDynIds) - our
--     components are grid children too, and a sweep would hide our own rig.
--   * Only create grid children once the grid displays (visibleGlobal).
--   * The parked child must stay BEHIND the canvas (MoveToBack).
local M = {}

local BASE = 517 * 65536 -- bank interface
local BANK_INV_STATIC = 201 -- BANK__BANK_INV: the 1920-slot grid
local EMPTY_OBJ = 48447 -- associatedObjectID of empty bank slots

-- Decorative custom-tab titles and dividers (203 TAB_SEPARATORS, 204
-- TAB_DIVIDERS) are hidden while a view is active.
local DECOR_STATICS = { 203, 204 }

-- ---- layout / shared view maths ---------------------------------------------
-- Geometry, palette and the pure model all live in core/presetview. This
-- module keeps only what is component-bound: claiming children, parking,
-- hiding, repairs.
local P = require("core/presetview")
local invread = require("core/invread")
local ORIGIN_X, TITLE_Y, ORIGIN_Y = P.ORIGIN_X, P.TITLE_Y, P.ORIGIN_Y
local PACK_HEADER_Y = P.PACK_HEADER_Y
local GRID_W, CHROME_W = P.GRID_W, P.CHROME_W
local SLOT_BG_DX, SLOT_BG_DY = P.SLOT_BG_DX, P.SLOT_BG_DY
local BOX = P.BOX
local DOLL_CX, DOLL_Y = P.DOLL_CX, P.DOLL_Y
local WORN_BANK, WORN_CONNECTORS = P.WORN_BANK, P.WORN_CONNECTORS
local wornPos = P.WornPos

local DIVIDER_COLOUR, TITLE_COLOUR = P.DIVIDER_COLOUR, P.TITLE_COLOUR
local WHITE, GHOST_TINT, CONNECTOR_TINT = P.WHITE, P.GHOST_TINT, P.CONNECTOR_TINT
-- The panel is opaque on purpose, not decoration.
local PANEL_COLOUR = P.PANEL_COLOUR
local DIM_ALPHA = P.DIM_ALPHA
local MISS_RED, UNDER_ORANGE = P.MISS_RED, P.UNDER_ORANGE
local SHORTFALL_COLOUR = P.SHORTFALL_COLOUR

-- ---- state ------------------------------------------------------------------
local canvas = nil -- ONE ui.Canvas: dividers, titles, backdrops, ghosts, tints
local cellPool = {} -- pooled ui.Sprite cells, reused across views in a session
local labelPool = {} -- pooled ui.Text shortfall labels (must out-rank sprites)
local ownDynIds = {} -- dynamicIDs of OUR grid children (excluded from sweeps)
local view = nil -- active view state; nil = no page shown
local tickCount = 0
local forceRepairTicks = 0
local reclaimWatch = 0 -- post-event window where emptied claims are re-checked per tick
M.activePresetId = nil
M.activePreset = nil
M.OnViewChanged = nil -- pvwin.lua hook, fired after Show/Restore

local function getGrid()
  return ui.Interfaces:GetComponent(BASE + BANK_INV_STATIC)
end

local function bankOpen()
  local inv = Inventory.Find(95)
  return inv ~= nil and inv:GetSlots() ~= nil
end
M.IsBankOpen = bankOpen

local function onAllItemsTab()
  local hi = nil
  pcall(function()
    local v = var.VarPlayer["BANK_3"].value
    hi = (v & 0xFF000000) >> 24
  end)
  if hi == nil then return true end
  return hi == 0x88
end
-- The Core engine (ui/bupage) needs the same read: Core 1.1.0 misses
-- CLIENT-initiated tab switches (deposit into another tab's placeholder),
-- so our integrated view bails on this var exactly like the panel engine.
M.OnAllItemsTab = onAllItemsTab

-- True when a native bank search or filter is active. Both re-filter the
-- grid, so a live view's claims stop lining up with what is shown.
local CANCEL_STATIC = 257 -- BANK__BOTTOM_PANEL_CANCEL
local CANCEL_LABEL_CAT, CANCEL_LABEL_DYN = 0, 9
local function nativeSearchActive()
  local visible = false
  pcall(function()
    local c = ui.Interfaces:GetComponent(BASE + CANCEL_STATIC)
    visible = c ~= nil and c.hidden ~= true and c.visible == true
      and c.visibleGlobal ~= false
  end)
  if not visible then return false end
  local text = nil
  pcall(function()
    local label = ui.Interfaces:GetComponent(517, CANCEL_STATIC,
      CANCEL_LABEL_CAT, CANCEL_LABEL_DYN)
    if label ~= nil and label.hidden ~= true and label.visible == true
      and label.visibleGlobal ~= false then
      text = label.content
    end
  end)
  if type(text) ~= "string" then return false end
  text = text:gsub("<[^>]*>", ""):gsub("%s+", " ")
  text = (text:match("^%s*(.-)%s*$") or ""):lower()
  return text == "cancel search" or text == "clear filter"
end

local function setStaticsHidden(hidden)
  for _, sid in ipairs(DECOR_STATICS) do
    pcall(function()
      local c = ui.Interfaces:GetComponent(BASE + sid)
      if c ~= nil then c.hidden = hidden end
    end)
  end
end

local uikit = require("ui/uikit")
local playSfx = uikit.PlaySfx
local BLOCKED_SFX = uikit.BLOCKED_SFX

-- Pulses a glow on the All Items tab when a view is refused for wrong-tab.
local glowTicks = 0
local glowEdges = {}
local function clearGlow()
  for _, c in ipairs(glowEdges) do
    if c then pcall(function() c:Destroy() end) end
  end
  glowEdges = {}
  Event.Logic.Unsubscribe("pvGlow")
end

local function flashAllItemsTab()
  clearGlow()
  playSfx(BLOCKED_SFX)
  -- first candidate component with a real size wins
  local btn, cw, ch = nil, 0, 0
  for _, sid in ipairs({ 165, 166, 167, 168 }) do
    local c = ui.Interfaces:GetComponent(BASE + sid)
    if c then
      local w, h = 0, 0
      pcall(function() w = c.width; h = c.height end)
      if btn == nil and w and w > 0 and h and h > 0 then btn, cw, ch = c, w, h end
    end
  end
  if not btn then return end
  local T, INSET, SHRINK, TOP_NUDGE = 2, 1, 2, 1
  glowEdges = {}
  local ok = pcall(function()
    local x0, y0 = INSET, INSET - TOP_NUDGE
    local w, h = cw - INSET * 2, ch - INSET * 2 - SHRINK + TOP_NUDGE
    local rects = {
      { x0, y0, w, T }, { x0, y0 + h - T, w, T },
      { x0, y0, T, h }, { x0 + w - T, y0, T, h },
    }
    for _, r in ipairs(rects) do
      local rect = ui.Rectangle.new(btn)
      rect:SetPos(r[1], r[2]); rect:SetSize(r[3], r[4])
      rect.fill = true
      rect.colour = Vector4.new(1.0, 0.9, 0.4, 0.0)
      rect:MoveToFront()
      glowEdges[#glowEdges + 1] = rect
    end
  end)
  if not ok or #glowEdges == 0 then glowEdges = {} return end

  glowTicks = 0
  local PERIOD = 46 -- ticks per pulse; ~3 pulses then stop
  Event.Logic.Subscribe("pvGlow", function(event)
    glowTicks = glowTicks + 1
    local phase = (glowTicks % PERIOD) / PERIOD
    local wave = 0.5 - 0.5 * math.cos(phase * 2 * math.pi)
    local a = 0.25 + 0.75 * wave
    for _, rect in ipairs(glowEdges) do
      pcall(function() rect.colour = Vector4.new(1.0, 0.9, 0.4, a) end)
    end
    if glowTicks >= PERIOD * 3 then clearGlow() end
  end)
end
-- The BankUtil Core route (core/bankutil) refuses with "not_all_items"
-- and deserves the same chime + pulse as our own wrong-tab
-- refusal, so pvwin.lua needs to reach this.
M.FlashWrongTab = flashAllItemsTab

-- ---- claiming ---------------------------------------------------------------
-- Pools bank children by obj id, skipping our own components, and reads
-- true counts from inv 95.
local function scanBank(grid)
  local pools = {}
  local emptyChildren = {} -- child -> true where the client reports 0 units
  grid:IterateDynamicComponents(function(child, visible)
    pcall(function()
      if ownDynIds[child.dynamicID] then return end
      local assoc = child.associatedObjectID
      if assoc == nil or assoc == EMPTY_OBJ or assoc < 0 then return end
      if pools[assoc] == nil then pools[assoc] = {} end
      pools[assoc][#pools[assoc] + 1] = child
      local q = child.associatedObjectQuantity
      if q ~= nil and q <= 0 then emptyChildren[child] = true end
    end)
  end)
  -- Stocked stacks claim BEFORE placeholders (bank order kept within each
  -- group). Without this, a multi-stack unique - several rune pouches,
  -- say - breaks the moment one is withdrawn: its placeholder keeps the
  -- bank SLOT, so pure bank order hands poolIndex 1 (the compact merged
  -- cell's only claim) the empty Remove-placeholder child while real
  -- stacks of the same obj sit unclaimed behind it.
  for _, pool in pairs(pools) do
    if #pool > 1 then
      local live, empty = {}, {}
      for _, child in ipairs(pool) do
        if emptyChildren[child] then
          empty[#empty + 1] = child
        else
          live[#live + 1] = child
        end
      end
      if #empty > 0 and #live > 0 then
        for i, child in ipairs(live) do pool[i] = child end
        for i, child in ipairs(empty) do pool[#live + i] = child end
      end
    end
  end
  return pools, invread.CountInv(95), emptyChildren
end

local carriedCounts = invread.Carried

-- The name guard for noted-form resolution (noted = base + 1), injected
-- into the pure model so it stays free of game globals.
local nameOf = uikit.ObjName

-- Builds the model via core/presetview, then attaches the actual bank
-- children its claim order picked. A bank STACK is one child that may serve
-- two cells (Backpack + BoB); a unique item's cells each claim a DISTINCT
-- child in pool order, and a poolIndex past the pool means no child.
local function buildCells(preset, pools, counts, carried, exact, emptyChildren)
  -- the model's bank descriptor: per resolved obj, how many native stacks
  -- (children, placeholders included) and how many units (inv 95 truth)
  local bank = {}
  for obj, pool in pairs(pools) do
    bank[obj] = { stacks = #pool, units = counts[obj] or 0 }
  end
  local model = P.Build(preset, bank, carried, exact, nameOf)
  for _, c in ipairs(model.cells) do
    if c.srcObj ~= nil and c.poolIndex ~= nil then
      local pool = pools[c.srcObj]
      if pool ~= nil then c.child = pool[c.poolIndex] end
    end
    -- whether this claim took a placeholder at build time - the repair
    -- tick's emptied-claim trigger must only fire on claims that emptied
    -- AFTER the build (see scanBank)
    c.claimedEmpty = c.child ~= nil
      and (emptyChildren or {})[c.child] == true
    -- and empty claims absorb carried coverage first (P.CellRemaining)
    c.claimGone = c.claimedEmpty
    -- Native position and display quantity, captured BEFORE we ever park
    -- or relabel this child. Restore puts both back.
    if c.child ~= nil then
      pcall(function()
        c.nx, c.ny = c.child.x, c.child.y
        c.origQty = c.child.associatedObjectQuantity
      end)
    end
  end
  return model
end

-- ---- chrome (ONE canvas - primitives are budget-free) -----------------------
local function ensureCanvas(grid)
  if canvas ~= nil then return true end
  local ok = pcall(function()
    canvas = ui.Canvas.new(grid)
    canvas:SetPos(0, 0)
    pcall(function() ownDynIds[canvas.dynamicID] = true end)
    canvas.clickthrough = true
  end)
  if not ok then canvas = nil end
  return canvas ~= nil
end

local function drawChrome(v)
  if canvas == nil then return end
  pcall(function()
    local cv = canvas
    -- The backdrop spans the WHOLE grid component, not just the preset
    -- content box, so every native slot stays masked at any scroll
    -- position rather than leaving bare bank beside or below the view.
    local gw, gh = CHROME_W, v.chromeH
    pcall(function()
      local grid = getGrid()
      if grid ~= nil then
        gw = math.max(gw, grid.width or gw)
        gh = math.max(gh, grid.height or gh)
      end
    end)
    cv:SetSize(gw, gh)
    cv:Clear()
    local font = id.Font.CINZEL_13PT_BOLD
    -- first, so everything else on the canvas draws over it
    cv:AddRectangle(0, 0, gw, gh, PANEL_COLOUR)
    local function divider(y, text)
      cv:AddText(ORIGIN_X - 2, y - 3, text, font, TITLE_COLOUR)
      cv:AddRectangle(ORIGIN_X, y + 18, GRID_W, 1, DIVIDER_COLOUR)
    end
    -- page title: section-title text with no underline rule
    cv:AddText(ORIGIN_X - 2, TITLE_Y - 3, tostring(v.preset.name or ""),
      font, TITLE_COLOUR)
    divider(ORIGIN_Y, "Worn")
    divider(PACK_HEADER_Y, "Backpack")
    if v.bobHeaderY ~= nil then divider(v.bobHeaderY, "Beast of Burden") end
    local slotBg = prettyui.Sprites.ITEM_SLOT_BACKGROUND
    -- the game's connector lines first, so slot art covers their ends
    -- connector x is relative to the centre column's LEFT EDGE
    for _, c in ipairs(WORN_CONNECTORS) do
      cv:AddSprite(DOLL_CX + c[1], DOLL_Y + c[2], c[3], c[4], c[5], CONNECTOR_TINT)
    end
    -- doll slots: same backdrop + art geometry as every other cell
    for slotIdx, m in pairs(WORN_BANK) do
      local p = wornPos(slotIdx)
      cv:AddSprite(p.x + SLOT_BG_DX, p.y + SLOT_BG_DY, BOX, BOX, slotBg, WHITE)
      if not v.placedDoll[slotIdx] then
        cv:AddSprite(p.x, p.y, 32, 32, m[3], GHOST_TINT)
      end
    end
    -- exact layout: empty slots keep their backdrop, so a gap in the
    -- snapshot reads as a gap rather than the grid ending early
    for _, p in ipairs(v.emptyBg or {}) do
      cv:AddSprite(p.x, p.y, BOX, BOX, slotBg, WHITE)
    end
    -- cell backdrops + missing/partial tints + shortfall labels
    for _, c in ipairs(v.cells) do
      -- box geometry differs: native 36x36 doll slots vs the 40x40 compact
      -- grid cells (doll backdrops are drawn above, with the connectors)
      local bx, by, bs = c.x + SLOT_BG_DX, c.y + SLOT_BG_DY, BOX
      -- doll backdrops are drawn above (with the connectors); only the
      -- compact-grid cells need one here. Tints use the same box either way.
      if not c.doll then cv:AddSprite(bx, by, bs, bs, slotBg, WHITE) end
      if c.missing then
        cv:AddRectangle(bx, by, bs, bs, MISS_RED)
      elseif c.partial then
        cv:AddRectangle(bx, by, bs, bs, UNDER_ORANGE)
      end
      -- shortfall labels are NOT drawn here: canvas art sits below the cell
      -- sprites (so a parked child can render), which would bury the text
      -- under the item icon. They are pooled ui.Text components instead.
    end
  end)
end

-- ---- drawn cells (pooled sprites; a cell is its own hover armer) ------------
local hotIndex = nil
local rearmPending = false -- Show asks onTick to re-hover the cell under the pointer
-- Forward declarations: the hover handlers below call into the one-click
-- machinery, which is defined further down (a later `local function` is
-- invisible to an earlier closure - it would silently resolve to nil).
local scanOps, cellRemaining, flagCell, applyCellDisplay, updateDisplays, refreshCounts

-- The quantity a released child should display: the LIVE total for a bank
-- STACK, nothing at all otherwise.
local function nativeQty(c)
  if not c.stacked then return nil end
  if view ~= nil and c.srcObj ~= nil then
    local n = view.counts[c.srcObj]
    if n ~= nil then return n end
  end
  return c.origQty
end

local function unHot()
  if view == nil or hotIndex == nil then return end
  local c = view.cells[hotIndex]
  hotIndex = nil
  if c == nil then return end
  pcall(function()
    if c.child ~= nil then
      pcall(function() c.child:Unsubscribe(ui.Hook.ONMOUSELEAVE, "pvLeave") end)
      pcall(function() c.child:Unsubscribe(ui.Hook.ONOP, "pvOp") end)
      flagCell(c, false) -- leave no left-click override on a released item
      -- Hand the native quantity back HERE, not only at Restore.
      local q = nativeQty(c)
      if q ~= nil then
        pcall(function()
          c.child.associatedObjectQuantity = q
          c.child.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.MULTIPLE
        end)
      end
      c.child.hidden = true
      pcall(function() c.sprite.clickthrough = false end) -- cell takes hover again
      -- Park it back where the client had it - but ONLY while still on the
      -- All Items tab. Off-tab (a tab-switch bail), these coords are stale
      -- and the client is about to re-lay-out the grid anyway; writing them
      -- stranded the preset's items at the wrong spot until the next switch.
      if c.nx ~= nil and onAllItemsTab() then
        pcall(function() c.child:SetPos(c.nx, c.ny) end)
      end
    end
    if c.sprite ~= nil then c.sprite.hidden = false end
  end)
end

local function goHot(i)
  if view == nil or hotIndex == i then return end
  local c = view.cells[i]
  if c == nil or c.child == nil then return end -- missing cells stay inert
  unHot()
  hotIndex = i
  pcall(function()
    -- THE PANEL MODEL: the claimed bank child is parked under the cell
    -- VISIBLE but masked, behind the opaque canvas, so none of its native
    -- art shows. Our own sprite stays on screen throughout; the only thing
    -- hover changes is that the cell stops eating input, so the click falls
    -- through to the real item beneath.
    c.child:SetPos(c.x, c.y)
    c.child.hidden = false
    pcall(function() c.child:MoveToBack() end) -- stay under the canvas
    c.sprite.clickthrough = true -- open the hole over this cell only
    -- our sprite no longer takes input, so the CHILD owns the leave event
    c.child:Subscribe(ui.Hook.ONMOUSELEAVE, "pvLeave", function()
      pcall(unHot)
    end)
    -- This cell's own one-click default (the per-hover flag is what lets a
    -- shared stack serve two cells with different needs).
    flagCell(c, true)
    applyCellDisplay(c)
    -- ONOP fires client-side AT the click with the op index: book the step
    -- as pending and re-flag inside the same handler, so a spam-click always
    -- sees fresh state instead of racing the server.
    c.child:Subscribe(ui.Hook.ONOP, "pvOp", function(_, opID)
      pcall(function()
        if view == nil or c.srcObj == nil then return end
        local map = scanOps(c)
        local amount = nil
        if map.all ~= nil and opID == map.all then
          amount = view.counts[c.srcObj] or 0
        elseif map.wear ~= nil and opID == map.wear then
          -- a wear consumes one unit; book it so the NEXT click already
          -- sees the cell as satisfied (Examine) instead of wearing a
          -- second copy while the server catches up
          amount = 1
        else
          for _, st in ipairs(map.steps) do
            if st.idx == opID then amount = st.step break end
          end
        end
        if amount == nil or amount <= 0 then return end -- Examine/other
        -- directed at this cell's SECTION, so a BoB-cell withdraw dims the
        -- BoB cell instead of counting down the backpack's copy
        local p = view.pending[c.srcObj] or { amount = 0, bySect = {} }
        p.amount = (p.amount or 0) + amount
        p.bySect = p.bySect or {}
        p.bySect[c.section] = (p.bySect[c.section] or 0) + amount
        p.tick = tickCount
        view.pending[c.srcObj] = p
        updateDisplays()
        flagCell(c, true)
      end)
    end)
  end)
end

local function ensureCell(i)
  local s = cellPool[i]
  if s ~= nil then return s end
  local grid = getGrid()
  if grid == nil then return nil end
  local okC = pcall(function()
    s = ui.Sprite.new(grid)
    s:SetSize(36, 32)
    s.clickthrough = false -- the cell IS its hover armer
    s.hidden = true
    pcall(function() ownDynIds[s.dynamicID] = true end)
    -- pool index == cell index (Show assigns sequentially), so the closure's
    -- i is the cell this sprite represents for its whole life
    s:Subscribe(ui.Hook.ONMOUSEOVER, function()
      pcall(function() goHot(i) end)
    end)
  end)
  if not okC then return nil end
  cellPool[i] = s
  return s
end

-- ---- one-click ops ----------------------------------------------------------
-- A component's left-click default is its opConfig HIGH-PRIORITY op. Only
-- the HOVERED cell is ever flagged.
scanOps = function(c)
  if c.opMap ~= nil then return c.opMap end
  c.opMap = P.BuildOpMap(uikit.ReadOps(c.child))
  return c.opMap
end

-- How many units this cell still wants: a TOP-UP counter against live
-- inventory (backpack + worn + BoB). Supplies already carried when the view
-- opens count toward it, and deposits count back out.
--
-- Allocation and the maths are presetview's; unconfirmed clicks
-- (view.pending) count immediately, for the instant dim and re-flag.
cellRemaining = function(c)
  if view == nil then return c.need end
  return P.CellRemaining(view, c, view.carried, view.pending)
end

-- Sets, or clears, the hovered cell's left-click default:
--   equipment  -> Wear
--   stacked    -> largest Withdraw-N <= what this cell still needs;
--                 Withdraw-All when the need covers the live stack;
--                 Examine once satisfied, so a stray click cannot overshoot
flagCell = function(c, on)
  if c == nil or c.child == nil then return end
  pcall(function()
    local oc = c.child.opConfig
    if not on then
      if c.opHigh ~= nil then oc:SetOpIDHighPriority(c.opHigh, false) end
      c.opHigh = nil
      return
    end
    local map = scanOps(c)
    local remaining = cellRemaining(c)
    local live = (view ~= nil and c.srcObj ~= nil) and (view.counts[c.srcObj] or 0) or 0
    -- the decision ladder (Examine when satisfied / Wear / Withdraw steps /
    -- All) is the shared maths - see P.ChooseOp for the reasoning
    local want = P.ChooseOp(map, remaining, live,
      view ~= nil and view.equipObjs[c.obj] == true, c.stacked)
    -- A claimed child with NO withdrawable/wearable op has only the
    -- destructive "Remove placeholder" as its native default. Force Examine
    -- (the one safe op). Guarded on want==nil so real stacks (which have
    -- steps) and non-stacked singles are untouched.
    if want == nil and #map.steps == 0 and map.all == nil and map.wear == nil
      and map.examine ~= nil then want = map.examine end
    if want ~= c.opHigh then
      if c.opHigh ~= nil then oc:SetOpIDHighPriority(c.opHigh, false) end
      c.opHigh = want
    end
    if want ~= nil then oc:SetOpIDHighPriority(want, true) end -- re-assert
  end)
end

-- Badge for one cell: a stacked cell counts DOWN its remaining need and
-- shows even a "1" (it's a withdraw count); once satisfied the number goes
-- away entirely rather than rendering "0".
applyCellDisplay = function(c)
  local exactView = view ~= nil and view.exact == true
  -- cellRemaining covers every cell, claimable or not - its basis is the
  -- carried counts, which exist whether or not the bank holds the item.
  -- Badge rules are shared maths; see P.Badge.
  local banked = (view ~= nil and c.srcObj ~= nil) and (view.claimQty[c.srcObj] or 0) or 0
  local rem, always, satisfied = P.Badge(c, cellRemaining(c), exactView, banked)
  -- Remembered so the per-tick loop can re-stamp the parked child without
  -- recomputing.
  c.lastRem, c.lastAlways = rem, always
  local function paint(comp)
    if comp == nil then return end
    pcall(function()
      comp.associatedObjectQuantity = rem
      comp.associatedObjectQuantityMode = always
        and ui.ObjectQuantityDisplayMode.ALWAYS
        or ui.ObjectQuantityDisplayMode.MULTIPLE
    end)
  end
  paint(c.sprite)
  -- A parked STACKED child gets the same badge as the cell.
  if view ~= nil and hotIndex ~= nil and view.cells[hotIndex] == c
    and c.stacked then
    paint(c.child)
  end
  -- Satisfied cells dim like a native placeholder: the item is on the
  -- player now, so the cell is a reminder rather than a task.
  local done = satisfied
  if done ~= c.dimmed then
    c.dimmed = done
    pcall(function() c.sprite.alpha = done and DIM_ALPHA or 1.0 end)
  end
end

updateDisplays = function()
  if view == nil then return end
  for _, c in ipairs(view.cells) do applyCellDisplay(c) end
end

-- Re-reads live bank counts and settles pending click predictions against
-- them (a confirmed drop consumes its prediction; stale ones expire, e.g. a
-- click the server refused because the backpack was full).
refreshCounts = function()
  if view == nil then return end
  local fresh = invread.CountInv(95)
  P.ReconcilePending(view.pending, view.counts, fresh, tickCount)
  view.counts = fresh
  -- Read in the SAME pass as the pending reconciliation above.
  view.carried = carriedCounts()
end

-- Walks a cell's claim from a stack that has EMPTIED onto the next live
-- stack of the same obj, IN PLACE - no view rebuild. A hot cell re-parks
-- the new child under the stationary pointer via the normal unHot/goHot
-- pair, so one-click withdrawals chain across a multi-stack unique's
-- stacks (several rune pouches) without the pointer having to leave.
local function reclaimCell(i, c, grid)
  local replacement = nil
  pcall(function()
    grid:IterateDynamicComponents(function(child)
      if replacement ~= nil then return end
      pcall(function()
        if ownDynIds[child.dynamicID] then return end
        if child.associatedObjectID ~= c.srcObj then return end
        local q = child.associatedObjectQuantity
        if q == nil or q <= 0 then return end
        -- skip stacks other cells already claim. == compare, never a
        -- table lookup: the iterate hands back fresh userdata that
        -- raw-matches nothing, but __eq holds.
        for _, c2 in ipairs(view.cells) do
          if c2.child == child then return end
        end
        replacement = child
      end)
    end)
  end)
  if replacement == nil then
    -- nothing live left to walk to: stop re-checking this claim. A
    -- deposit that restocks the obj still rebuilds the view through the
    -- more-of-a-short-item trigger.
    c.claimedEmpty = true
    return
  end
  local wasHot = hotIndex == i
  if wasHot then unHot() end
  c.child = replacement
  c.opMap = nil -- the new child's op indices are its own
  c.claimedEmpty = false
  c.claimGone = false
  pcall(function()
    c.nx, c.ny = replacement.x, replacement.y
    c.origQty = replacement.associatedObjectQuantity
  end)
  if wasHot then
    -- re-park only while the pointer is still inside the cell; unreadable
    -- mouse or geometry errs toward re-parking (a wiggle recovers either
    -- way, and the sprite was never torn down so xyGlobal is settled)
    local m, sg = nil, nil
    pcall(function() m = Mouse.GetPosition() end)
    pcall(function() sg = c.sprite.xyGlobal end)
    if m == nil or sg == nil
      or (m.x >= sg.x and m.x < sg.x + 36
        and m.y >= sg.y and m.y < sg.y + 32) then
      pcall(function() goHot(i) end)
    end
  end
end

-- One sweep of the emptied-claim check (see reclaimCell). Cheap: a few
-- property reads per NON-STACKED claimed cell, nothing else.
local function reclaimPass(grid)
  for i, c in ipairs(view.cells) do
    if c.child ~= nil and c.srcObj ~= nil and not c.stacked then
      local q = nil
      pcall(function() q = c.child.associatedObjectQuantity end)
      local gone = q ~= nil and q <= 0
      -- satisfaction allocates to empty-claim cells FIRST (the dim must
      -- land on the cell that can no longer be withdrawn from, not on
      -- whichever cell is earliest) - see P.CellRemaining
      c.claimGone = gone
      if gone and c.claimedEmpty ~= true
        and (view.counts[c.srcObj] or 0) > 0 and cellRemaining(c) > 0 then
        reclaimCell(i, c, grid)
      end
    end
  end
end

-- Shortfall "-N" labels on missing and partial cells: real components,
-- pooled per bank session, kept ABOVE the cell sprites in z-order.
local SHORTFALL_FONT, SHORTFALL_FONT_H = uikit.SmallFont()

-- Label = a 50% black plate with the red count on top (red on item art alone
-- was hard to read). Both pooled; the plate must sit above the cell sprite
-- and below its own text.
local function ensureLabel(i)
  local e = labelPool[i]
  if e ~= nil then return e end
  local grid = getGrid()
  if grid == nil then return nil end
  e = {}
  local ok = pcall(function()
    e.bg = ui.Rectangle.new(grid)
    e.bg.fill = true
    e.bg.colour = Vector4.new(0, 0, 0, 0.65)
    e.bg.clickthrough = true
    e.bg.hidden = true
    pcall(function() ownDynIds[e.bg.dynamicID] = true end)
    e.text = ui.Text.new(grid)
    e.text:SetSize(38, SHORTFALL_FONT_H)
    e.text.clickthrough = true
    e.text.hidden = true
    pcall(function() e.text.font = SHORTFALL_FONT end)
    pcall(function() e.text.rgba = SHORTFALL_COLOUR end)
    pcall(function() e.text.alignHorizontal = ui.AlignMode.LEFT end)
    pcall(function() ownDynIds[e.text.dynamicID] = true end)
  end)
  if not ok then return nil end
  labelPool[i] = e
  return e
end

-- ---- native hiding ----------------------------------------------------------
-- Hides every native slot; only the hot cell's claimed child is ever
-- un-hidden. Re-run on every repair.
local function hideSweep(grid)
  if view == nil then return end
  local parkDyn = nil
  if hotIndex ~= nil and view.cells[hotIndex] ~= nil then
    pcall(function() parkDyn = view.cells[hotIndex].child.dynamicID end)
  end
  grid:IterateDynamicComponents(function(child, visible)
    pcall(function()
      local dyn = child.dynamicID
      if ownDynIds[dyn] or dyn == parkDyn then return end
      if child.hidden ~= true then
        child.hidden = true
        if view.hiddenSet[dyn] == nil then
          view.hiddenSet[dyn] = true
          view.hiddenChildren[#view.hiddenChildren + 1] = child
        end
      end
    end)
  end)
end

-- Claims must still point at the right items (slot ids shift when a stack
-- empties or a placeholder-off withdrawal removes its slot).
local function claimsValid()
  if view == nil then return true end
  for _, c in ipairs(view.cells) do
    if c.child ~= nil then
      local assoc = nil
      pcall(function() assoc = c.child.associatedObjectID end)
      if assoc ~= c.obj and assoc ~= c.obj - 1 then return false end
    end
  end
  return true
end

-- ---- lifecycle --------------------------------------------------------------
local function onTick(event)
  pcall(function()
    tickCount = tickCount + 1
    if view == nil then return end
    local grid = getGrid()
    if grid == nil then return end

    -- deferred hover re-arm (set by Show; see the comment there)
    if rearmPending then
      rearmPending = false
      pcall(function()
        local m = Mouse.GetPosition()
        if m == nil or hotIndex ~= nil then return end
        for i, c in ipairs(view.cells) do
          if c.child ~= nil and c.sprite ~= nil then
            local sg = c.sprite.xyGlobal
            if sg ~= nil and m.x >= sg.x and m.x < sg.x + 36
              and m.y >= sg.y and m.y < sg.y + 32 then
              goHot(i)
              break
            end
          end
        end
      end)
    end

    -- geometry re-assert: client re-layouts stomp positions but not hidden
    -- flags, so pinning our handful of components is the whole repair story
    pcall(function() canvas:SetPos(0, 0) end)
    for i, c in ipairs(view.cells) do
      if c.sprite ~= nil then
        pcall(function() c.sprite:SetPos(c.x, c.y) end)
      end
      if c.label ~= nil then
        pcall(function()
          c.label.bg:SetPos(c.labelX, c.labelY)
          c.label.text:SetPos(c.labelX + 3, c.labelY + 1)
        end)
      end
      if i == hotIndex and c.child ~= nil then
        pcall(function()
          c.child:SetPos(c.x, c.y)
          c.child.hidden = false
          c.child:MoveToBack() -- stay masked behind the canvas
          -- re-stamp each tick (STACKED cells only - uniques are never
          -- stamped, see nativeQty): the client rewrites the child's
          -- quantity to the true bank total when a withdrawal lands, and
          -- the press feedback would then flash that number
          if c.stacked and c.lastRem ~= nil then
            c.child.associatedObjectQuantity = c.lastRem
            c.child.associatedObjectQuantityMode = c.lastAlways
              and ui.ObjectQuantityDisplayMode.ALWAYS
              or ui.ObjectQuantityDisplayMode.MULTIPLE
          end
        end)
      end
    end

    local structural = forceRepairTicks > 0 or tickCount % 25 == 0
    if forceRepairTicks > 0 then forceRepairTicks = forceRepairTicks - 1 end
    local watching = reclaimWatch > 0
    if watching then reclaimWatch = reclaimWatch - 1 end
    if not structural then
      -- between structural passes, the post-event watch still re-checks
      -- emptied claims per tick: a fresh placeholder's quantity can take a
      -- few ticks to settle to 0, and the user's next click can beat the
      -- 25-tick pass to it
      if watching then reclaimPass(grid) end
      return
    end

    if not onAllItemsTab() then
      -- deposits into another tab's placeholder make the client switch tabs
      -- itself; a custom tab suppresses repositioned children, so bail out
      M.Restore()
      return
    end
    -- A native search/filter re-filters the grid under us; get out of the
    -- way rather than sit drawn with clicks misbehaving (same as the
    -- integrated engine). English-only detection, so it stays up otherwise.
    if nativeSearchActive() then
      M.Restore()
      return
    end
    if not claimsValid() then
      local p = M.activePreset
      M.Restore()
      if p ~= nil then M.Show(p, true) end
      return
    end
    -- settle predictions against server truth, then re-badge and re-assert
    -- the hovered cell's flag (a re-layout can drop op config)
    refreshCounts()

    -- Walk claims off stacks that have EMPTIED into placeholders while
    -- the bank still holds live stacks of the same obj (multi-stack
    -- uniques: several rune pouches, one withdrawn). The placeholder
    -- keeps its obj id, so claimsValid cannot see this - left alone, the
    -- cell sits on the empty child and its native default reads
    -- Remove-placeholder while real stacks go unclaimed. In-place swap,
    -- hover preserved - see reclaimCell/reclaimPass.
    reclaimPass(grid)

    -- Rebuild only when the bank now holds MORE of something a cell is
    -- short of.
    for _, c in ipairs(view.cells) do
      if c.missing or c.partial then
        local now = (view.counts[c.obj] or 0) + (view.counts[c.obj - 1] or 0)
        local atShow = (c.srcObj ~= nil) and (view.claimQty[c.srcObj] or 0) or 0
        if now > atShow then
          local p = M.activePreset
          M.Restore()
          if p ~= nil then M.Show(p, true) end
          return
        end
      end
    end

    updateDisplays()
    if hotIndex ~= nil then flagCell(view.cells[hotIndex], true) end
    hideSweep(grid)
    -- Re-assert the stack: children the client spawned after a withdrawal
    -- can land ABOVE our canvas, which would unmask native art. Canvas over
    -- natives, our cells and labels over the canvas.
    pcall(function() canvas:MoveToFront() end)
    for _, c in ipairs(view.cells) do
      if c.sprite ~= nil then pcall(function() c.sprite:MoveToFront() end) end
    end
    for _, c in ipairs(view.cells) do
      if c.label ~= nil then
        pcall(function()
          c.label.bg:MoveToFront()
          c.label.text:MoveToFront()
        end)
      end
    end
  end)
end

M.Restore = function()
  if M.activePresetId == nil then return end
  pcall(function() Event.Logic.Unsubscribe("pvPageTick") end)
  pcall(function() Event.InventoryUpdated.Unsubscribe("pvInvUpd") end)
  unHot()
  if view ~= nil then
    -- put the display back: un-hide every native we hid (confirmed restore
    -- path) and reset any quantity override on claimed children
    for _, child in ipairs(view.hiddenChildren) do
      pcall(function() child.hidden = false end)
    end
    for _, c in ipairs(view.cells) do
      if c.sprite ~= nil then pcall(function() c.sprite.hidden = true end) end
      if c.label ~= nil then
        pcall(function()
          c.label.bg.hidden = true
          c.label.text.hidden = true
        end)
      end
      if c.child ~= nil then
        flagCell(c, false) -- never leave a left-click override behind
        pcall(function()
          -- full hand-back: native quantity, native display mode, visible.
          -- (A child hidden by the hot/unhot cycle may not be in
          -- hiddenChildren, so un-hide here too.) Position is restored ONLY
          -- on the All Items tab - off-tab (tab-switch bail) the coords are
          -- stale and the client re-lays-out the grid itself; forcing them
          -- stranded the preset's items until the next manual tab switch.
          if c.nx ~= nil and onAllItemsTab() then c.child:SetPos(c.nx, c.ny) end
          -- quantity + mode hand-back is for STACKED claims only: uniques
          -- are never stamped, and writing anything onto one that emptied
          -- into a placeholder overwrites the client's own 0 (nativeQty)
          local q = nativeQty(c)
          if q ~= nil then
            c.child.associatedObjectQuantity = q
            c.child.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.MULTIPLE
          end
          c.child.hidden = false
        end)
      end
    end
  end
  pcall(function() canvas.hidden = true end)
  setStaticsHidden(false)
  view = nil
  hotIndex = nil
  rearmPending = false
  reclaimWatch = 0
  M.activePresetId = nil
  M.activePreset = nil
  if M.OnViewChanged then pcall(M.OnViewChanged) end
end

M.Show = function(preset, isRebuild)
  local grid = getGrid()
  if grid == nil then
    log("[PV] bank not open")
    return false
  end
  local displayed = nil
  pcall(function() displayed = grid.visibleGlobal end)
  if displayed ~= true then return false end
  if not onAllItemsTab() then
    flashAllItemsTab() -- point the user at the tab instead of failing silently
    return false
  end
  M.Restore()

  local ok, err = pcall(function()
    local pools, counts, emptyChildren = scanBank(grid)
    -- exact layout is read at build time, so a settings toggle only needs
    -- to Restore + Show to take effect
    local exact = PersistentDB:GetBool("ui.exactLayout") == true
    -- the shared model carries cells + geometry + the live-layer lookups
    -- (equipObjs, claimQty, liveCells); this engine adds its runtime state
    local model = buildCells(preset, pools, counts, carriedCounts(), exact,
      emptyChildren)
    if not ensureCanvas(grid) then error("canvas build failed") end

    view = model
    view.carried = carriedCounts() -- fresh read: the build consumed a copy
    view.counts = counts
    view.pending = {}
    view.hiddenChildren, view.hiddenSet = {}, {}
    local cells = view.cells

    pcall(function() canvas.hidden = false end)
    drawChrome(view)
    pcall(function() canvas:MoveToFront() end)

    for i, c in ipairs(cells) do
      local s = ensureCell(i)
      if s ~= nil then
        c.sprite = s
        pcall(function()
          s:SetPos(c.x, c.y)
          s:SetSize(36, 32) -- every cell, doll or grid, is the same size
          s:SetAssociatedObject(c.obj)
          s.hidden = false
          s:MoveToFront()
        end)
        -- badge (a bank-STACKED item shows even "1" - it's a withdraw count,
        -- which MULTIPLE would hide natively)
        applyCellDisplay(c)
      end
    end
    -- hide any leftover pooled cells from a larger previous view
    for i = #cells + 1, #cellPool do
      pcall(function() cellPool[i].hidden = true end)
    end

    -- shortfall labels last: they must sit above the cell sprites
    local labelIdx = 0
    for _, c in ipairs(cells) do
      if c.shortfall ~= nil and c.shortfall > 0 then
        labelIdx = labelIdx + 1
        local lab = ensureLabel(labelIdx)
        if lab ~= nil then
          c.label = lab
          local txt = "-" .. P.FormatCount(c.shortfall)
          local w = 22
          pcall(function()
            w = config.Font.FromID(SHORTFALL_FONT):GetStringWidth(txt, false) + 6
          end)
          -- bottom-left of the slot box, sized to the text
          c.labelX, c.labelY = c.x - 3, c.y + 20
          pcall(function()
            lab.bg:SetPos(c.labelX, c.labelY)
            lab.bg:SetSize(w, SHORTFALL_FONT_H + 2)
            lab.bg.hidden = false
            lab.bg:MoveToFront()
            lab.text.content = txt
            lab.text:SetPos(c.labelX + 3, c.labelY + 1)
            lab.text:SetSize(w, SHORTFALL_FONT_H)
            lab.text.hidden = false
            lab.text:MoveToFront()
          end)
        end
      end
    end
    for i = labelIdx + 1, #labelPool do
      pcall(function()
        labelPool[i].bg.hidden = true
        labelPool[i].text.hidden = true
      end)
    end

    hideSweep(grid)
    setStaticsHidden(true)
    M.activePresetId = preset.id
    M.activePreset = preset
    tickCount = 0
    Event.Logic.Subscribe("pvPageTick", onTick)
    pcall(function()
      Event.InventoryUpdated.Subscribe("pvInvUpd", function(ev)
        pcall(function()
          if ev.inv == nil then return end
          local iid = ev.inv.id
          -- Bank (95) and all three carried inventories: satisfaction is
          -- measured against what the player holds, so a transfer or an
          -- equip swap has to trigger a repair as well.
          if iid == 95 or iid == 93 or iid == 94 or iid == 530 then
            forceRepairTicks = 3
            -- a withdrawal's fresh placeholder can take a few ticks to
            -- read 0; keep re-checking emptied claims through the window
            reclaimWatch = 15
          end
        end)
      end)
    end)
    -- Re-arm the cell already under the pointer, ONE TICK from now.
    -- ONMOUSEOVER only fires on ENTRY, and the emptied-claim re-claim path
    -- rebuilds the view under a STATIONARY cursor mid-withdraw - without
    -- this, the next click lands on the un-hot cell sprite and does
    -- nothing until the pointer moves away and back.
    rearmPending = true
  end)
  if not ok then
    log(formatStr("[PV] bank view failed: {}", tostring(err)))
    M.Restore()
    return false
  end
  if M.OnViewChanged then pcall(M.OnViewChanged) end
  return true
end

-- Drops the canvas and cell pool. Called by main.lua on the open->closed
-- transition, after Restore.
M.DestroyChrome = function()
  clearGlow()
  for _, s in ipairs(cellPool) do
    pcall(function() s:Destroy() end)
  end
  cellPool = {}
  for _, e in ipairs(labelPool) do
    pcall(function() e.bg:Destroy() end)
    pcall(function() e.text:Destroy() end)
  end
  labelPool = {}
  pcall(function() canvas:Destroy() end)
  canvas = nil
  ownDynIds = {}
end

return M
