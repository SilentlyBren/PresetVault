-- Shared UI plumbing for every ui/ module: sounds, the per-window tooltip,
-- the single Logic-tick heartbeat, pointer scaling, PrettyUI chrome repairs
-- and the reads both bank engines share. Nothing here knows about presets.
local M = {}
local prefs = require("core/prefs")

M.BLOCKED_SFX = 29596
M.CLICK_SFX = 36961
M.DROP_SFX = 4174

M.PlaySfx = function(sfxId)
  if prefs.GetBool("ui.sfxOff") == true then return end
  pcall(function()
    local sp = audio.SoundPlaybackParams.new()
    sp.type = audio.SoundType.SCRIPT
    sp.audioBus = audio.AudioBus.SFX
    audio.Play(sfxId, sp)
  end)
end

M.PlayRandomSfx = function(set)
  M.PlaySfx(set[math.random(#set)])
end

local tick = 0
local tickers = {}

-- Ticks since load, about 50 a second.
M.Now = function()
  return tick
end

-- Registering an existing name replaces that ticker.
M.AddTicker = function(name, fn)
  tickers[name] = fn
end

local function interfaceScale()
  local scale = 1
  pcall(function()
    local pct = tonumber(game.options.InterfaceScale.setting) or 100
    if pct > 0 then scale = pct / 100 end
  end)
  return scale
end

local pointerScale = nil -- window pixels per interface unit
local pointerScaleFor = nil -- the Interface Scale it was measured at

-- x, y are a hook's component-relative coordinates. The component must be at
-- its laid-out geometry: one just moved or stretched reports a stale xyGlobal.
M.CalibratePointer = function(component, x, y)
  if type(x) ~= "number" or type(y) ~= "number" then return end
  local raw, origin = Mouse.GetPosition(), nil
  pcall(function() origin = component.xyGlobal end)
  if raw == nil or origin == nil then return end
  local ex, ey = origin.x + x, origin.y + y
  if ex < 32 or ey < 32 then return end
  local sx, sy = raw.x / ex, raw.y / ey
  if sx < 0.5 or sx > 4 or sy < 0.5 or sy > 4
    or math.abs(sx - sy) > math.max(sx, sy) * 0.1 then
    return
  end
  pointerScale = (ex >= ey) and sx or sy
  pointerScaleFor = interfaceScale()
end

-- The pointer in interface coordinates. Mouse.GetPosition() is in window
-- pixels, which match component x/y and xyGlobal only at 100% Interface Scale.
M.MousePos = function()
  local m = Mouse.GetPosition()
  if m == nil then return nil end
  local scale = interfaceScale()
  if pointerScale ~= nil and pointerScaleFor == scale then
    scale = pointerScale
  end
  return { x = m.x / scale, y = m.y / scale }
end

local reported = {}
M.ReportOnce = function(where, err)
  local key = where .. tostring(err)
  if reported[key] then return end
  reported[key] = true
  log(formatStr("[PV] {} failed: {}", where, tostring(err)))
end

local TIP_DELAY_TICKS = 40
M.TIP_BLOCKED_TICKS = 100

-- One Tooltip per window content: a tooltip reads its target's local
-- coordinates, so it must share the target's parent.
local sharedTips = {}
local pendingTip = nil -- { comp, text, parent, at }
local tipExpireAt = nil
local defaultTipParent = nil

M.SetDefaultTipParent = function(content)
  defaultTipParent = content
end

M.HideTip = function()
  pendingTip = nil
  tipExpireAt = nil
  for _, tip in pairs(sharedTips) do pcall(function() tip:Hide() end) end
end

local function showTipFor(component, text, parent)
  local ok, err = pcall(function()
    parent = parent or defaultTipParent
    if parent == nil then return end
    local tip = sharedTips[parent]
    if tip == nil then
      tip = prettyui.Tooltip.attach(component, parent, text, {
        onMouseOver = function() end, -- Show and Hide are driven from here
        onMouseLeave = function() end,
      })
      if tip == nil then return end
      sharedTips[parent] = tip
    end
    tip.target = component
    tip:SetText(text)
    tip:Show()
  end)
  if not ok then log(formatStr("[PV] tooltip failed: {}", tostring(err))) end
end

M.ShowInstantTip = function(component, text, parent, expireTicks)
  showTipFor(component, text, parent)
  if expireTicks then tipExpireAt = tick + expireTicks end
end

-- parentContent is the window content the component lives in. text is a
-- string, or a function returning (text, { instant = bool, expire = ticks }).
-- onOver/onLeave share this subscription: a second one on the hook is unreliable.
M.AttachDelayedTooltip = function(component, text, parentContent, onOver, onLeave)
  component:Subscribe(ui.Hook.ONMOUSEOVER, "pvTip", function()
    if onOver then pcall(onOver) end
    local t, opts = text, nil
    if type(text) == "function" then
      local okT, rt, ro = pcall(text)
      if not okT or rt == nil then return end
      t, opts = rt, ro
    end
    if opts and opts.instant then
      showTipFor(component, t, parentContent)
      if opts.expire then tipExpireAt = tick + opts.expire end
    else
      pendingTip = { comp = component, text = t, parent = parentContent,
        at = tick + TIP_DELAY_TICKS }
    end
  end)
  component:Subscribe(ui.Hook.ONMOUSELEAVE, "pvTip", function()
    if onLeave then pcall(onLeave) end
    M.HideTip()
  end)
end

M.DestroyTips = function()
  for _, tip in pairs(sharedTips) do
    pcall(function() tip:Destroy() end)
  end
  sharedTips = {}
  pendingTip = nil
  tipExpireAt = nil
end

Event.Logic.Subscribe("pvUikitTick", function()
  tick = tick + 1
  if pendingTip and tick >= pendingTip.at then
    local t = pendingTip
    pendingTip = nil
    showTipFor(t.comp, t.text, t.parent)
  end
  if tipExpireAt and tick >= tipExpireAt then
    M.HideTip()
  end
  for _, fn in pairs(tickers) do pcall(fn) end
end)

M.Shutdown = function()
  M.HideTip()
  pcall(function() Event.Logic.Unsubscribe("pvUikitTick") end)
end

local TITLE_H = 32 -- PrettyUI Window title-bar height

-- PrettyUI centres the title across an asymmetric span (12px left, 48px right).
M.CentreTitle = function(w)
  pcall(function()
    w.titleText:SetPos(48, 2)
    w.titleText:SetSize(-96, TITLE_H - 4, 1.0)
  end)
end

-- Call after moving w.root: the title-drag layer is parented outside the
-- window and stays behind, eating hover and clicks, until SetSize re-places it.
M.SyncWindowChrome = function(w)
  pcall(function() w:SetSize(w.root.width, w.root.height) end)
end

-- Standalone anchors the window at ax, ay on every open. Integrated places it
-- at defX, defY once and then leaves it where the user dragged it. st is the
-- caller's per-window state table.
M.PlaceSatellite = function(w, st, integrated, ax, ay, defX, defY)
  if integrated then
    if st.placed ~= true then
      w.root:SetPos(defX, defY)
      st.placed = true
    end
  else
    w.root:SetPos(ax, ay)
    st.placed = false
  end
end

-- The caller positions the returned root and drives SetVisible.
local CLEAR_REST = id.Sprite.RS3_ICON_CLEAR_16PX_0
local CLEAR_HOVER = id.Sprite.RS3_ICON_CLEAR_16PX_1
M.AttachClearButton = function(parent, onClear)
  local spr = ui.Sprite.new(parent)
  spr:SetSize(16, 16)
  spr.spriteID = CLEAR_REST
  spr.hidden = true
  spr:Subscribe(ui.Hook.ONMOUSEOVER, function() spr.spriteID = CLEAR_HOVER end)
  spr:Subscribe(ui.Hook.ONMOUSELEAVE, function() spr.spriteID = CLEAR_REST end)
  spr:Subscribe(ui.Hook.ONCLICK, function()
    local ok, err = pcall(onClear)
    if not ok then log(formatStr("[PV] search clear failed: {}", tostring(err))) end
  end)
  return {
    root = spr,
    SetVisible = function(v)
      spr.hidden = v ~= true
      if v == true then
        pcall(function() spr:MoveToFront() end)
      else
        spr.spriteID = CLEAR_REST -- or it reappears on the hover art
      end
    end,
  }
end

local TITLE_DRAG_RIGHT = 34 -- PrettyUI's CLOSE_SIZE (20) + 14

-- Keeps insetLeft px at the left of the title bar clear of the drag handle.
-- Call it every tick: PrettyUI resets the handle's geometry by itself.
M.ApplyTitleInset = function(w, insetLeft)
  if w == nil or w.root == nil or w.titleDrag == nil then return end
  -- mid-drag the handle covers the whole screen; resizing it kills the drag
  if w.dragFeedback ~= nil then return end
  pcall(function()
    if w.root.hidden == true then return end
    w.titleDrag:SetPos((w.root.x or 0) + insetLeft, w.root.y or 0)
    w.titleDrag:SetSize(
      (w.root.width or 0) - insetLeft - TITLE_DRAG_RIGHT, TITLE_H)
  end)
end

-- Case-insensitive substring match, or an anchored wildcard match when the
-- query holds "*". An empty query matches everything.
M.MatchesSearch = function(name, query)
  if query == nil or query == "" then return true end
  local n, q = string.lower(name or ""), string.lower(query)
  if string.find(q, "*", 1, true) == nil then
    return string.find(n, q, 1, true) ~= nil
  end
  local pat = "^" .. q:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*", ".*") .. "$"
  return string.find(n, pat) ~= nil
end

-- rows is { { id, y0, y1 }, ... } top to bottom, y in the same content space.
-- Returns { above, below, lineY }; above or below is nil at the ends, and the
-- result is nil when rows is empty.
M.GapAt = function(rows, y)
  if #rows == 0 then return nil end
  for i, r in ipairs(rows) do
    if y < (r.y0 + r.y1) / 2 then
      return { above = rows[i - 1], below = r, lineY = r.y0 }
    end
  end
  local last = rows[#rows]
  return { above = last, below = nil, lineY = last.y1 }
end

-- The id to hand store.ReorderPreset so movedId lands between aboveId and
-- belowId, or nil when it is already there. orderIdx is
-- store.PresetOrderIndex(): the side is decided on stored order, not screen order.
M.GapTarget = function(orderIdx, movedId, aboveId, belowId)
  local m = orderIdx[movedId]
  if m == nil then return nil end
  local a = aboveId ~= nil and orderIdx[aboveId] or nil
  local b = belowId ~= nil and orderIdx[belowId] or nil
  if a ~= nil and m < a then return aboveId end
  if b ~= nil and m > b then return belowId end
  return nil
end

-- Returns the raw name value, or nil when the id does not resolve.
M.ObjName = function(objId)
  local n = nil
  pcall(function() n = config.Obj.FromID(objId).name end)
  return n
end

-- staticId is a component of the bank interface (517).
M.BankComponent = function(staticId)
  local c = nil
  pcall(function()
    c = ui.Interfaces:GetComponent(517 * 65536 + staticId)
  end)
  return c
end

-- Returns { { idx, name }, ... }.
M.ReadOps = function(component)
  local list = {}
  pcall(function()
    local oc = component.opConfig
    local n = 10
    pcall(function() n = oc.numOpNames or 10 end)
    for i = 0, n do
      local nm = nil
      pcall(function() nm = oc:GetOpName(i) end)
      if nm ~= nil then list[#list + 1] = { idx = i, name = tostring(nm) } end
    end
  end)
  return list
end

-- Returns font, lineHeight. A missing font enum resolves to -1, not nil.
local smallFont = nil
M.SmallFont = function()
  if smallFont ~= nil then return smallFont.font, smallFont.h end
  smallFont = { font = id.Font.MUSEO_SANS_15PT_REGULAR, h = 14 }
  for _, nm in ipairs({ "MUSEO_SANS_11PT_REGULAR", "MUSEO_SANS_12PT_REGULAR",
    "MUSEO_SANS_13PT_REGULAR" }) do
    local f = nil
    pcall(function() f = id.Font[nm] end)
    if type(f) == "number" and f >= 0 then
      smallFont = { font = f, h = 12 }
      break
    end
  end
  return smallFont.font, smallFont.h
end

-- Points a PrettyUI SpriteButton at raw sprite ids, which its constructor
-- refuses. The caller sets btn._pvActive to hold the button in its lit state.
M.SetButtonSprites = function(btn, neutral, active)
  btn.sprites = { neutral = neutral, active = active or neutral }
  local base = btn._UpdateState
  if active == nil then
    btn._UpdateState = function(selfBtn)
      base(selfBtn)
      pcall(function()
        selfBtn.root.alpha =
          (selfBtn._pvActive or selfBtn.hovered or selfBtn.pressed) and 1.0 or 0.78
      end)
    end
  else
    btn._UpdateState = function(selfBtn)
      base(selfBtn)
      pcall(function()
        if selfBtn._pvActive and not selfBtn.disabled then
          selfBtn.root.spriteID = selfBtn.sprites.active
        end
      end)
    end
  end
  btn:_UpdateState()
end

return M
