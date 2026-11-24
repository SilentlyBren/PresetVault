-- The preset bank view, standalone engine: hides the native bank slots, draws
-- the preset over them, and parks the hovered item's real bank child under
-- its cell so the click, menu and tooltip stay the game's own.
local M = {}
local prefs = require("core/prefs")

local BASE = 517 * 65536 -- bank interface
local BANK_INV_STATIC = 201
local EMPTY_OBJ = 48447 -- associatedObjectID of an empty bank slot

-- grid siblings, so the canvas (a grid child) cannot cover them
local DECOR_STATICS = { 203, 204 }

local P = require("core/presetview")
local invread = require("core/invread")
local ORIGIN_X, TITLE_Y, ORIGIN_Y = P.ORIGIN_X, P.TITLE_Y, P.ORIGIN_Y
local GRID_W = P.GRID_W
local SLOT_BG_DX, SLOT_BG_DY = P.SLOT_BG_DX, P.SLOT_BG_DY
local BOX = P.BOX
local DOLL_CX, DOLL_Y = P.DOLL_CX, P.DOLL_Y
local WORN_BANK, WORN_CONNECTORS = P.WORN_BANK, P.WORN_CONNECTORS
local wornPos = P.WornPos

local DIVIDER_COLOUR, TITLE_COLOUR = P.DIVIDER_COLOUR, P.TITLE_COLOUR
local WHITE, GHOST_TINT, CONNECTOR_TINT = P.WHITE, P.GHOST_TINT, P.CONNECTOR_TINT
local PANEL_COLOUR = P.PANEL_COLOUR
local DIM_ALPHA = P.DIM_ALPHA
local MISS_RED, UNDER_ORANGE = P.MISS_RED, P.UNDER_ORANGE
local SHORTFALL_COLOUR = P.SHORTFALL_COLOUR

local canvas = nil
local cellPool = {}
local labelPool = {}
-- dynamicIDs of our own grid children; every grid walk must skip them
local ownDynIds = {}
local view = nil
local tickCount = 0
local forceRepairTicks = 0
local reclaimWatch = 0 -- ticks left of per-tick emptied-claim checks
M.activePresetId = nil
M.activePreset = nil
M.OnViewChanged = nil
local quiet = 0 -- above zero, view-changed notifications are held back

local function fireViewChanged()
  if quiet == 0 and M.OnViewChanged then pcall(M.OnViewChanged) end
end

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

-- English-only label match: another client language, or a failed read,
-- returns false.
local CANCEL_STATIC = 257
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
  local PERIOD = 46 -- ticks
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
M.FlashWrongTab = flashAllItemsTab

-- Unit counts come from inv 95, never associatedObjectQuantity, which may
-- hold our own badge override.
local function scanBank(grid)
  local pools = {}
  local emptyChildren = {}
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
  -- Stocked stacks order before placeholders, so poolIndex 1 is never an
  -- emptied stack while live ones exist. The quantity read above only
  -- orders the pool; a nil quantity counts as live.
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

local nameOf = uikit.ObjName

-- One child may serve several cells; a poolIndex past the pool means no child.
local function buildCells(preset, pools, counts, carried, exact, emptyChildren, layout)
  local bank = {}
  for obj, pool in pairs(pools) do
    bank[obj] = { stacks = #pool, units = counts[obj] or 0 }
  end
  local model = P.Build(preset, bank, carried, exact, nameOf, layout)
  for _, c in ipairs(model.cells) do
    if c.srcObj ~= nil and c.poolIndex ~= nil then
      local pool = pools[c.srcObj]
      if pool ~= nil then c.child = pool[c.poolIndex] end
    end
    -- a placeholder claimed at build; reclaimPass must skip these or it
    -- re-fires on every pass
    c.claimedEmpty = c.child ~= nil
      and (emptyChildren or {})[c.child] == true
    c.claimGone = c.claimedEmpty
    -- captured before anything parks or stamps the child, so these are
    -- the client's own values
    if c.child ~= nil then
      pcall(function()
        c.nx, c.ny = c.child.x, c.child.y
        c.origQty = c.child.associatedObjectQuantity
      end)
    end
  end
  return model
end

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
    -- the whole grid, so natives stay masked at any scroll position
    local gw, gh = v.chromeW, v.chromeH
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
    -- opaque: masks native art the client re-creates un-hidden after a
    -- withdrawal
    cv:AddRectangle(0, 0, gw, gh, PANEL_COLOUR)
    local function divider(x, y, w, text)
      cv:AddText(x - 2, y - 3, text, font, TITLE_COLOUR)
      cv:AddRectangle(x, y + 18, w, 1, DIVIDER_COLOUR)
    end
    cv:AddText(ORIGIN_X - 2, TITLE_Y - 3, tostring(v.preset.name or ""),
      font, TITLE_COLOUR)
    divider(ORIGIN_X, ORIGIN_Y, v.wornW, "Worn")
    divider(v.packX, v.packHeaderY, v.packW, "Backpack")
    if v.bobHeaderY ~= nil then
      divider(ORIGIN_X, v.bobHeaderY, GRID_W, "Beast of Burden")
    end
    local slotBg = prettyui.Sprites.ITEM_SLOT_BACKGROUND
    for _, c in ipairs(WORN_CONNECTORS) do
      cv:AddSprite(DOLL_CX + c[1], DOLL_Y + c[2], c[3], c[4], c[5], CONNECTOR_TINT)
    end
    for slotIdx, m in pairs(WORN_BANK) do
      local p = wornPos(slotIdx)
      cv:AddSprite(p.x + SLOT_BG_DX, p.y + SLOT_BG_DY, BOX, BOX, slotBg, WHITE)
      if not v.placedDoll[slotIdx] then
        cv:AddSprite(p.x, p.y, 32, 32, m[3], GHOST_TINT)
      end
    end
    for _, p in ipairs(v.emptyBg or {}) do
      cv:AddSprite(p.x, p.y, BOX, BOX, slotBg, WHITE)
    end
    for _, c in ipairs(v.cells) do
      local bx, by, bs = c.x + SLOT_BG_DX, c.y + SLOT_BG_DY, BOX
      if not c.doll then cv:AddSprite(bx, by, bs, bs, slotBg, WHITE) end
      if c.missing then
        cv:AddRectangle(bx, by, bs, bs, MISS_RED)
      elseif c.partial then
        cv:AddRectangle(bx, by, bs, bs, UNDER_ORANGE)
      end
    end
  end)
end

local hotIndex = nil
local rearmPending = false
-- declared ahead: the hover handlers below call these
local scanOps, cellRemaining, flagCell, applyCellDisplay, updateDisplays, refreshCounts

-- nil for a non-stacked cell: its child is never stamped and must never be
-- written, or an emptied stack's own 0 is overwritten.
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
      flagCell(c, false)
      -- handed back here as well as in Restore, or a rebuild captures our
      -- stamp as the child's own quantity
      local q = nativeQty(c)
      if q ~= nil then
        pcall(function()
          c.child.associatedObjectQuantity = q
          c.child.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.MULTIPLE
        end)
      end
      c.child.hidden = true
      pcall(function() c.sprite.clickthrough = false end)
      -- off the All Items tab these coords are stale and strand the item
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
  if c == nil or c.child == nil then return end
  unHot()
  hotIndex = i
  pcall(function()
    -- the child is parked visible but must stay behind the opaque canvas
    c.child:SetPos(c.x, c.y)
    c.child.hidden = false
    pcall(function() c.child:MoveToBack() end)
    c.sprite.clickthrough = true
    -- a click-through sprite gets no hover events, so the child owns the leave
    c.child:Subscribe(ui.Hook.ONMOUSELEAVE, "pvLeave", function()
      pcall(unHot)
    end)
    flagCell(c, true)
    applyCellDisplay(c)
    -- ONOP fires client-side at the click: book the amount and re-flag
    -- here, before the server answers, so a spam click sees fresh state
    c.child:Subscribe(ui.Hook.ONOP, "pvOp", function(_, opID)
      pcall(function()
        if view == nil or c.srcObj == nil then return end
        local map = scanOps(c)
        local amount = nil
        if map.all ~= nil and opID == map.all then
          amount = view.counts[c.srcObj] or 0
        elseif map.wear ~= nil and opID == map.wear then
          amount = 1
        else
          for _, st in ipairs(map.steps) do
            if st.idx == opID then amount = st.step break end
          end
        end
        if amount == nil or amount <= 0 then return end
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
    s.clickthrough = false
    s.hidden = true
    pcall(function() ownDynIds[s.dynamicID] = true end)
    -- pool index equals cell index for the session, so i stays this
    -- sprite's cell
    s:Subscribe(ui.Hook.ONMOUSEOVER, function()
      pcall(function() goHot(i) end)
    end)
  end)
  if not okC then return nil end
  cellPool[i] = s
  return s
end

scanOps = function(c)
  if c.opMap ~= nil then return c.opMap end
  c.opMap = P.BuildOpMap(uikit.ReadOps(c.child))
  return c.opMap
end

cellRemaining = function(c)
  if view == nil then return c.need end
  return P.CellRemaining(view, c, view.carried, view.pending)
end

-- Only the hovered cell is flagged: one child can serve two cells with
-- different needs.
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
    local want = P.ChooseOp(map, remaining, live,
      view ~= nil and view.equipObjs[c.obj] == true, c.stacked)
    -- a child with no withdraw or wear op is a placeholder, whose native
    -- default is Remove placeholder
    if want == nil and #map.steps == 0 and map.all == nil and map.wear == nil
      and map.examine ~= nil then want = map.examine end
    if want ~= c.opHigh then
      if c.opHigh ~= nil then oc:SetOpIDHighPriority(c.opHigh, false) end
      c.opHigh = want
    end
    -- set even when unchanged: a client re-layout can drop the flag
    if want ~= nil then oc:SetOpIDHighPriority(want, true) end
  end)
end

applyCellDisplay = function(c)
  local exactView = view ~= nil and view.exact == true
  local banked = (view ~= nil and c.srcObj ~= nil) and (view.claimQty[c.srcObj] or 0) or 0
  local rem, always, satisfied = P.Badge(c, cellRemaining(c), exactView, banked)
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
  -- Native press feedback shows through the canvas, so the parked child
  -- carries our badge. Stacked only: see nativeQty.
  if view ~= nil and hotIndex ~= nil and view.cells[hotIndex] == c
    and c.stacked then
    paint(c.child)
  end
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

refreshCounts = function()
  if view == nil then return end
  local fresh = invread.CountInv(95)
  P.ReconcilePending(view.pending, view.counts, fresh, tickCount)
  view.counts = fresh
  -- must be read in the same pass as the reconcile, or a unit counts twice
  view.carried = carriedCounts()
end

-- Swaps an emptied claim onto the next live stack of the same obj. Not a
-- rebuild: a rebuild re-claims the emptied child and drops the hover.
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
        -- == compare, never a table lookup: the walk hands back fresh userdata
        for _, c2 in ipairs(view.cells) do
          if c2.child == child then return end
        end
        replacement = child
      end)
    end)
  end)
  if replacement == nil then
    -- nothing live left: stop re-checking this claim
    c.claimedEmpty = true
    return
  end
  local wasHot = hotIndex == i
  if wasHot then unHot() end
  c.child = replacement
  c.opMap = nil
  c.claimedEmpty = false
  c.claimGone = false
  pcall(function()
    c.nx, c.ny = replacement.x, replacement.y
    c.origQty = replacement.associatedObjectQuantity
  end)
  if wasHot then
    -- an unreadable mouse or position errs toward re-parking
    local m, sg = nil, nil
    pcall(function() m = uikit.MousePos() end)
    pcall(function() sg = c.sprite.xyGlobal end)
    if m == nil or sg == nil
      or (m.x >= sg.x and m.x < sg.x + 36
        and m.y >= sg.y and m.y < sg.y + 32) then
      pcall(function() goHot(i) end)
    end
  end
end

-- Non-stacked cells only: their children are never stamped, so the quantity
-- read is the client's own.
local function reclaimPass(grid)
  for i, c in ipairs(view.cells) do
    if c.child ~= nil and c.srcObj ~= nil and not c.stacked then
      local q = nil
      pcall(function() q = c.child.associatedObjectQuantity end)
      local gone = q ~= nil and q <= 0
      c.claimGone = gone
      if gone and c.claimedEmpty ~= true
        and (view.counts[c.srcObj] or 0) > 0 and cellRemaining(c) > 0 then
        reclaimCell(i, c, grid)
      end
    end
  end
end

local SHORTFALL_FONT, SHORTFALL_FONT_H = uikit.SmallFont()

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

local sweepParkDyn = nil
local function hideChild(child)
  local dyn = child.dynamicID
  if ownDynIds[dyn] or dyn == sweepParkDyn then return end
  if child.hidden ~= true then
    child.hidden = true
    if view.hiddenSet[dyn] == nil then
      view.hiddenSet[dyn] = true
      view.hiddenChildren[#view.hiddenChildren + 1] = child
    end
  end
end
-- must return nothing: a true return from an iterate callback stops the walk
local function hideVisit(child)
  pcall(hideChild, child)
end

local function hideSweep(grid)
  if view == nil then return end
  sweepParkDyn = nil
  if hotIndex ~= nil and view.cells[hotIndex] ~= nil then
    pcall(function() sweepParkDyn = view.cells[hotIndex].child.dynamicID end)
  end
  grid:IterateDynamicComponents(hideVisit)
end

-- Slot ids shift when a withdrawal with placeholders off removes a slot.
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

-- Notifies the list only if the same preset did not come back.
local function rebuildView()
  local p = M.activePreset
  quiet = quiet + 1
  pcall(function()
    M.Restore()
    if p ~= nil then M.Show(p, true) end
  end)
  quiet = quiet - 1
  if M.activePresetId ~= (p ~= nil and p.id or nil) then fireViewChanged() end
end

-- Tick bodies passed through pcall's arguments so the tick allocates no
-- closures. One function per guarded step: merged, a failure in the first
-- would skip the second.
local function pinCanvas()
  canvas:SetPos(0, 0)
end
local function pinSprite(c)
  c.sprite:SetPos(c.x, c.y)
end
local function pinLabel(c)
  c.label.bg:SetPos(c.labelX, c.labelY)
  c.label.text:SetPos(c.labelX + 3, c.labelY + 1)
end
local function pinHot(c)
  c.child:SetPos(c.x, c.y)
  c.child.hidden = false
  c.child:MoveToBack()
  -- every tick: the client rewrites the quantity to the true bank total
  -- when a withdrawal lands
  if c.stacked and c.lastRem ~= nil then
    c.child.associatedObjectQuantity = c.lastRem
    c.child.associatedObjectQuantityMode = c.lastAlways
      and ui.ObjectQuantityDisplayMode.ALWAYS
      or ui.ObjectQuantityDisplayMode.MULTIPLE
  end
end
local function frontCanvas()
  canvas:MoveToFront()
end
local function frontSprite(c)
  c.sprite:MoveToFront()
end
local function frontLabel(c)
  c.label.bg:MoveToFront()
  c.label.text:MoveToFront()
end

local function tickBody()
  tickCount = tickCount + 1
  if view == nil then return end
  local grid = getGrid()
  if grid == nil then return end

  if rearmPending then
    rearmPending = false
    pcall(function()
      local m = uikit.MousePos()
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

  -- client re-layouts rewrite positions but leave hidden flags alone
  pcall(pinCanvas)
  for i, c in ipairs(view.cells) do
    if c.sprite ~= nil then pcall(pinSprite, c) end
    if c.label ~= nil then pcall(pinLabel, c) end
    if i == hotIndex and c.child ~= nil then pcall(pinHot, c) end
  end

  local structural = forceRepairTicks > 0 or tickCount % 25 == 0
  if forceRepairTicks > 0 then forceRepairTicks = forceRepairTicks - 1 end
  local watching = reclaimWatch > 0
  if watching then reclaimWatch = reclaimWatch - 1 end
  if not structural then
    -- the player's next click can beat the structural pass to an emptied claim
    if watching then reclaimPass(grid) end
    return
  end

  if not onAllItemsTab() then
    -- a deposit into another tab's placeholder makes the client switch tabs
    M.Restore()
    return
  end
  if nativeSearchActive() then
    M.Restore()
    return
  end
  if not claimsValid() then
    rebuildView()
    return
  end
  refreshCounts()

  -- a placeholder keeps its obj id, so claimsValid cannot see an emptied claim
  reclaimPass(grid)

  -- Only when the bank holds more of a short item than at build: a wider
  -- trigger rebuilds on every withdrawal.
  for _, c in ipairs(view.cells) do
    if c.missing or c.partial then
      local now = (view.counts[c.obj] or 0) + (view.counts[c.obj - 1] or 0)
      local atShow = (c.srcObj ~= nil) and (view.claimQty[c.srcObj] or 0) or 0
      if now > atShow then
        rebuildView()
        return
      end
    end
  end

  updateDisplays()
  if hotIndex ~= nil then flagCell(view.cells[hotIndex], true) end
  hideSweep(grid)
  -- children the client spawns after a withdrawal can land above the canvas
  pcall(frontCanvas)
  for _, c in ipairs(view.cells) do
    if c.sprite ~= nil then pcall(frontSprite, c) end
  end
  for _, c in ipairs(view.cells) do
    if c.label ~= nil then pcall(frontLabel, c) end
  end
end

local function onTick()
  pcall(tickBody)
end

M.Restore = function()
  if M.activePresetId == nil then return end
  pcall(function() Event.Logic.Unsubscribe("pvPageTick") end)
  pcall(function() Event.InventoryUpdated.Unsubscribe("pvInvUpd") end)
  unHot()
  if view ~= nil then
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
        flagCell(c, false)
        pcall(function()
          -- off the All Items tab these coords are stale and strand the item
          if c.nx ~= nil and onAllItemsTab() then c.child:SetPos(c.nx, c.ny) end
          local q = nativeQty(c)
          if q ~= nil then
            c.child.associatedObjectQuantity = q
            c.child.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.MULTIPLE
          end
          -- a child hidden by unHot may not be in hiddenChildren
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
  fireViewChanged()
end

M.Show = function(preset, isRebuild)
  local grid = getGrid()
  if grid == nil then
    log("[PV] bank not open")
    return false
  end
  -- grid children must not be created before the grid displays
  local displayed = nil
  pcall(function() displayed = grid.visibleGlobal end)
  if displayed ~= true then return false end
  if not onAllItemsTab() then
    flashAllItemsTab()
    return false
  end
  local hadView = M.activePresetId ~= nil
  quiet = quiet + 1
  pcall(M.Restore)
  quiet = quiet - 1

  local ok, err = pcall(function()
    local pools, counts, emptyChildren = scanBank(grid)
    local exact = prefs.GetBool("ui.exactLayout") == true
    local model = buildCells(preset, pools, counts, carriedCounts(), exact,
      emptyChildren, {
        beside = prefs.GetBool("ui.packStackOff") == true,
        tall = prefs.GetBool("ui.packTall") == true,
      })
    if not ensureCanvas(grid) then error("canvas build failed") end

    view = model
    view.carried = carriedCounts()
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
          s:SetSize(36, 32)
          s:SetAssociatedObject(c.obj)
          s.hidden = false
          s:MoveToFront()
        end)
        applyCellDisplay(c)
      end
    end
    for i = #cells + 1, #cellPool do
      pcall(function() cellPool[i].hidden = true end)
    end

    -- labels last: they must sit above the cell sprites
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
          -- the carried inventories too: a transfer or an equip swap changes
          -- satisfaction without touching the bank
          if iid == 95 or iid == 93 or iid == 94 or iid == 530 then
            -- repairs run on the tick: the client's re-layout lands after
            -- this event and would overwrite a repair made here
            forceRepairTicks = 3
            reclaimWatch = 15
          end
        end)
      end)
    end)
    -- ONMOUSEOVER fires on entry only, so the cell under a stationary
    -- pointer is re-armed by hand; next tick, because xyGlobal is still
    -- the pre-layout value here
    rearmPending = true
  end)
  if not ok then
    log(formatStr("[PV] bank view failed: {}", tostring(err)))
    M.Restore()
    -- Restore is silent once the view is already gone
    if hadView and M.activePresetId == nil then fireViewChanged() end
    return false
  end
  fireViewChanged()
  return true
end

-- Call after Restore. Needed on bank close (the client detaches plugin
-- children of bank components) and before handing the grid to Bank Core.
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
