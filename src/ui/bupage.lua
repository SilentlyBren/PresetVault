-- The BankUtil Core bank-view engine: draws the preset into Core's custom
-- view, as a STATELESS rebuild of the shared model (core/presetview).
--
-- Core destroys and redraws the entire drawing on every bank item change,
-- and handles what the standalone engine has to fight for: masking the
-- natives, moving the real bank stack under whichever bound cell the
-- pointer hovers, and repairing its own layout. Only three pieces of live
-- machinery survive between redraws, because Core cannot do them for us:
--   * the top-up satisfaction refresh - badges and dims mutated in place
--   * the one-click left-click default, flagged via opConfig on the stack
--     Core has parked under a cell
--   * pending-click accounting from Event.MiniMenuEntrySelected
--
-- main.lua injects { draw = M.Draw, stop = M.Stop } into
-- bankutil.SetViewProvider. M.Stop runs whenever the view stops being ours.
local M = {}

local P = require("core/presetview")
local invread = require("core/invread")
local uikit = require("ui/uikit")
local bankpage = require("ui/bankpage") -- OnAllItemsTab (the shared tab read)
local bankutil = require("core/bankutil")

local BANK_INV_STATIC = 201 -- the 1920-slot grid: where Core's moved stacks live

local SHORTFALL_FONT, SHORTFALL_FONT_H = uikit.SmallFont()

-- ---- module state (survives redraws; a drawing's components do not) ----------
local drawing = nil -- { model, bySrc } for the CURRENT Core drawing
local counts = {} -- inv 95 totals, refreshed by the live layer
local carried = {} -- inv 93 + 94 + 530 totals
-- Unconfirmed clicks: srcObj -> { amount, tick, snap, bySect }, where `snap`
-- is the snapshot obj served (it differs from the key for noted items) and
-- `bySect` splits the amount across the sections clicked.
local pending = {}
local tickCount = 0
local forceTicks = 0
local running = false
-- The opConfig flags we own right now: child -> { op, map, cell }.
local flags = {}
-- The last child-and-cell pairing a flag served, kept briefly after the
-- flag dies so a MENU pick (whose pointer is on the menu, not the cell)
-- can still direct its pending booking at the right section.
local recent = nil -- { child, cell, tick }
local RECENT_TTL = 150 -- ticks (~3s): longer than any realistic menu dwell
-- Per-unit cells the player has withdrawn FROM, per srcObj, keyed by each
-- cell's ordinal within its group (stable across redraws): the next
-- binding puts the placeholders under exactly these cells, so the cell
-- the player clicked is the one that dims. Survives redraws and view
-- toggles; cleared when the preset changes.
local consumed = {} -- srcObj -> { list = {ord..}, set = {[ord]=true} }
local lastPresetId = nil

local nameOf = uikit.ObjName

local carriedCounts = invread.Carried

-- Bank read for the model: per obj, native stack count + total units.
-- Core's GetBankItems first, inv 95 slots as the fallback.
local function readBank()
  local bank, totals = {}, {}
  local function add(obj, q)
    if obj == nil or obj < 0 then return end
    local b = bank[obj]
    if b == nil then
      b = { stacks = 0, units = 0 }
      bank[obj] = b
    end
    b.stacks = b.stacks + 1
    b.units = b.units + q
    totals[obj] = (totals[obj] or 0) + q
  end
  local items = bankutil.GetBankItems()
  if items ~= nil then
    for _, it in ipairs(items) do
      pcall(function() add(it.objectID, tonumber(it.quantity) or 0) end)
    end
    return bank, totals
  end
  for _, h in pairs(invread.Slots(95)) do
    add(h.obj, h.count or 0)
  end
  return bank, totals
end

-- ---- one-click flags ----------------------------------------------------------
local function unflagChild(child, entry)
  pcall(function()
    if entry.op ~= nil then
      child.opConfig:SetOpIDHighPriority(entry.op, false)
    end
  end)
  -- Hand the native quantity back: the LIVE bank total for a single-stack
  -- obj, the park-time reading otherwise. Skipped if we never stamped.
  if (entry.origQty or 0) >= 1 then
    pcall(function()
      local q = entry.origQty
      local c = entry.cell
      if c ~= nil and c.stacked and c.srcObj ~= nil
        and counts[c.srcObj] ~= nil then
        q = counts[c.srcObj]
      end
      child.associatedObjectQuantity = q
      child.associatedObjectQuantityMode = entry.origMode
        or ui.ObjectQuantityDisplayMode.MULTIPLE
    end)
  end
end

local function unflagAll()
  for child, entry in pairs(flags) do unflagChild(child, entry) end
  flags = {}
end

local function scanOps(child)
  return P.BuildOpMap(uikit.ReadOps(child))
end

local function cellRemaining(c)
  if drawing == nil then return c.need end
  return P.CellRemaining(drawing.model, c, carried, pending)
end

-- Finds the stack Core has parked under our hovered cell and keeps its
-- left-click default flagged to that cell's current need. A grid child is
-- parked at a cell when its object id resolves to that cell, its
-- on-screen position overlaps the cell's sprite, AND the pointer is
-- inside the cell - Core only ever parks under the pointer, so a match
-- without the pointer is a home-position coincidence, never a park.
-- How far a grid child's on-screen position may sit from a cell's sprite
-- and still count as parked there.
local PARK_TOLERANCE = 8
local function stepFlags()
  local model = drawing and drawing.model
  if model == nil then return end
  -- EXACT layout: get out of Core's way and let it own input natively.
  if model.exact then
    unflagAll()
    return
  end
  local grid = uikit.BankComponent(BANK_INV_STATIC)
  if grid == nil then
    unflagAll()
    return
  end
  -- No pointer reading means no way to tell a park from a coincidence:
  -- hold no flags at all (native defaults still work) rather than risk one.
  local mouse = nil
  pcall(function() mouse = Mouse.GetPosition() end)
  if mouse == nil then
    unflagAll()
    return
  end
  local seen = {}
  pcall(function()
    grid:IterateDynamicComponents(function(child)
      pcall(function()
        local assoc = child.associatedObjectID
        local cellsFor = drawing.bySrc[assoc]
        if cellsFor == nil or child.hidden == true then return end
        local cg = child.xyGlobal
        if cg == nil then return end
        for _, c in ipairs(cellsFor) do
          if c.sprite ~= nil then
            local sg = nil
            pcall(function() sg = c.sprite.xyGlobal end)
            -- cell sprites are 36x32; the pointer must be inside the cell
            -- (with the park slack) for the child to count as parked there
            if sg ~= nil
              and mouse.x >= sg.x - PARK_TOLERANCE
              and mouse.x < sg.x + 36 + PARK_TOLERANCE
              and mouse.y >= sg.y - PARK_TOLERANCE
              and mouse.y < sg.y + 32 + PARK_TOLERANCE
              and math.abs(cg.x - sg.x) <= PARK_TOLERANCE
              and math.abs(cg.y - sg.y) <= PARK_TOLERANCE then
              seen[child] = c
              break
            end
          end
        end
      end)
    end)
  end)
  -- release flags on children no longer parked
  for child, entry in pairs(flags) do
    if seen[child] == nil then
      unflagChild(child, entry)
      flags[child] = nil
    end
  end
  -- flag (or re-choose and re-assert) the parked ones; re-assert matters -
  -- client re-layouts can drop op config, and a mutation costs nothing
  for child, c in pairs(seen) do
    recent = { child = child, cell = c, tick = tickCount }
    local entry = flags[child]
    if entry == nil then
      entry = { map = scanOps(child), cell = c }
      -- the native quantity, captured BEFORE the badge stamp below ever
      -- touches this child - unflagChild hands it back
      pcall(function()
        entry.origQty = child.associatedObjectQuantity
        entry.origMode = child.associatedObjectQuantityMode
      end)
      flags[child] = entry
    elseif entry.cell ~= c then
      entry.cell = c
    end
    -- An inventory event can swap the parked child's op list IN PLACE (a
    -- unique emptying into a placeholder while hovered - Core's light
    -- hover path keeps the park); re-scan during the post-event window so
    -- the cached map cannot flag a withdraw index against placeholder ops.
    if forceTicks > 0 then entry.map = scanOps(child) end
    local live = (c.srcObj ~= nil) and (counts[c.srcObj] or 0) or 0
    local want = P.ChooseOp(entry.map, cellRemaining(c), live,
      model.equipObjs[c.obj] == true, c.stacked)
    -- This engine NEVER flags Examine. Core redraws and re-parks through
    -- every withdrawal, so a flag that changed across those transitions
    -- would churn the left-click label before settling. Native defaults
    -- rule here; satisfied cells rely on the dim and the player.
    if want ~= nil and want == entry.map.examine then want = nil end
    pcall(function()
      local oc = child.opConfig
      if want ~= entry.op and entry.op ~= nil then
        oc:SetOpIDHighPriority(entry.op, false)
      end
      entry.op = want
      if want ~= nil then oc:SetOpIDHighPriority(want, true) end
    end)
    -- While parked, the child carries OUR badge rather than its true
    -- quantity, re-stamped per tick. Two safety rules: never stamp a
    -- placeholder (origQty < 1), and never stamp below 1.
    if (entry.origQty or 0) >= 1 then
      pcall(function()
        local qty, always = c.lastRem, c.lastAlways == true
        if qty == nil or qty < 1 then
          qty, always = 1, false -- 1 + MULTIPLE renders no number at all
        end
        child.associatedObjectQuantity = qty
        child.associatedObjectQuantityMode = always
          and ui.ObjectQuantityDisplayMode.ALWAYS
          or ui.ObjectQuantityDisplayMode.MULTIPLE
      end)
    end
  end
end

-- ---- display ------------------------------------------------------------------
-- Badge and dim for one cell, mutated in place on OUR sprite.
local function applyCellDisplay(c)
  if c.sprite == nil or drawing == nil then return end
  local banked = (c.srcObj ~= nil) and (drawing.model.claimQty[c.srcObj] or 0) or 0
  local rem, always, satisfied =
    P.Badge(c, cellRemaining(c), drawing.model.exact, banked)
  -- remembered so stepFlags can stamp the parked child with the same badge
  c.lastRem, c.lastAlways = rem, always
  pcall(function()
    c.sprite.associatedObjectQuantity = rem
    c.sprite.associatedObjectQuantityMode = always
      and ui.ObjectQuantityDisplayMode.ALWAYS
      or ui.ObjectQuantityDisplayMode.MULTIPLE
  end)
  if satisfied ~= c.dimmed then
    c.dimmed = satisfied
    pcall(function() c.sprite.alpha = satisfied and P.DIM_ALPHA or 1.0 end)
  end
end

-- Marks cells whose Core backing must be a PLACEHOLDER, so satisfaction
-- dims them first (P.CellRemaining's claimGone ordering).
local function markClaimGone()
  if drawing == nil then return end
  local groups = {}
  local occ = {}
  for _, c in ipairs(drawing.model.cells) do
    if c.srcObj ~= nil and not c.stacked then
      if c.perUnit then
        if groups[c.srcObj] == nil then groups[c.srcObj] = {} end
        local g = groups[c.srcObj]
        g[#g + 1] = c
      else
        -- plain non-stacked cells: model order, gone past the unit count
        occ[c.srcObj] = (occ[c.srcObj] or 0) + 1
        c.claimGone = occ[c.srcObj] > (counts[c.srcObj] or 0)
      end
    end
  end
  for srcObj, g in pairs(groups) do
    local pend = 0
    local p = pending[srcObj]
    if p ~= nil then pend = p.amount or 0 end
    local eff = (counts[srcObj] or 0) - pend
    if eff < 0 then eff = 0 end
    local ph = #g - eff
    if ph < 0 then ph = 0 end
    local marks = consumed[srcObj]
    if marks ~= nil then
      while #marks.list > ph do
        local ord = table.remove(marks.list)
        marks.set[ord] = nil
      end
    end
    local set = (marks ~= nil) and marks.set or {}
    local extra = ph - ((marks ~= nil) and #marks.list or 0)
    for i = #g, 1, -1 do
      local c = g[i]
      if set[c.unitOrd] then
        c.claimGone = true
      elseif extra > 0 then
        c.claimGone = true
        extra = extra - 1
      else
        c.claimGone = false
      end
    end
  end
end

local function updateDisplays()
  if drawing == nil then return end
  markClaimGone()
  for _, c in ipairs(drawing.model.cells) do applyCellDisplay(c) end
end

-- ---- live layer ---------------------------------------------------------------
-- Pending reconciles on the ARRIVAL side here, unlike the panel engine's
-- bank-drop side. Old-vs-fresh carried is compared in the SAME pass that
-- stores the fresh table.
local function refreshCounts()
  local freshCarried = carriedCounts()
  P.ReconcileArrivals(pending, carried, freshCarried, tickCount)
  carried = freshCarried
  counts = invread.CountInv(95)
end

local function onTick()
  pcall(function()
    tickCount = tickCount + 1
    if drawing == nil then return end
    local structural = forceTicks > 0 or tickCount % 25 == 0
    if forceTicks > 0 then forceTicks = forceTicks - 1 end
    if structural then
      if bankutil.ActivePresetId() == nil then
        M.Stop()
        return
      end
      -- Close our view the moment the All Items tab is gone, exactly as
      -- the panel engine does. Prefer Core's own tab reading, falling back
      -- to our BANK_3 heuristic when Core cannot answer.
      local viewAll = bankutil.NativeViewAll()
      if viewAll == nil then viewAll = bankpage.OnAllItemsTab() end
      if not viewAll then
        pcall(bankutil.Hide)
        return
      end
      -- Close the view when the player starts a native search or filter.
      if bankutil.NativeSearchActive() then
        pcall(bankutil.Hide)
        return
      end
      refreshCounts()
      updateDisplays()
    end
    stepFlags()
  end)
end

local function stop()
  if not running then return end
  running = false
  pcall(function() Event.Logic.Unsubscribe("pvBuTick") end)
  pcall(function() Event.MiniMenuEntrySelected.Unsubscribe("pvBuMenu") end)
  pcall(function() Event.InventoryUpdated.Unsubscribe("pvBuInv") end)
end

-- Books a click the moment the client dispatches it: the amount lands in
-- `pending`, displays re-dim, and the flagged op re-chooses inside the same
-- handler. Covers left clicks AND menu picks.
local function onMenuSelected(event)
  pcall(function()
    if drawing == nil then return end
    local e = event.entry
    local verb = tostring(e.verbText or ""):gsub("<[^>]->", "")
    local cd = e.componentData
    local obj = nil
    pcall(function() obj = cd and cd.objConfig and cd.objConfig.id end)
    if obj == nil then return end
    local cellsFor = drawing.bySrc[obj]
    if cellsFor == nil then return end
    -- Only clicks on the bank's own components book a prediction.
    local inBank = false
    pcall(function()
      local cur, depth = cd.component, 0
      while cur ~= nil and depth < 32 do
        if cur.interfaceID == 517 then
          inBank = true
          break
        end
        cur = cur.parent
        depth = depth + 1
      end
    end)
    if not inBank then return end
    local amount = nil
    local sect = "backpack" -- where a withdraw lands unless we know better
    local step = verb:match("^Withdraw%-(%d+)$")
    if step ~= nil then
      amount = tonumber(step)
    elseif verb == "Withdraw-All" then
      amount = counts[obj] or 0
    elseif verb:find("Wear") or verb:find("Wield") or verb:find("Equip") then
      amount = 1 -- a wear consumes one unit; the NEXT click must already
      -- see the cell satisfied (Examine), not wear a second copy
      sect = "equipment"
    end
    if amount == nil or amount <= 0 then return end -- Examine/other
    -- The clicked stack is the parked child we flagged, matched with ==,
    -- and its CELL's section directs the prediction.
    local cellHit = nil
    pcall(function()
      local clicked = cd.component
      if clicked == nil then return end
      for child, entry in pairs(flags) do
        if child == clicked and entry.cell ~= nil then
          sect = entry.cell.section or sect
          cellHit = entry.cell
          return
        end
      end
      -- A MENU pick lands with the pointer on the menu, so the
      -- pointer-gated flag is usually gone by then; the remembered
      -- last-parked pairing directs it instead.
      if recent ~= nil and recent.child == clicked
        and (tickCount - (recent.tick or 0)) <= RECENT_TTL
        and recent.cell ~= nil then
        sect = recent.cell.section or sect
        cellHit = recent.cell
      end
    end)
    -- A fast move-and-click can land BEFORE the tick that would have
    -- flagged the parked pairing (the known <=1-tick gap), leaving both
    -- lookups empty - resolve the cell by POSITION instead: the clicked
    -- component sits parked AT its cell.
    if cellHit == nil then
      pcall(function()
        local clicked = cd.component
        local cg = clicked and clicked.xyGlobal or nil
        if cg == nil then return end
        for _, c2 in ipairs(cellsFor) do
          if c2.sprite ~= nil then
            local sg = nil
            pcall(function() sg = c2.sprite.xyGlobal end)
            if sg ~= nil and math.abs(cg.x - sg.x) <= PARK_TOLERANCE
              and math.abs(cg.y - sg.y) <= PARK_TOLERANCE then
              cellHit = c2
              sect = c2.section or sect
              break
            end
          end
        end
      end)
    end
    -- Clicked-cell dims: remember which per-unit cell this withdrawal
    -- came from, so the next binding parks the placeholder under IT
    -- (Draw binds consumed ordinals last; markClaimGone dims them).
    if cellHit ~= nil and cellHit.perUnit and cellHit.unitOrd ~= nil
      and cellHit.srcObj ~= nil then
      local marks = consumed[cellHit.srcObj]
      if marks == nil then
        marks = { list = {}, set = {} }
        consumed[cellHit.srcObj] = marks
      end
      if not marks.set[cellHit.unitOrd] then
        marks.set[cellHit.unitOrd] = true
        marks.list[#marks.list + 1] = cellHit.unitOrd
      end
    end
    -- `snap` is the snapshot obj this prediction serves, which differs
    -- from the bank stack's obj for noted items. FoldPending and the
    -- arrival reconcile both key on it.
    local p = pending[obj] or { amount = 0, snap = cellsFor[1].obj, bySect = {} }
    p.amount = (p.amount or 0) + amount
    p.bySect = p.bySect or {}
    p.bySect[sect] = (p.bySect[sect] or 0) + amount
    p.tick = tickCount
    pending[obj] = p
    updateDisplays()
    stepFlags()
  end)
end

local function start()
  if running then return end
  running = true
  tickCount = 0
  forceTicks = 0
  Event.Logic.Subscribe("pvBuTick", onTick)
  pcall(function()
    Event.MiniMenuEntrySelected.Subscribe("pvBuMenu", onMenuSelected)
  end)
  pcall(function()
    Event.InventoryUpdated.Subscribe("pvBuInv", function(ev)
      pcall(function()
        if ev.inv == nil then return end
        local iid = ev.inv.id
        -- carried counts (93/94/530) change without touching the bank on
        -- equip swaps and BoB transfers; 95 covers withdraw/deposit
        if iid == 95 or iid == 93 or iid == 94 or iid == 530 then
          forceTicks = 3
        end
      end)
    end)
  end)
end

-- ---- chrome -------------------------------------------------------------------
-- One canvas below the cell sprites: title, dividers, doll connectors and
-- ghosts, slot backdrops, missing and partial tints.
local function drawChrome(cv, model, view)
  local w = math.max(P.CHROME_W, view.width or P.CHROME_W)
  local h = math.max(model.chromeH, view.height or 0)
  cv:SetSize(w, h)
  local font = id.Font.CINZEL_13PT_BOLD
  local function divider(y, text)
    cv:AddText(P.ORIGIN_X - 2, y - 3, text, font, P.TITLE_COLOUR)
    cv:AddRectangle(P.ORIGIN_X, y + 18, P.GRID_W, 1, P.DIVIDER_COLOUR)
  end
  -- page title: section-title text with no underline rule
  cv:AddText(P.ORIGIN_X - 2, P.TITLE_Y - 3, tostring(model.preset.name or ""),
    font, P.TITLE_COLOUR)
  divider(P.ORIGIN_Y, "Worn")
  divider(P.PACK_HEADER_Y, "Backpack")
  if model.bobHeaderY ~= nil then divider(model.bobHeaderY, "Beast of Burden") end
  local slotBg = prettyui.Sprites.ITEM_SLOT_BACKGROUND
  -- the game's connector lines first, so slot art covers their ends
  for _, c in ipairs(P.WORN_CONNECTORS) do
    cv:AddSprite(P.DOLL_CX + c[1], P.DOLL_Y + c[2], c[3], c[4], c[5],
      P.CONNECTOR_TINT)
  end
  -- doll slots: same backdrop + art geometry as every other cell
  for slotIdx, m in pairs(P.WORN_BANK) do
    local p = P.WornPos(slotIdx)
    cv:AddSprite(p.x + P.SLOT_BG_DX, p.y + P.SLOT_BG_DY, P.BOX, P.BOX,
      slotBg, P.WHITE)
    if not model.placedDoll[slotIdx] then
      cv:AddSprite(p.x, p.y, 32, 32, m[3], P.GHOST_TINT)
    end
  end
  -- exact layout: empty slots keep their backdrop, so a gap in the
  -- snapshot reads as a gap rather than the grid ending early
  for _, p in ipairs(model.emptyBg or {}) do
    cv:AddSprite(p.x, p.y, P.BOX, P.BOX, slotBg, P.WHITE)
  end
  -- cell backdrops + missing/partial tints (doll backdrops drawn above)
  for _, c in ipairs(model.cells) do
    local bx, by, bs = c.x + P.SLOT_BG_DX, c.y + P.SLOT_BG_DY, P.BOX
    if not c.doll then cv:AddSprite(bx, by, bs, bs, slotBg, P.WHITE) end
    if c.missing then
      cv:AddRectangle(bx, by, bs, bs, P.MISS_RED)
    elseif c.partial then
      cv:AddRectangle(bx, by, bs, bs, P.UNDER_ORANGE)
    end
  end
end

-- Shortfall "-N" plates on a SECOND canvas, created after the cell sprites
-- so the text draws above the item art.
local function drawLabels(cv, model, view)
  cv:SetSize(math.max(P.CHROME_W, view.width or P.CHROME_W),
    math.max(model.chromeH, view.height or 0))
  for _, c in ipairs(model.cells) do
    if c.shortfall ~= nil and c.shortfall > 0 then
      local txt = "-" .. P.FormatCount(c.shortfall)
      local w = 22
      pcall(function()
        w = config.Font.FromID(SHORTFALL_FONT):GetStringWidth(txt, false) + 6
      end)
      local lx, ly = c.x - 3, c.y + 20 -- bottom-left of the slot box
      cv:AddRectangle(lx, ly, w, SHORTFALL_FONT_H + 2, 0x000000A6)
      cv:AddText(lx + 3, ly + 1, txt, SHORTFALL_FONT, P.SHORTFALL_COLOUR)
    end
  end
end

-- ---- the drawer (Core calls this for every drawing) ---------------------------
-- Errors are deliberately NOT swallowed here.
M.Draw = function(view)
  -- stacks were restored before Core redraws, and the old drawing's
  -- components are about to be destroyed with their layers
  unflagAll()
  drawing = nil
  local preset = bankutil.ViewPreset()
  if preset == nil then return 0 end
  -- consumed marks belong to ONE preset's cell geometry
  if preset.id ~= lastPresetId then
    lastPresetId = preset.id
    consumed = {}
  end

  local bank, freshCounts = readBank()
  counts = freshCounts
  carried = carriedCounts()
  local exact = PersistentDB:GetBool("ui.exactLayout") == true
  -- Tints are built from carried PLUS in-flight clicks.
  local model = P.Build(preset, bank, P.FoldPending(carried, pending),
    exact, nameOf)

  local canvas = ui.Canvas.new(view.parent)
  canvas:SetPos(0, 0)
  canvas.clickthrough = true -- the pointer must reach Core's input beneath
  drawChrome(canvas, model, view)

  -- One sprite per cell, badge-stamped, bound in allocation order
  -- (equipment, backpack ascending, BoB). EVERY cell is bound, missing
  -- ones included. Noted forms bind the RESOLVED id.
  local bySrc = {}
  -- Per-unit split groups bind NON-CONSUMED cells first, consumed cells
  -- LAST: Core assigns stacks by occurrence over its stocked-first
  -- grouping, so the placeholders land under exactly the cells the player
  -- withdrew from - the clicked cell dims, matching the standalone
  -- engine's sticky claims.
  local perUnitGroups = {}
  for _, c in ipairs(model.cells) do
    local s = ui.Sprite.new(view.parent)
    s:SetPos(c.x, c.y)
    s:SetSize(36, 32) -- every cell, doll or grid, is the same size
    s:SetAssociatedObject(c.obj)
    c.sprite = s
    c.dimmed = nil
    if c.perUnit then
      local key = c.srcObj or c.obj
      if perUnitGroups[key] == nil then perUnitGroups[key] = {} end
      local g = perUnitGroups[key]
      g[#g + 1] = c
      c.unitOrd = #g -- stable ordinal within the group, across redraws
    else
      view:BindItem(s, c.srcObj or c.obj)
    end
    if c.srcObj ~= nil then
      if bySrc[c.srcObj] == nil then bySrc[c.srcObj] = {} end
      local list = bySrc[c.srcObj]
      list[#list + 1] = c
    end
  end
  for key, g in pairs(perUnitGroups) do
    local marks = consumed[key]
    local set = (marks ~= nil) and marks.set or {}
    for _, c in ipairs(g) do
      if not set[c.unitOrd] then view:BindItem(c.sprite, key) end
    end
    for _, c in ipairs(g) do
      if set[c.unitOrd] then view:BindItem(c.sprite, key) end
    end
  end

  local labels = ui.Canvas.new(view.parent)
  labels:SetPos(0, 0)
  labels.clickthrough = true
  drawLabels(labels, model, view)

  drawing = { model = model, bySrc = bySrc }
  updateDisplays() -- badges + dims against the counts just read
  start()
  return model.chromeH
end

-- The view stopped being ours - close, bank close, dispose, integration
-- toggle or Core reload. Idempotent.
M.Stop = function()
  unflagAll()
  drawing = nil
  pending = {}
  recent = nil -- its cell belongs to the dead drawing
  stop()
end

-- main.lua injects this into bankutil.SetViewProvider.
M.Provider = { draw = M.Draw, stop = M.Stop }

return M
