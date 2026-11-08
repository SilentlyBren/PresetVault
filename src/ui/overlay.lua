-- Discrepancy overlay: while a preset's bank view is on, washes each slot of
-- the bank's own side panels (Backpack / Worn / Beast of Burden) with its
-- status against that preset.
--   green  = right item, right quantity
--   yellow = right item, MORE than wanted (harmless overage)
--   orange = under-supplied: short of the wanted quantity, in place or
--            (guide off) short across the whole section - will run out
--   red    = want unmet; a BLANK slot with an unmet or short want also
--            draws a ghost of the expected item, an occupied wrong-item
--            slot gets the wash alone
--   purple = right item, wrong slot - one misplaced item at a time gets the
--            wash, its destination slot a border
--
-- Active only while a view is on, for whichever engine owns it.
local M = {}

local P = require("core/presetview")
local invread = require("core/invread")
local uikit = require("ui/uikit")
local bankpage = require("ui/bankpage")
local bankutil = require("core/bankutil")

-- Washes reuse the bank view's exact tints so the two surfaces read as one
-- system; green/purple are overlay-only (same ~28% alpha convention).
local OK_GREEN = 0x28A03C42
local PURPLE_TINT = 0x9440C86E
local PURPLE_BORDER = 0xC878F0FF
local BORDER_T = 2
local GHOST_ALPHA = 0.35

--   slots     - the static whose children give per-slot geometry
--   art       - where the item art box sits inside a slot child, for
--               placing ghosts
--   artStatic - the layer whose children draw the native slot art
--   minSlots  - chrome is not created until the pool has this many
--               children
local PANELS = {
  { key = "backpack", slots = 14, inv = 93, minSlots = 28,
    art = { dx = 4, dy = 2, w = 36, h = 32 },
    section = function(p) return p.backpack end },
  { key = "worn", slots = 27, inv = 94, artStatic = 28, minSlots = 19,
    -- the worn panel's art box sits one pixel in from the backpack's
    art = { dx = 3, dy = 3, w = 32, h = 30 },
    -- Equipment slots are typed, so an item can never be wrong-slot: the
    -- purple guide scan is skipped on this panel regardless of the setting.
    noGuide = true,
    section = function(p) return p.equipment end },
  { key = "bob", slots = 34, inv = 530, minSlots = 1,
    art = { dx = 4, dy = 2, w = 36, h = 32 },
    section = function(p) return (p.bob ~= nil) and p.bob.items or nil end },
}

-- Per bank session, per panel: { canvas, ghosts, ownIds, hidden }.
-- `hidden` holds native art children we hid behind a ghost, to restore.
local chrome = {}
local tickCount = 0
local forceTicks = 0
local lastSig = nil -- redraw only when the computed picture changes
local anythingShown = false

local comp = uikit.BankComponent

-- The preset being compared: the loaded bank view's, from whichever engine
-- owns it. nil = overlay off or no view on.
local function activePreset()
  if PersistentDB:GetBool("ui.overlayOff") == true then return nil end
  local p = bankpage.activePreset
  if p ~= nil then return p end
  return bankutil.ActivePreset() -- internally guarded against a stale Core
end

local readHeld = invread.Slots

local function ensureChrome(key, host)
  local c = chrome[key]
  if c ~= nil then return c end
  c = { ghosts = {}, ownIds = {}, hidden = {} }
  local ok = pcall(function()
    c.canvas = ui.Canvas.new(host)
    c.canvas:SetPos(0, 0)
    c.canvas.clickthrough = true
    pcall(function() c.ownIds[c.canvas.dynamicID] = true end)
  end)
  if not ok then return nil end
  chrome[key] = c
  return c
end

local function ensureGhost(c, i, host)
  local g = c.ghosts[i]
  if g ~= nil then return g end
  local ok = pcall(function()
    g = ui.Sprite.new(host)
    g.clickthrough = true
    g.hidden = true
    pcall(function() g.alpha = GHOST_ALPHA end)
    pcall(function()
      g.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.NEVER
    end)
    pcall(function() c.ownIds[g.dynamicID] = true end)
  end)
  if not ok then return nil end
  c.ghosts[i] = g
  return g
end

-- Wipes one panel's drawn state and restores every native art child it hid.
local function clearPanel(c)
  pcall(function() c.canvas:Clear() end)
  for _, g in ipairs(c.ghosts) do
    pcall(function() g.hidden = true end)
  end
  for s, child in pairs(c.hidden) do
    pcall(function() child.hidden = false end)
    c.hidden[s] = nil
  end
end

-- Hide everything (no view, bank closed, panel has no section). Components
-- are kept - they are per-bank-session and a hidden panel costs nothing.
local function clear()
  if not anythingShown then return end
  anythingShown = false
  lastSig = nil
  for _, c in pairs(chrome) do clearPanel(c) end
end

local function render(panel, host, preset, entries, guideOn)
  -- Geometry FIRST, chrome second: our components may only be created once
  -- the pool's full native set exists, so their dynamicIDs land past the
  -- native range.
  local c = chrome[panel.key]
  local geom, capacity = {}, 0
  pcall(function()
    host:IterateDynamicComponents(function(child)
      pcall(function()
        local d = child.dynamicID
        if c ~= nil and c.ownIds[d] then return end
        geom[d + 1] = { x = child.x, y = child.y,
          w = child.width or 0, h = child.height or 0 }
        if d + 1 > capacity then capacity = d + 1 end
      end)
    end)
  end)
  if capacity < (panel.minSlots or 1) then
    -- unbuilt or mid-rebuild: draw nothing and forget the picture, so the
    -- next complete read redraws fresh
    if c ~= nil then clearPanel(c) end
    lastSig = nil
    return
  end
  c = ensureChrome(panel.key, host)
  if c == nil then return end

  local held = readHeld(panel.inv)
  local states, purple = P.CompareSlots(entries, held, capacity, guideOn)

  -- redraw only when the picture changes (holdings, states, purple pair,
  -- capacity, panel, preset or the guide setting)
  local parts = { panel.key, tostring(preset.id), tostring(guideOn),
    tostring(capacity) }
  for s = 1, capacity do
    local h = held[s]
    parts[#parts + 1] = (states[s] or "-") .. (h ~= nil
      and (tostring(h.obj) .. "x" .. tostring(h.count)) or "b")
  end
  if purple ~= nil then
    parts[#parts + 1] = purple.from .. ">" .. purple.to
  end
  local sig = table.concat(parts, "|")
  if sig == lastSig then
    -- unchanged picture - just re-assert the ghost-slot hides, since the
    -- client's own panel refreshes un-hide its art children
    for _, child in pairs(c.hidden) do
      pcall(function() child.hidden = true end)
    end
    return
  end

  lastSig = sig
  anythingShown = true
  -- one visible panel at a time, but a tab switch must not leave the OLD
  -- panel's chrome drawn for when the player switches back to stale state
  for key, other in pairs(chrome) do
    if key ~= panel.key then clearPanel(other) end
  end

  local wantObj = {}
  for _, e in ipairs(entries) do
    local s = tonumber(e.slot)
    if s ~= nil and wantObj[s] == nil then wantObj[s] = e.obj end
  end

  pcall(function()
    c.canvas:SetPos(0, 0)
    c.canvas:SetSize(host.width, host.height)
    c.canvas:Clear()
    local ghostIdx = 0
    local ghosted = {} -- slots whose native art makes way for a ghost
    for s = 1, capacity do
      local g = geom[s]
      if g ~= nil and g.w > 0 and g.h > 0 then
        local st = states[s]
        local colour = nil
        if purple ~= nil and purple.from == s then
          colour = PURPLE_TINT -- the misplaced item itself
        elseif st == "ok" then
          colour = OK_GREEN
        elseif st == "under" then
          colour = P.UNDER_ORANGE
        elseif st == "over" then
          colour = P.PART_YELLOW
        elseif st == "wrong" or st == "missing" then
          colour = P.MISS_RED
        end
        if colour ~= nil then
          c.canvas:AddRectangle(g.x, g.y, g.w, g.h, colour)
        end
        if purple ~= nil and purple.to == s then
          -- destination: border only, so the ghost/own state stays legible
          c.canvas:AddRectangle(g.x, g.y, g.w, BORDER_T, PURPLE_BORDER)
          c.canvas:AddRectangle(g.x, g.y + g.h - BORDER_T, g.w, BORDER_T,
            PURPLE_BORDER)
          c.canvas:AddRectangle(g.x, g.y, BORDER_T, g.h, PURPLE_BORDER)
          c.canvas:AddRectangle(g.x + g.w - BORDER_T, g.y, BORDER_T, g.h,
            PURPLE_BORDER)
        end
        -- expected-item ghost on BLANK wanted slots only; covers both an
        -- unmet want and a blank slot whose want is short section-wide
        if (st == "missing" or st == "under")
          and held[s] == nil and wantObj[s] ~= nil then
          ghostIdx = ghostIdx + 1
          local gh = ensureGhost(c, ghostIdx, host)
          if gh ~= nil then
            pcall(function()
              gh:SetPos(g.x + panel.art.dx, g.y + panel.art.dy)
              gh:SetSize(panel.art.w, panel.art.h)
              gh:SetAssociatedObject(wantObj[s])
              gh.hidden = false
            end)
            ghosted[s] = true
          end
        end
      end
    end
    for i = ghostIdx + 1, #c.ghosts do
      pcall(function() c.ghosts[i].hidden = true end)
    end
    -- Hide the native glyph for exactly the ghosted slots, and restore any
    -- slot that stopped being ghosted.
    if panel.artStatic ~= nil then
      local artHost = comp(panel.artStatic)
      if artHost ~= nil then
        local artKids = {}
        pcall(function()
          artHost:IterateDynamicComponents(function(child)
            pcall(function() artKids[child.dynamicID + 1] = child end)
          end)
        end)
        for s, child in pairs(c.hidden) do
          if not ghosted[s] then
            pcall(function() child.hidden = false end)
            c.hidden[s] = nil
          end
        end
        for s in pairs(ghosted) do
          local child = artKids[s]
          if child ~= nil then
            pcall(function() child.hidden = true end)
            c.hidden[s] = child
          end
        end
      end
    end
    pcall(function() c.canvas:MoveToFront() end)
    for i = 1, ghostIdx do
      pcall(function() c.ghosts[i]:MoveToFront() end)
    end
  end)
end

-- ---- cadence ------------------------------------------------------------------
-- A settle pass every 5 ticks, pulled forward to 3 after an inventory
-- event. The tick only recomputes; an unchanged signature draws nothing.
local function onTick()
  pcall(function()
    tickCount = tickCount + 1
    local due = forceTicks > 0 or tickCount % 5 == 0
    if forceTicks > 0 then forceTicks = forceTicks - 1 end
    if not due then return end
    local preset = activePreset()
    if preset == nil then
      clear()
      return
    end
    local panel, host = nil, nil
    for _, p in ipairs(PANELS) do
      local c = comp(p.slots)
      local vis = false
      pcall(function() vis = c ~= nil and c.visibleGlobal == true end)
      if vis then
        panel, host = p, c
        break
      end
    end
    if panel == nil then
      clear()
      return
    end
    local entries = panel.section(preset)
    if entries == nil or #entries == 0 then
      clear()
      return
    end
    local guideOn = panel.noGuide ~= true
      and PersistentDB:GetBool("ui.wrongSlotOff") ~= true
    render(panel, host, preset, entries, guideOn)
  end)
end

M.Init = function()
  Event.Logic.Subscribe("pvOvTick", onTick)
  pcall(function()
    Event.InventoryUpdated.Subscribe("pvOvInv", function(ev)
      pcall(function()
        if ev.inv == nil then return end
        local iid = ev.inv.id
        if iid == 93 or iid == 94 or iid == 95 or iid == 530 then
          forceTicks = 3
        end
      end)
    end)
  end)
end

-- Drops all per-session chrome. Called by main.lua on bank close and at
-- shutdown.
M.DestroyChrome = function()
  for _, c in pairs(chrome) do
    pcall(function() c.canvas:Destroy() end)
    for _, g in ipairs(c.ghosts) do
      pcall(function() g:Destroy() end)
    end
    -- un-hide any native art we were masking (post-close these handles
    -- are detached and the writes are harmless no-ops)
    for _, child in pairs(c.hidden) do
      pcall(function() child.hidden = false end)
    end
  end
  chrome = {}
  lastSig = nil
  anythingShown = false
end

M.Shutdown = function()
  pcall(function() Event.Logic.Unsubscribe("pvOvTick") end)
  pcall(function() Event.InventoryUpdated.Unsubscribe("pvOvInv") end)
  M.DestroyChrome()
end

return M
