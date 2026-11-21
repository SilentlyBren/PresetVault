-- The preset-view model shared by both bank engines: layout geometry, cell
-- building, live top-up satisfaction, one-click op choice and badge rules.
-- Pure: no game globals; the obj-name lookup is injected by the caller.
local P = {}

P.CELL_W, P.CELL_H, P.COLS = 44, 40, 7
P.ORIGIN_X = 8
P.TITLE_Y = 6
local TITLE_GAP = 8
P.ORIGIN_Y = P.TITLE_Y + 18 + TITLE_GAP
P.SECTION_H = 26
P.PACK_X = P.ORIGIN_X + 4
P.DOLL_TOP_PAD = 2
P.GRID_W = P.COLS * P.CELL_W - 4
P.CHROME_W = P.ORIGIN_X + P.GRID_W + 8
-- a cell's x, y is its item art; the slot backdrop sits at this offset from it
P.SLOT_BG_DX, P.SLOT_BG_DY = -4, -4

P.DIVIDER_COLOUR = 0xB8A169CC
P.TITLE_COLOUR = 0xE7D7B0FF
P.WHITE = 0xFFFFFFFF
P.GHOST_TINT = 0xFFFFFF99
P.CONNECTOR_TINT = 0xFFFFFF66
P.PANEL_COLOUR = 0x332E29FF
P.DIM_ALPHA = 0.4
P.MISS_RED = 0xC0141447
P.PART_YELLOW = 0xC0A01435
P.UNDER_ORANGE = 0xFF7A0055
P.SHORTFALL_COLOUR = 0xFF4040FF

P.BOX, P.GAP = 40, 4
local BOX, GAP = P.BOX, P.GAP
local PITCH = BOX + GAP
local NEAR, FAR = PITCH, BOX + 24
local COL = { c = 0, nl = -NEAR, nr = NEAR, fl = -FAR, fr = FAR }
local ROW = { 0, PITCH, PITCH * 2, PITCH * 3, PITCH * 4 }

-- engine slot index -> { column offset, row y, ghost placeholder sprite }
P.WORN_BANK = {
  [1] = { COL.c, ROW[1], 24431 }, [18] = { COL.nr, ROW[1], 24443 },
  [2] = { COL.nl, ROW[2], 24432 }, [3] = { COL.c, ROW[2], 24433 },
  [14] = { COL.nr, ROW[2], 24441 },
  [4] = { COL.fl, ROW[3], 24434 }, [5] = { COL.c, ROW[3], 24436 },
  [6] = { COL.fr, ROW[3], 24437 },
  [8] = { COL.c, ROW[4], 24438 },
  [10] = { COL.fl, ROW[5], 24439 }, [11] = { COL.c, ROW[5], 24440 },
  [13] = { COL.fr, ROW[5], 24435 },
}

-- { x, y, w, h, sprite }, x relative to the centre column's left edge
local T = 10
P.WORN_CONNECTORS = {}
do
  local WC = P.WORN_CONNECTORS
  local mid = (BOX - T) // 2
  for r = 1, 4 do
    WC[#WC + 1] = { mid, ROW[r] + BOX, T, GAP, 29316 }
  end
  WC[#WC + 1] = { -GAP, ROW[2] + mid, GAP, T, 29313 }
  WC[#WC + 1] = { BOX, ROW[2] + mid, GAP, T, 29313 }
  WC[#WC + 1] = { -(FAR - BOX), ROW[3] + mid, FAR - BOX, T, 29313 }
  WC[#WC + 1] = { BOX, ROW[3] + mid, FAR - BOX, T, 29313 }
  local runY, runH = ROW[3] + BOX, ROW[5] - (ROW[3] + BOX)
  WC[#WC + 1] = { COL.fl + mid, runY, T, runH, 29316 }
  WC[#WC + 1] = { COL.fr + mid, runY, T, runH, 29316 }
end

P.DOLL_CX = P.PACK_X + FAR
P.DOLL_Y = P.ORIGIN_Y + P.SECTION_H + P.DOLL_TOP_PAD

P.WornPos = function(slotIdx)
  local m = P.WORN_BANK[slotIdx]
  if m == nil then return { x = P.DOLL_CX, y = P.DOLL_Y } end
  return { x = P.DOLL_CX + m[1] - P.SLOT_BG_DX,
    y = P.DOLL_Y + m[2] - P.SLOT_BG_DY, slot = slotIdx }
end
P.PACK_HEADER_Y = P.DOLL_Y + ROW[5] + BOX + 8

P.PENDING_TTL = 75 -- ticks
P.BULK_ALL_ABOVE = 500

-- The bank obj serving a preset obj: the exact id, else id - 1 (the unnoted
-- base of a noted item) when the display names match.
local function resolveSource(bank, obj, name, nameOf)
  if bank[obj] ~= nil then return obj end
  local baseId = obj - 1
  if bank[baseId] ~= nil then
    local match = false
    if nameOf ~= nil then
      local n = nameOf(baseId)
      match = n ~= nil and tostring(n) == tostring(name)
    end
    if match then return baseId end
  end
  return nil
end

-- array order is the spill-over order
local CONTAINERS = { "backpack", "equipment", "bob" }

-- bank[obj] = { stacks, units (never a component's display quantity) };
-- carried[container][obj] = units; nameOf(objId) = display name.
-- The order of the returned cells is the satisfaction priority.
P.Build = function(preset, bank, carried, exact, nameOf)
  local cells = {}
  local claimIdx = {}
  local claimedUnits = {}
  local emptyBg = {}
  local currentSection = "equipment"

  local function addCell(e, pos, sectionNeed)
    local need = sectionNeed or e.count
    local srcObj = resolveSource(bank, e.obj, e.name, nameOf)
    local hasStack, poolIndex, stacked = false, nil, false
    if srcObj ~= nil then
      local b = bank[srcObj]
      if b.stacks == 1 then
        hasStack, poolIndex = true, 1
        stacked = (b.units or 0) > 1
      else
        claimIdx[srcObj] = (claimIdx[srcObj] or 0) + 1
        poolIndex = claimIdx[srcObj]
        hasStack = poolIndex <= (b.stacks or 0)
      end
    end
    local bankLeft = 0
    if srcObj ~= nil then
      local units = bank[srcObj].units or 0
      bankLeft = math.max(0, units - (claimedUnits[srcObj] or 0))
      claimedUnits[srcObj] = (claimedUnits[srcObj] or 0) + math.min(need, bankLeft)
    end
    local cell = {
      x = pos.x, y = pos.y, obj = e.obj, srcObj = srcObj, name = e.name,
      need = need, section = currentSection,
      stacked = stacked, hasStack = hasStack, poolIndex = poolIndex,
      -- carried coverage is applied once every cell exists
      shortBank = math.max(0, need - bankLeft),
    }
    cells[#cells + 1] = cell
    return cell
  end

  local placedDoll = {}
  currentSection = "equipment"
  for _, e in ipairs(preset.equipment or {}) do
    local c = addCell(e, P.WornPos(e.slot))
    c.doll = true
    placedDoll[e.slot] = true
  end

  -- Returns rows used, or nil when a slot is missing, duplicated or out of
  -- range; the caller then builds the section compact.
  local function addSectionExact(entries, baseY, slotCount)
    local bySlot = {}
    for _, e in ipairs(entries or {}) do
      local s = tonumber(e.slot)
      if s == nil or s < 1 or s > slotCount or s ~= math.floor(s)
        or bySlot[s] ~= nil then return nil end
      bySlot[s] = e
    end
    for s = 1, slotCount do
      local pos = { x = P.PACK_X + ((s - 1) % P.COLS) * P.CELL_W,
        y = baseY + ((s - 1) // P.COLS) * P.CELL_H }
      local e = bySlot[s]
      if e ~= nil then
        addCell(e, pos, e.count)
      else
        emptyBg[#emptyBg + 1] =
          { x = pos.x + P.SLOT_BG_DX, y = pos.y + P.SLOT_BG_DY }
      end
    end
    return math.ceil(slotCount / P.COLS)
  end

  -- Per-instance items (several stacks, at most one unit each) get one cell
  -- per unit. units <= stacks keeps a stack beside its own placeholder merged.
  local function addSection(entries, baseY)
    local needByObj, order, nameByObj = {}, {}, {}
    for _, e in ipairs(entries or {}) do
      if needByObj[e.obj] == nil then
        order[#order + 1] = e.obj
        nameByObj[e.obj] = e.name
      end
      needByObj[e.obj] = (needByObj[e.obj] or 0) + e.count
    end
    local idx = 0
    for _, obj in ipairs(order) do
      local need = needByObj[obj]
      local cellCount, cellNeed = 1, need
      if need > 1 then
        local srcObj = resolveSource(bank, obj, nameByObj[obj], nameOf)
        local b = srcObj ~= nil and bank[srcObj] or nil
        if b ~= nil and (b.stacks or 0) > 1
          and (b.units or 0) <= (b.stacks or 0) then
          cellCount, cellNeed = need, 1
        end
      end
      for _ = 1, cellCount do
        local pos = { x = P.PACK_X + (idx % P.COLS) * P.CELL_W,
          y = baseY + (idx // P.COLS) * P.CELL_H }
        local cell = addCell({ obj = obj, name = nameByObj[obj],
          count = cellNeed }, pos, cellNeed)
        if cellCount > 1 then cell.perUnit = true end
        idx = idx + 1
      end
    end
    return math.max(1, math.ceil(idx / P.COLS))
  end

  local function sectionRows(entries, baseY, slotCount)
    if exact and slotCount ~= nil then
      local rows = addSectionExact(entries, baseY, slotCount)
      if rows ~= nil then return rows end
    end
    return addSection(entries, baseY)
  end

  -- raised to the highest entry slot so a mismatched size never hides an item
  local bobSlots = nil
  if preset.bob ~= nil then
    bobSlots = math.floor(tonumber(preset.bob.size) or 32)
    if bobSlots < 1 then bobSlots = 1 end
    if bobSlots > 32 then bobSlots = 32 end
    for _, e in ipairs(preset.bob.items or {}) do
      local s = tonumber(e.slot)
      if s ~= nil and s > bobSlots and s <= 32 then
        bobSlots = math.ceil(s)
      end
    end
  end

  currentSection = "backpack"
  local packRows = sectionRows(preset.backpack, P.PACK_HEADER_Y + P.SECTION_H, 28)
  local bobHeaderY, bobRows = nil, 0
  if preset.bob ~= nil and preset.bob.items ~= nil and #preset.bob.items > 0 then
    bobHeaderY = P.PACK_HEADER_Y + P.SECTION_H + packRows * P.CELL_H + 6
    currentSection = "bob"
    bobRows = sectionRows(preset.bob.items, bobHeaderY + P.SECTION_H, bobSlots)
  end

  local bottom
  if bobHeaderY ~= nil then
    bottom = bobHeaderY + P.SECTION_H + bobRows * P.CELL_H
  else
    bottom = P.PACK_HEADER_Y + P.SECTION_H + packRows * P.CELL_H
  end

  -- Both passes are needed: carried units cover their own container's
  -- cells first, then leftovers spill to the other sections.
  local pools = {}
  for _, k in ipairs(CONTAINERS) do
    pools[k] = {}
    for obj, n in pairs((carried or {})[k] or {}) do pools[k][obj] = n end
  end
  for _, c in ipairs(cells) do
    c.short = c.shortBank
    if c.short > 0 then
      local pool = pools[c.section]
      local take = math.min(c.short, pool[c.obj] or 0)
      pool[c.obj] = (pool[c.obj] or 0) - take
      c.short = c.short - take
    end
  end
  for _, c in ipairs(cells) do
    for _, k in ipairs(CONTAINERS) do
      if c.short <= 0 then break end
      local take = math.min(c.short, pools[k][c.obj] or 0)
      pools[k][c.obj] = (pools[k][c.obj] or 0) - take
      c.short = c.short - take
    end
  end
  for _, c in ipairs(cells) do
    -- hasStack stays out of this: a zero-unit placeholder keeps its stack
    -- for clicks but counts as missing
    c.missing = c.short >= (c.need or 1)
    c.partial = c.short > 0 and not c.missing
    if (c.missing or c.partial) and c.need > 1 then c.shortfall = c.short end
    c.shortBank, c.short = nil, nil
  end

  local equipObjs = {}
  for _, e in ipairs(preset.equipment or {}) do equipObjs[e.obj] = true end
  local claimQty = {}
  for _, c in ipairs(cells) do
    if c.srcObj ~= nil then claimQty[c.srcObj] = bank[c.srcObj].units or 0 end
  end
  -- keyed by snapshot obj, unclaimable cells included, in cell order
  local liveCells = {}
  for _, c in ipairs(cells) do
    if liveCells[c.obj] == nil then liveCells[c.obj] = {} end
    local list = liveCells[c.obj]
    list[#list + 1] = c
  end

  return {
    preset = preset, cells = cells, placedDoll = placedDoll,
    bobHeaderY = bobHeaderY, chromeH = bottom + 8, emptyBg = emptyBg,
    exact = exact == true,
    equipObjs = equipObjs, claimQty = claimQty, liveCells = liveCells,
  }
end

-- Units cell c still wants, against live carried counts plus unconfirmed
-- clicks. pending[srcObj] = { amount, tick, bySect = { section = units } }.
P.CellRemaining = function(model, c, carried, pending)
  local cells = (model.liveCells or {})[c.obj]
  if cells == nil then return c.need end
  -- cells the engine marked claimGone (backing stack emptied) are covered first
  local order = cells
  do
    local gone = nil
    for _, cell in ipairs(cells) do
      if cell.claimGone then
        gone = gone or {}
        gone[#gone + 1] = cell
      end
    end
    if gone ~= nil then
      order = gone
      for _, cell in ipairs(cells) do
        if not cell.claimGone then order[#order + 1] = cell end
      end
    end
  end
  cells = order
  carried = carried or {}
  local pool = {}
  for _, k in ipairs(CONTAINERS) do
    pool[k] = (carried[k] or {})[c.obj] or 0
  end
  -- section tags are capped by p.amount, which reconciles shrink without
  -- touching the tags; the untagged remainder joins the spill
  local bySect, free = {}, 0
  if c.srcObj ~= nil and pending ~= nil then
    local p = pending[c.srcObj]
    if p ~= nil then
      local budget = p.amount or 0
      for k, v in pairs(p.bySect or {}) do
        local use = math.min(v, budget)
        bySect[k] = use
        budget = budget - use
      end
      free = budget
    end
  end
  local rem = {}
  for i, cell in ipairs(cells) do
    local k = cell.section or "backpack"
    local take = math.min(cell.need, pool[k] or 0)
    pool[k] = (pool[k] or 0) - take
    local r = cell.need - take
    local dir = bySect[cell.section] or 0
    local take2 = math.min(r, dir)
    bySect[cell.section] = dir - take2
    rem[i] = r - take2
  end
  local spill = free
  for _, k in ipairs(CONTAINERS) do spill = spill + pool[k] end
  for _, v in pairs(bySect) do spill = spill + v end
  local mine = c.need
  for i, cell in ipairs(cells) do
    local take = math.min(rem[i], spill)
    spill = spill - take
    rem[i] = rem[i] - take
    if cell == c then mine = rem[i] end
  end
  return mine
end

-- A confirmed bank drop consumes its prediction. Mutates `pending`.
P.ReconcilePending = function(pending, oldCounts, freshCounts, nowTick, ttl)
  ttl = ttl or P.PENDING_TTL
  for obj, p in pairs(pending) do
    local drop = (oldCounts[obj] or 0) - (freshCounts[obj] or 0)
    if drop > 0 then p.amount = math.max(0, (p.amount or 0) - drop) end
    if (p.amount or 0) <= 0 or (nowTick - (p.tick or 0)) > ttl then
      pending[obj] = nil
    end
  end
end

-- A rise in the carried counts consumes its prediction, read at p.snap (the
-- snapshot obj) or else the pending key. Mutates `pending`.
P.ReconcileArrivals = function(pending, oldCarried, freshCarried, nowTick, ttl)
  ttl = ttl or P.PENDING_TTL
  for key, p in pairs(pending) do
    local obj = p.snap or key
    -- per container, not the total: a backpack-to-BoB transfer cancels out
    for _, k in ipairs(CONTAINERS) do
      local rise = (((freshCarried or {})[k]) or {})[obj] or 0
      rise = rise - ((((oldCarried or {})[k]) or {})[obj] or 0)
      if rise > 0 then
        p.amount = math.max(0, (p.amount or 0) - rise)
        if p.bySect ~= nil then
          local v = p.bySect[k] or 0
          local used = math.min(v, rise)
          p.bySect[k] = v - used
          rise = rise - used
          if rise > 0 then
            for s2, v2 in pairs(p.bySect) do
              local u2 = math.min(v2, rise)
              p.bySect[s2] = v2 - u2
              rise = rise - u2
              if rise <= 0 then break end
            end
          end
        end
      end
    end
    if (p.amount or 0) <= 0 or (nowTick - (p.tick or 0)) > ttl then
      pending[key] = nil
    end
  end
end

-- Carried counts plus in-flight clicks, as fresh tables; inputs untouched.
P.FoldPending = function(carried, pending)
  local eff = {}
  for _, k in ipairs(CONTAINERS) do
    eff[k] = {}
    for obj, n in pairs((carried or {})[k] or {}) do eff[k][obj] = n end
  end
  for key, p in pairs(pending or {}) do
    local obj = p.snap or key
    local total = p.amount or 0
    for sect, v in pairs(p.bySect or {}) do
      local use = math.min(v, total)
      local pool = eff[sect] or eff.backpack
      pool[obj] = (pool[obj] or 0) + use
      total = total - use
    end
    if total > 0 then
      eff.backpack[obj] = (eff.backpack[obj] or 0) + total
    end
  end
  return eff
end

-- held = { [slot] = { obj, count } }. Returns states[slot] ("ok", "under",
-- "over", "wrong", "missing"; unwanted slots stay nil) and, when positional,
-- { from, to } for the lowest misplaced slot or nil.
P.CompareSlots = function(entries, held, capacity, positional)
  local wantBySlot = {}
  for _, e in ipairs(entries or {}) do
    local s = tonumber(e.slot)
    if s ~= nil and s >= 1 and s <= capacity and s == math.floor(s)
      and wantBySlot[s] == nil then
      wantBySlot[s] = e
    end
  end
  local states = {}

  if positional then
    for s = 1, capacity do
      local w, h = wantBySlot[s], held[s]
      if w ~= nil and h ~= nil then
        if h.obj == w.obj then
          states[s] = (h.count == w.count) and "ok"
            or (h.count < w.count) and "under" or "over"
        else
          states[s] = "wrong"
        end
      elseif w ~= nil then
        states[s] = "missing"
      end
    end
    local purple = nil
    for a = 1, capacity do
      local h = held[a]
      if h ~= nil and (wantBySlot[a] == nil or wantBySlot[a].obj ~= h.obj) then
        for b = 1, capacity do
          local w = wantBySlot[b]
          if b ~= a and w ~= nil and w.obj == h.obj
            and (held[b] == nil or held[b].obj ~= w.obj) then
            purple = { from = a, to = b }
            break
          end
        end
        if purple ~= nil then break end
      end
    end
    return states, purple
  end

  -- own-slot items allocate first, so an earlier want cannot take a correct slot
  local heldTotal = {}
  for _, h in pairs(held) do
    heldTotal[h.obj] = (heldTotal[h.obj] or 0) + (h.count or 0)
  end
  for s = 1, capacity do
    local w, h = wantBySlot[s], held[s]
    if w ~= nil and h ~= nil and h.obj == w.obj then
      states[s] = (h.count == w.count) and "ok"
        or (h.count < w.count) and "under" or "over"
      heldTotal[w.obj] = math.max(0,
        (heldTotal[w.obj] or 0) - math.min(w.count, h.count))
    end
  end
  for s = 1, capacity do
    if states[s] == nil and wantBySlot[s] ~= nil then
      local w = wantBySlot[s]
      local avail = heldTotal[w.obj] or 0
      if avail >= (w.count or 1) then
        heldTotal[w.obj] = avail - w.count
      elseif avail > 0 then
        heldTotal[w.obj] = 0
        states[s] = "under"
      else
        states[s] = "missing"
      end
    end
  end
  return states, nil
end

-- list = { { idx = <0-based op index>, name = <op name> }, ... }
P.BuildOpMap = function(list)
  local map = { steps = {} }
  for _, e in ipairs(list or {}) do
    local s = tostring(e.name)
    local step = s:match("^Withdraw%-(%d+)$")
    if step ~= nil then
      map.steps[#map.steps + 1] = { step = tonumber(step), idx = e.idx }
    elseif s == "Withdraw-All" then
      map.all = e.idx
    elseif s:find("Wear") or s:find("Wield") or s:find("Equip") then
      map.wear = e.idx
    elseif s == "Examine" then
      map.examine = e.idx
    end
  end
  table.sort(map.steps, function(a, b) return a.step > b.step end)
  return map
end

-- Returns the op index to make the left-click default, or nil to leave the
-- native default. The satisfied check must stay first: it stops overshoot.
P.ChooseOp = function(map, remaining, live, isEquip, stacked)
  if remaining <= 0 then return map.examine end
  if isEquip then return map.wear end
  if not stacked then return nil end
  local want = nil
  if map.all ~= nil and (remaining >= (live or 0) or remaining > P.BULK_ALL_ABOVE) then
    want = map.all
  else
    for _, st in ipairs(map.steps) do
      if st.step <= remaining then
        want = st.idx
        break
      end
    end
    if want == nil and #map.steps > 0 then want = map.steps[#map.steps].idx end
  end
  return want
end

-- Returns qty, alwaysShow, satisfied. banked = claim-time units for the
-- cell's srcObj (model.claimQty).
P.Badge = function(c, rem, exactView, banked)
  local always = rem > 0
    and (c.need > 1 or (c.stacked and not exactView and not c.doll))
  local satisfied = rem <= 0
  local qty = rem
  if satisfied and c.need <= 1 and ((banked or 0) <= 1 or exactView or c.doll) then
    qty = 1 -- the MULTIPLE display mode hides a quantity of 1
  end
  return qty, always, satisfied
end

-- 1000, 5000, 10.2k, 100k, 2000k, 10m: one truncated decimal below 100 of a unit
P.FormatCount = function(n)
  n = math.floor(tonumber(n) or 0)
  local sign = ""
  if n < 0 then sign, n = "-", -n end
  local units = {
    { 1e10, 1e9, "b" },
    { 1e7, 1e6, "m" },
    { 1e4, 1e3, "k" },
  }
  for _, u in ipairs(units) do
    if n >= u[1] then
      local v = n / u[2]
      if v < 100 then
        local tenths = math.floor(v * 10) / 10
        if tenths % 1 == 0 then
          return sign .. string.format("%d%s", tenths, u[3])
        end
        return sign .. string.format("%.1f%s", tenths, u[3])
      end
      return sign .. string.format("%d%s", math.floor(v), u[3])
    end
  end
  return sign .. tostring(n)
end

return P
