-- The Bank Core bank-view engine: draws the preset into Core's custom view
-- as a stateless rebuild of the shared model (core/presetview), and runs
-- the live layer (badges, one-click flags, pending clicks) between redraws.
local M = {}
local prefs = require("core/prefs")

local P = require("core/presetview")
local invread = require("core/invread")
local uikit = require("ui/uikit")
local bankutil = require("core/bankutil")

local BANK_INV_STATIC = 201 -- the bank's item grid, where Core's moved stacks live

local SHORTFALL_FONT, SHORTFALL_FONT_H = uikit.SmallFont()

local drawing = nil -- { model, bySrc } for the current Core drawing
local counts = {} -- inv 95 totals
local carried = {} -- inv 93 + 94 + 530 totals
-- srcObj -> { amount, tick, snap, bySect }. `snap` is the snapshot obj, which
-- differs from the key for noted items; `bySect` splits amount by section.
local pending = {}
local tickCount = 0
local forceTicks = 0
local running = false
local flags = {} -- child -> { op, map, cell, origQty, origMode }
-- The last parked pairing, kept after its flag dies: a menu pick arrives
-- with the pointer on the menu, not the cell.
local recent = nil -- { child, cell, tick }
local RECENT_TTL = 150 -- ticks
-- Per-unit cell ordinals the player has withdrawn from. Survives redraws
-- and view toggles; cleared when the preset changes.
local consumed = {} -- srcObj -> { list = {ord..}, set = {[ord]=true} }
local lastPresetId = nil

local nameOf = uikit.ObjName

local carriedCounts = invread.Carried

-- Core's read lists placeholders at quantity 0; the inv 95 fallback may not.
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

local function unflagChild(child, entry)
  pcall(function()
    if entry.op ~= nil then
      child.opConfig:SetOpIDHighPriority(entry.op, false)
    end
  end)
  -- Core never restores quantity. A stacked cell gets the live bank total
  -- (the park-time reading is stale after a withdrawal); never-stamped
  -- children are left alone.
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

local PARK_TOLERANCE = 8 -- px between a parked child and its cell's sprite
local function spriteXY(c)
  return c.sprite.xyGlobal
end
-- A grid child is parked at a cell when its obj resolves to that cell, it
-- overlaps the cell's sprite, and the pointer is inside the cell. The
-- pointer test is required: a stack's home position can overlap a cell.
local function stepFlags()
  local model = drawing and drawing.model
  if model == nil then return end
  -- flags and stamps would block Core's per-occurrence stack-follow
  if model.exact then
    unflagAll()
    return
  end
  local grid = uikit.BankComponent(BANK_INV_STATIC)
  if grid == nil then
    unflagAll()
    return
  end
  local mouse = nil
  pcall(function() mouse = uikit.MousePos() end)
  if mouse == nil then
    unflagAll()
    return
  end
  -- Skips the grid walk when the pointer is in no cell. The bounds must
  -- stay identical to the park test below.
  local overCell = false
  for _, c in ipairs(model.cells) do
    if c.sprite ~= nil and c.srcObj ~= nil then
      local ok, sg = pcall(spriteXY, c)
      if ok and sg ~= nil
        and mouse.x >= sg.x - PARK_TOLERANCE
        and mouse.x < sg.x + 36 + PARK_TOLERANCE
        and mouse.y >= sg.y - PARK_TOLERANCE
        and mouse.y < sg.y + 32 + PARK_TOLERANCE then
        overCell = true
        break
      end
    end
  end
  if not overCell then
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
  for child, entry in pairs(flags) do
    if seen[child] == nil then
      unflagChild(child, entry)
      flags[child] = nil
    end
  end
  -- re-asserted every tick: client re-layouts can drop op config
  for child, c in pairs(seen) do
    recent = { child = child, cell = c, tick = tickCount }
    local entry = flags[child]
    if entry == nil then
      entry = { map = scanOps(child), cell = c }
      -- read before the stamp below ever touches this child
      pcall(function()
        entry.origQty = child.associatedObjectQuantity
        entry.origMode = child.associatedObjectQuantityMode
      end)
      flags[child] = entry
    elseif entry.cell ~= c then
      entry.cell = c
    end
    -- an inventory event can swap the parked child's op list in place
    if forceTicks > 0 then entry.map = scanOps(child) end
    local live = (c.srcObj ~= nil) and (counts[c.srcObj] or 0) or 0
    local want = P.ChooseOp(entry.map, cellRemaining(c), live,
      model.equipObjs[c.obj] == true, c.stacked)
    -- Examine is never flagged: it churns the label across Core's re-parks
    if want ~= nil and want == entry.map.examine then want = nil end
    pcall(function()
      local oc = child.opConfig
      if want ~= entry.op and entry.op ~= nil then
        oc:SetOpIDHighPriority(entry.op, false)
      end
      entry.op = want
      if want ~= nil then oc:SetOpIDHighPriority(want, true) end
    end)
    -- Core reads this field and treats <= 0 as a placeholder: never stamp
    -- a placeholder, never stamp below 1. The client rewrites it on a
    -- withdrawal, hence the stamp every tick.
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

local function applyCellDisplay(c)
  if c.sprite == nil or drawing == nil then return end
  local banked = (c.srcObj ~= nil) and (drawing.model.claimQty[c.srcObj] or 0) or 0
  local rem, always, satisfied =
    P.Badge(c, cellRemaining(c), drawing.model.exact, banked)
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

-- Marks the cells Core backs with a placeholder. Assumes M.Draw's binding
-- order (consumed ordinals last); the two must change together.
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

-- Pending reconciles as items arrive in carried, not as they leave the
-- bank: Core redraws on the bank change while the item is still in flight.
local function refreshCounts()
  local freshCarried = carriedCounts()
  P.ReconcileArrivals(pending, carried, freshCarried, tickCount)
  carried = freshCarried
  counts = invread.CountInv(95)
end

local function tickBody()
  tickCount = tickCount + 1
  if drawing == nil then return end
  local structural = forceTicks > 0 or tickCount % 25 == 0
  if forceTicks > 0 then forceTicks = forceTicks - 1 end
  if structural then
    -- a close that missed Stop must not leave flags on bank children
    if bankutil.ActivePresetId() == nil then
      M.Stop()
      return
    end
    if bankutil.NativeSearchActive() then
      pcall(bankutil.Hide)
      return
    end
    refreshCounts()
    updateDisplays()
  end
  stepFlags()
end

local function onTick()
  pcall(tickBody)
end

local function stop()
  if not running then return end
  running = false
  pcall(function() Event.Logic.Unsubscribe("pvBuTick") end)
  pcall(function() Event.MiniMenuEntrySelected.Unsubscribe("pvBuMenu") end)
  pcall(function() Event.InventoryUpdated.Unsubscribe("pvBuInv") end)
end

-- Books left clicks and menu picks into `pending` as the client dispatches
-- them, so a rapid second click sees the first.
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
    -- backpack clicks on the same obj must not book: the refresh pass
    -- already counts them
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
    local sect = "backpack"
    local step = verb:match("^Withdraw%-(%d+)$")
    if step ~= nil then
      amount = tonumber(step)
    elseif verb == "Withdraw-All" then
      amount = counts[obj] or 0
    elseif verb:find("Wear") or verb:find("Wield") or verb:find("Equip") then
      amount = 1
      sect = "equipment"
    end
    if amount == nil or amount <= 0 then return end
    -- matched with ==: the event's component is fresh userdata, so it
    -- cannot be used as a table key
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
      -- a menu pick arrives after the pointer-gated flag is gone
      if recent ~= nil and recent.child == clicked
        and (tickCount - (recent.tick or 0)) <= RECENT_TTL
        and recent.cell ~= nil then
        sect = recent.cell.section or sect
        cellHit = recent.cell
      end
    end)
    -- A click can land before the tick that flags the pairing; the clicked
    -- component is parked at its cell, so position finds it.
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
        -- 95 is the bank; 93, 94 and 530 are the carried inventories
        if iid == 95 or iid == 93 or iid == 94 or iid == 530 then
          forceTicks = 3
        end
      end)
    end)
  end)
end

local function drawChrome(cv, model, view)
  local w = math.max(P.CHROME_W, view.width or P.CHROME_W)
  local h = math.max(model.chromeH, view.height or 0)
  cv:SetSize(w, h)
  local font = id.Font.CINZEL_13PT_BOLD
  local function divider(y, text)
    cv:AddText(P.ORIGIN_X - 2, y - 3, text, font, P.TITLE_COLOUR)
    cv:AddRectangle(P.ORIGIN_X, y + 18, P.GRID_W, 1, P.DIVIDER_COLOUR)
  end
  cv:AddText(P.ORIGIN_X - 2, P.TITLE_Y - 3, tostring(model.preset.name or ""),
    font, P.TITLE_COLOUR)
  divider(P.ORIGIN_Y, "Worn")
  divider(P.PACK_HEADER_Y, "Backpack")
  if model.bobHeaderY ~= nil then divider(model.bobHeaderY, "Beast of Burden") end
  local slotBg = prettyui.Sprites.ITEM_SLOT_BACKGROUND
  -- connectors first, so slot art covers their ends
  for _, c in ipairs(P.WORN_CONNECTORS) do
    cv:AddSprite(P.DOLL_CX + c[1], P.DOLL_Y + c[2], c[3], c[4], c[5],
      P.CONNECTOR_TINT)
  end
  for slotIdx, m in pairs(P.WORN_BANK) do
    local p = P.WornPos(slotIdx)
    cv:AddSprite(p.x + P.SLOT_BG_DX, p.y + P.SLOT_BG_DY, P.BOX, P.BOX,
      slotBg, P.WHITE)
    if not model.placedDoll[slotIdx] then
      cv:AddSprite(p.x, p.y, 32, 32, m[3], P.GHOST_TINT)
    end
  end
  for _, p in ipairs(model.emptyBg or {}) do
    cv:AddSprite(p.x, p.y, P.BOX, P.BOX, slotBg, P.WHITE)
  end
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
      local lx, ly = c.x - 3, c.y + 20
      cv:AddRectangle(lx, ly, w, SHORTFALL_FONT_H + 2, 0x000000A6)
      cv:AddText(lx + 3, ly + 1, txt, SHORTFALL_FONT, P.SHORTFALL_COLOUR)
    end
  end
end

-- Core calls this for every drawing; returns the content height. Errors
-- must propagate: Core then restores the native view. No handle methods
-- may be called from here (they answer "busy").
M.Draw = function(view)
  unflagAll()
  drawing = nil
  local preset = bankutil.ViewPreset()
  if preset == nil then return 0 end
  -- consumed marks belong to one preset's cell geometry
  if preset.id ~= lastPresetId then
    lastPresetId = preset.id
    consumed = {}
  end

  local bank, freshCounts = readBank()
  counts = freshCounts
  carried = carriedCounts()
  local exact = prefs.GetBool("ui.exactLayout") == true
  -- pending is folded in: Core redraws before carried shows the withdrawal
  local model = P.Build(preset, bank, P.FoldPending(carried, pending),
    exact, nameOf)

  local canvas = ui.Canvas.new(view.parent)
  canvas:SetPos(0, 0)
  canvas.clickthrough = true -- the pointer must reach Core's input beneath
  drawChrome(canvas, model, view)

  -- Core matches stacks in binding order, so cells bind in model order and
  -- every cell is bound, missing ones included. Per-unit groups bind
  -- consumed cells last; markClaimGone assumes that order.
  local bySrc = {}
  local perUnitGroups = {}
  for _, c in ipairs(model.cells) do
    local s = ui.Sprite.new(view.parent)
    s:SetPos(c.x, c.y)
    s:SetSize(36, 32)
    s:SetAssociatedObject(c.obj)
    c.sprite = s
    c.dimmed = nil
    if c.perUnit then
      local key = c.srcObj or c.obj
      if perUnitGroups[key] == nil then perUnitGroups[key] = {} end
      local g = perUnitGroups[key]
      g[#g + 1] = c
      c.unitOrd = #g -- stable across redraws
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

  -- created after the sprites so the plates draw above the item art
  local labels = ui.Canvas.new(view.parent)
  labels:SetPos(0, 0)
  labels.clickthrough = true
  drawLabels(labels, model, view)

  drawing = { model = model, bySrc = bySrc }
  updateDisplays()
  start()
  return model.chromeH
end

-- Idempotent. Every way the view stops being ours must reach this, or
-- opConfig flags stay on native bank children.
M.Stop = function()
  unflagAll()
  drawing = nil
  pending = {}
  recent = nil
  stop()
end

M.Provider = { draw = M.Draw, stop = M.Stop }

return M
