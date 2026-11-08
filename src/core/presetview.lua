-- The preset-view model shared by both bank engines: layout geometry, cell
-- building, live top-up satisfaction, one-click op choice and badge rules.
--
-- Pure - plain data in, plain data out, no game globals. The single game
-- lookup it needs (obj id to display name, for noted-form guarding) is
-- injected by the caller.
local P = {}

-- ---- layout -----------------------------------------------------------------
-- 7-column grid at the bank's own slot pitch. The whole view hangs off
-- ORIGIN_Y, so it shifts as one block.
P.CELL_W, P.CELL_H, P.COLS = 44, 40, 7
P.ORIGIN_X = 8
P.TITLE_Y = 6
local TITLE_GAP = 8
P.ORIGIN_Y = P.TITLE_Y + 18 + TITLE_GAP -- 18 = divider text-line height
P.SECTION_H = 26 -- titled divider: text line + 1px rule under it
P.PACK_X = P.ORIGIN_X + 4
P.DOLL_TOP_PAD = 2
P.GRID_W = P.COLS * P.CELL_W - 4
P.CHROME_W = P.ORIGIN_X + P.GRID_W + 8
P.SLOT_BG_DX, P.SLOT_BG_DY = -4, -4

-- Shared palette; both engines must render identically.
P.DIVIDER_COLOUR = 0xB8A169CC
P.TITLE_COLOUR = 0xE7D7B0FF
P.WHITE = 0xFFFFFFFF
P.GHOST_TINT = 0xFFFFFF99
P.CONNECTOR_TINT = 0xFFFFFF66 -- 40%: connector art is high-contrast
P.PANEL_COLOUR = 0x332E29FF -- the bank's own backdrop
P.DIM_ALPHA = 0.4 -- satisfied cells, mirroring a native placeholder
P.MISS_RED = 0xC0141447 -- missing tint (RGBA, ~28%)
P.PART_YELLOW = 0xC0A01435 -- partial tint
-- Under-supplied tint. Full-saturation orange at a higher alpha than the
-- red: the bank backdrop is itself a dark desaturated orange, so a muted
-- orange only brightens it - this one has to win on chroma.
P.UNDER_ORANGE = 0xFF7A0055
P.SHORTFALL_COLOUR = 0xFF4040FF

-- Worn doll: the native arrangement rebuilt at OUR slot size, so doll,
-- backpack and BoB cells all read as one grid.
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

-- The doll's connector lines, derived for our box size rather than
-- hardcoded: { x, y, w, h, sprite }, x relative to the CENTRE column's left
-- edge. Sprite 29313 is the horizontal art, 29316 the vertical; both
-- stretch, so each run is one stretched sprite rather than tiled art.
local T = 10 -- line thickness across its short axis
P.WORN_CONNECTORS = {}
do
  local WC = P.WORN_CONNECTORS
  local mid = (BOX - T) // 2
  for r = 1, 4 do -- vertical stubs down the centre column, one per row gap
    WC[#WC + 1] = { mid, ROW[r] + BOX, T, GAP, 29316 }
  end
  -- row 2: centre <-> near columns (cape/neck, neck/ammo)
  WC[#WC + 1] = { -GAP, ROW[2] + mid, GAP, T, 29313 }
  WC[#WC + 1] = { BOX, ROW[2] + mid, GAP, T, 29313 }
  -- row 3: centre <-> far columns (main hand, off hand)
  WC[#WC + 1] = { -(FAR - BOX), ROW[3] + mid, FAR - BOX, T, 29313 }
  WC[#WC + 1] = { BOX, ROW[3] + mid, FAR - BOX, T, 29313 }
  -- long verticals down the outer columns (weapons -> gloves/ring)
  local runY, runH = ROW[3] + BOX, ROW[5] - (ROW[3] + BOX)
  WC[#WC + 1] = { COL.fl + mid, runY, T, runH, 29316 }
  WC[#WC + 1] = { COL.fr + mid, runY, T, runH, 29316 }
end

-- Doll centre column, placed so the FAR columns line their x up with the
-- backpack grid's left-hand column below.
P.DOLL_CX = P.PACK_X + FAR
P.DOLL_Y = P.ORIGIN_Y + P.SECTION_H + P.DOLL_TOP_PAD

-- A worn slot's cell position.
P.WornPos = function(slotIdx)
  local m = P.WORN_BANK[slotIdx]
  if m == nil then return { x = P.DOLL_CX, y = P.DOLL_Y } end
  return { x = P.DOLL_CX + m[1] - P.SLOT_BG_DX,
    y = P.DOLL_Y + m[2] - P.SLOT_BG_DY, slot = slotIdx }
end
-- doll bottom (last row + box) then a gap before the next divider
P.PACK_HEADER_Y = P.DOLL_Y + ROW[5] + BOX + 8

-- ---- one-click tuning ---------------------------------------------------------
P.PENDING_TTL = 75 -- ticks (~1.5s) before an unconfirmed click expires
P.BULK_ALL_ABOVE = 500 -- needs above this take Withdraw-All in one click

-- ---- source resolution --------------------------------------------------------
-- Which bank entry serves a preset obj: the exact id, else the unnoted base
-- (a noted item's id is base + 1), guarded by comparing display names so a
-- genuine miss cannot claim an unrelated neighbouring id.
--   bank[obj] = { stacks = native stack count, units = total units }
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

-- ---- model building -----------------------------------------------------------

-- The preset's three containers. Array order is the spill-over order.
local CONTAINERS = { "backpack", "equipment", "bob" }

-- Builds the whole view model from a preset and a bank read.
--   bank[obj] = { stacks, units }  - the caller's own read
--   carried   = per-container unit counts (see CONTAINERS)
--   exact     = one cell per snapshot slot instead of merged cells
--   nameOf    = obj id -> display name, for noted-form guarding
-- Returns the cell list with geometry, need allocation and tint flags, plus
-- the lookups the live layer needs.
--
-- Worn entries keep their doll positions; backpack and BoB either merge per
-- obj into compact grids, or map slot-for-slot in exact mode.
--
-- Cell fields: x, y, obj, srcObj, name, need, section, stacked, hasStack,
-- poolIndex, missing, partial, shortfall?, doll?
P.Build = function(preset, bank, carried, exact, nameOf)
  local cells = {}
  local claimIdx = {} -- per resolved obj: next unclaimed unique stack
  local claimedUnits = {} -- srcObj -> units already promised to earlier cells
  local emptyBg = {} -- exact mode: empty-slot backdrop positions
  local currentSection = "equipment" -- which section addCell is building

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
        -- Uniques: one cell per unit, each claiming a DISTINCT stack in
        -- bank order. Once they run out, the cell has no stack.
        claimIdx[srcObj] = (claimIdx[srcObj] or 0) + 1
        poolIndex = claimIdx[srcObj]
        hasStack = poolIndex <= (b.stacks or 0)
      end
    end
    -- Bank units still unpromised for this obj. Earlier cells are served
    -- first, so a duplicate's second cell only counts what is left over.
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
      -- what the bank cannot cover; carried coverage is applied later, in
      -- the container-aware pass that needs ALL cells to exist first
      shortBank = math.max(0, need - bankLeft),
    }
    cells[#cells + 1] = cell
    return cell
  end

  -- worn: one cell per entry at its doll position
  local placedDoll = {}
  currentSection = "equipment"
  for _, e in ipairs(preset.equipment or {}) do
    local c = addCell(e, P.WornPos(e.slot))
    c.doll = true
    placedDoll[e.slot] = true
  end

  -- Exact layout (the ui.exactLayout setting): one cell per snapshot
  -- SLOT at that slot's grid position, blanks kept. Returns rows used, or
  -- nil when the slot data cannot be trusted (missing/duplicate/
  -- out-of-range in a hand-edited vault) - the caller falls back to the
  -- compact grid, because a merged cell beats hiding an item.
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

  -- compact sections: merge per obj, then flow into the 7-col grid.
  -- EXCEPTION: per-instance items (several bank stacks of one obj, each
  -- holding at most one unit) get one cell PER UNIT, not a merged cell -
  -- the bank itself displays them as separate icons, and a single merged
  -- cell can only ever claim ONE of the stacks.
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
        -- marks the cell as one unit of a split group - the Core engine
        -- binds these in reverse so dims fill left-to-right (see bupage)
        if cellCount > 1 then cell.perUnit = true end
        idx = idx + 1
      end
    end
    return math.max(1, math.ceil(idx / P.COLS)) -- rows used (min 1 keeps shape)
  end

  local function sectionRows(entries, baseY, slotCount)
    if exact and slotCount ~= nil then
      local rows = addSectionExact(entries, baseY, slotCount)
      if rows ~= nil then return rows end
    end
    return addSection(entries, baseY)
  end

  -- BoB grid size mirrors the detail preview: the snapshot's own capacity,
  -- clamped 1..32 and RAISED to the highest entry slot (a mismatched import
  -- must not hide an item).
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

  -- Carried coverage for the build-time tints, in two passes: items cover
  -- cells of their OWN container first, then leftovers spill to the other
  -- sections.
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
    -- missing (red) = NOTHING covers the want: absent from the bank, or
    -- only a zero-unit placeholder. partial (orange) = some of it exists,
    -- bank or carried, but not enough. hasStack stays out of it - a
    -- placeholder cell still claims its child for geometry and clicks,
    -- but zero withdrawable units is a miss, not a partial.
    -- Only label a shortfall the player cannot already infer: "-1" on a
    -- unique piece of gear is pure noise (need 1 can never be partial).
    c.missing = c.short >= (c.need or 1)
    c.partial = c.short > 0 and not c.missing
    if (c.missing or c.partial) and c.need > 1 then c.shortfall = c.short end
    c.shortBank, c.short = nil, nil
  end

  -- live-layer lookups, built once per model:
  -- equipment objs wear on left-click (gear and backpack stay segregated:
  -- withdrawing gear into a full backpack could deadlock)
  local equipObjs = {}
  for _, e in ipairs(preset.equipment or {}) do equipObjs[e.obj] = true end
  -- claim-time units: the satisfied-"0" display fudge compares against the
  -- bank as it stood at build
  local claimQty = {}
  for _, c in ipairs(cells) do
    if c.srcObj ~= nil then claimQty[c.srcObj] = bank[c.srcObj].units or 0 end
  end
  -- satisfaction allocates by SNAPSHOT obj across ALL of its cells,
  -- including unclaimable ones. Cell array order IS the allocation
  -- priority: equipment, backpack slots ascending, BoB.
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

-- ---- live satisfaction --------------------------------------------------------

-- How many units a cell still wants: a TOP-UP counter against LIVE
-- inventory. Satisfaction is what the player HOLDS NOW, plus unconfirmed
-- clicks (`pending[srcObj] = { amount, tick }`).
--
-- CONTAINER-AWARE: a carried unit satisfies its OWN container's cells first
-- (BoB food counts down the BoB cell, not the backpack's), then leftovers -
-- and pending - spill to the obj's remaining cells in order (equipment,
-- backpack ascending, BoB), so an item wanted in the backpack but currently
-- worn still satisfies.
P.CellRemaining = function(model, c, carried, pending)
  local cells = (model.liveCells or {})[c.obj]
  if cells == nil then return c.need end
  -- Cells whose claimed/backed stack has EMPTIED (engine-set c.claimGone)
  -- absorb coverage FIRST: they can never be withdrawn from, so carried
  -- units must satisfy them ahead of live-backed cells.
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
  -- Unconfirmed clicks are DIRECTED at the section that was clicked
  -- (p.bySect, written at booking): a BoB-cell withdraw must dim the BoB
  -- cell at once, never count down the backpack's copy of the same item.
  -- Tags are capped by the live amount (drop-side reconciles shrink amount
  -- only); any untagged remainder joins the spill pool like carried
  -- leftovers do.
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

-- Settles pending click predictions against fresh bank counts: a confirmed
-- drop consumes its prediction, and stale ones expire. Mutates `pending`
-- in place.
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

-- The ARRIVAL-side reconcile, for the Core engine: a prediction is consumed
-- as its units turn up in the CARRIED counts, at the snapshot obj it serves
-- (`p.snap`, recorded when the click was booked; the pending key - the bank
-- stack's obj - is the fallback).
P.ReconcileArrivals = function(pending, oldCarried, freshCarried, nowTick, ttl)
  ttl = ttl or P.PENDING_TTL
  for key, p in pairs(pending) do
    local obj = p.snap or key
    -- PER-CONTAINER rises, not the total, and a rise's container IS the
    -- section tag it confirms: matching tag first, then any other.
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

-- Effective carried counts for BUILD-TIME tints: carried plus in-flight
-- clicks. In-flight units fold into the container their section tag maps
-- to, so the build's own-container pass credits the right cell; untagged
-- remainders fold into the backpack pool and reach other sections through
-- the spill pass. Returns fresh tables; inputs untouched.
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

-- ---- side-panel slot comparison -------------------------------------------
-- Compares one preset section against the live contents of its inventory,
-- per slot, for the discrepancy overlay on the bank's own side panels.
--   entries  = the section's snapshot entries ({slot, obj, count, ...})
--   held     = { [slot] = { obj, count } } from the live inventory
--   capacity = the panel's slot count (slots past it are ignored)
--   positional = the wrong-slot guide setting:
--     ON  -> strict per-slot states plus ONE purple pair: the misplaced
--            item in the LOWEST slot whose obj is wanted, unsatisfied, at
--            another slot. Returns states, { from, to }.
--     OFF -> position-insensitive: green stays positional (the slot holds
--            its own item), but problems are allocation-based - an item
--            held ANYWHERE in the section covers its want, and red means
--            genuinely not held. Returns states, nil.
-- States: "ok" (green) / "under" (short of the wanted quantity - orange:
-- the player will run out) / "over" (right item, more than wanted -
-- yellow: harmless) / "wrong" (different item in a wanted slot - red,
-- positional only) / "missing" (want unmet - red; the renderer adds the
-- expected-item ghost when the slot is BLANK). Unwanted slots are never
-- marked - they can only be the purple pair's source.
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

  -- lenient: items in their OWN slots allocate first, so a correct slot
  -- cannot be "stolen" by an earlier want; leftovers cover remaining
  -- wants in slot order
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
        heldTotal[w.obj] = avail - w.count -- covered elsewhere: no mark
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

-- ---- op choice ----------------------------------------------------------------
-- Classifies a component's op names into the map ChooseOp consumes.
-- `list` = { { idx = <0-based op index>, name = <op name> }, ... }
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

-- The left-click default for a cell's stack:
--   satisfied  -> Examine, so a stray click cannot overshoot (covers
--                 equipment - wearing a second copy - and uniques too)
--   equipment  -> Wear
--   stacked    -> largest Withdraw-N <= remaining; Withdraw-All when the
--                 need covers the live stack or beats BULK_ALL_ABOVE
--   otherwise  -> nil (leave the native default alone)
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

-- ---- badge rules ---------------------------------------------------------------
-- What a cell's quantity display should read. Returns qty, alwaysShow,
-- satisfied. A stacked cell counts DOWN its remaining need and shows even
-- a "1", since it is a withdraw count; once satisfied the number goes away
-- rather than rendering "0" - unless counting down meant something (the
-- bank held a stack, or the preset wanted several), where "0" reads as done.
--   banked = claim-time units for the cell's srcObj (model.claimQty)
P.Badge = function(c, rem, exactView, banked)
  local always = rem > 0
    and (c.need > 1 or (c.stacked and not exactView and not c.doll))
  local satisfied = rem <= 0
  local qty = rem
  if satisfied and c.need <= 1 and ((banked or 0) <= 1 or exactView or c.doll) then
    qty = 1 -- MULTIPLE display mode hides a quantity of 1 natively
  end
  return qty, always, satisfied
end

-- Thousand-form notation for counts: 1000, 5000, 10.2k, 100k, 2000k, 10m,
-- 1000m, 10b. Units switch at 10 of the next unit up; one truncated
-- decimal below 100 of a unit, dropped when it is .0.
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
