-- Shared UI plumbing, served to every ui/ module:
--   * interface sounds, silenced as one by the sfx setting
--   * the per-window delayed tooltip and the instant blocked-action hint
--   * the single Logic-tick heartbeat that drives all time-based UI
--   * PrettyUI chrome repairs: title centring, drag-handle insets,
--     satellite placement, the search field's clear button
--   * the name-search matcher both list surfaces share
--   * the bank-engine reads both engines share: obj names, bank
--     components, op lists, the smallest available body font
local M = {}

-- ---- interface sounds ---------------------------------------------------

M.BLOCKED_SFX = 29596 -- refused action
M.CLICK_SFX = 36961 -- standard button
M.DROP_SFX = 4174 -- confirmed drag-and-drop or "Move to"

-- Plays a sound unless the user has silenced the plugin's audio.
M.PlaySfx = function(sfxId)
  if PersistentDB:GetBool("ui.sfxOff") == true then return end
  pcall(function()
    local sp = audio.SoundPlaybackParams.new()
    sp.type = audio.SoundType.SCRIPT
    sp.audioBus = audio.AudioBus.SFX
    audio.Play(sfxId, sp)
  end)
end

-- Plays one of a set at random, as the client's own variant sets do.
M.PlayRandomSfx = function(set)
  M.PlaySfx(set[math.random(#set)])
end

-- ---- Logic-tick heartbeat -------------------------------------------------
-- One Event.Logic subscription drives every time-based UI concern. Tickers
-- are named, so re-registering a name replaces it rather than stacking.
local tick = 0
local tickers = {}

-- Shared timebase, in ticks (~50/s).
M.Now = function()
  return tick
end

M.AddTicker = function(name, fn)
  tickers[name] = fn
end

-- ---- shared delayed tooltip ------------------------------------------------
-- One Tooltip per window content, retargeted and retexted per button after a
-- hover dwell, rather than one tooltip per button.
local TIP_DELAY_TICKS = 40 -- ~0.8s dwell before a tooltip shows
M.TIP_BLOCKED_TICKS = 100 -- ~2s on screen for "can't do that" popups

local sharedTips = {} -- keyed by window content
local pendingTip = nil -- { comp, text, parent, at }
local tipExpireAt = nil -- tick to auto-hide an instant tooltip
local defaultTipParent = nil -- used when a call site passes no parent

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
        onMouseOver = function() end, -- we drive Show/Hide ourselves
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

-- A tooltip that appears at once and dismisses itself: the blocked-action
-- hint, where a dwell delay would mean the user never sees why.
M.ShowInstantTip = function(component, text, parent, expireTicks)
  showTipFor(component, text, parent)
  if expireTicks then tipExpireAt = tick + expireTicks end
end

-- Attaches hover handling to a component.
--   parentContent - the window content the COMPONENT lives in
--   text          - a string, or a function returning (text, opts), where
--                   opts = { instant = bool, expire = ticks }
--   onOver/onLeave - optional extra hover behaviour
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

-- Destroys the pooled tooltips on window teardown; the pool refills lazily.
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
    M.HideTip() -- clears tipExpireAt itself
  end
  for _, fn in pairs(tickers) do pcall(fn) end
end)

M.Shutdown = function()
  M.HideTip()
  pcall(function() Event.Logic.Unsubscribe("pvUikitTick") end)
end

-- ---- PrettyUI window-chrome repairs -----------------------------------------
local TITLE_H = 32 -- PrettyUI Window title-bar height

-- Re-spans a window title symmetrically.
M.CentreTitle = function(w)
  pcall(function()
    w.titleText:SetPos(48, 2)
    w.titleText:SetSize(-96, TITLE_H - 4, 1.0)
  end)
end

-- Re-syncs a PrettyUI window's invisible title-drag layer after a move.
M.SyncWindowChrome = function(w)
  pcall(function() w:SetSize(w.root.width, w.root.height) end)
end

-- Places a satellite window (icon picker, share, import) on open.
-- Standalone re-anchors to its owner window every open; integrated
-- (BankUtils column) places it at defX/defY ONCE and afterwards leaves it
-- wherever the user dragged it. st is the caller's per-window state table.
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

-- A 16px clear ("x") icon for a search field: hidden while the field is
-- empty, lit variant on hover, click hands control to the caller's onClear.
-- The caller positions it inside the field's right edge and drives
-- SetVisible from the field's onChange.
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
        spr.spriteID = CLEAR_REST -- never reopen stuck on the hover art
      end
    end,
  }
end

local TITLE_DRAG_RIGHT = 34 -- PrettyUI's own CLOSE_SIZE (20) + 14

-- Clears `insetLeft` px at the left end of a window's title bar so a button
-- there stays clickable. Must be called every tick, not once.
M.ApplyTitleInset = function(w, insetLeft)
  if w == nil or w.root == nil or w.titleDrag == nil then return end
  -- Mid-drag the handle is expanded over the whole screen so a fast cursor
  -- cannot escape it; touching it then would kill the drag.
  if w.dragFeedback ~= nil then return end
  pcall(function()
    if w.root.hidden == true then return end
    w.titleDrag:SetPos((w.root.x or 0) + insetLeft, w.root.y or 0)
    w.titleDrag:SetSize(
      (w.root.width or 0) - insetLeft - TITLE_DRAG_RIGHT, TITLE_H)
  end)
end

-- Case-insensitive name filter: plain substring, or an anchored wildcard
-- pattern when the query holds "*". An empty query matches everything.
M.MatchesSearch = function(name, query)
  if query == nil or query == "" then return true end
  local n, q = string.lower(name or ""), string.lower(query)
  if string.find(q, "*", 1, true) == nil then
    return string.find(n, q, 1, true) ~= nil
  end
  local pat = "^" .. q:gsub("[%^%$%(%)%%%.%[%]%+%-%?]", "%%%1"):gsub("%*", ".*") .. "$"
  return string.find(n, pat) ~= nil
end

-- ---- shared bank-engine plumbing --------------------------------------------

-- An obj id's display name from the client's config, or nil when it cannot
-- be resolved.
M.ObjName = function(objId)
  local n = nil
  pcall(function() n = config.Obj.FromID(objId).name end)
  return n
end

-- A component of the bank interface (517) by static id, or nil.
M.BankComponent = function(staticId)
  local c = nil
  pcall(function()
    c = ui.Interfaces:GetComponent(517 * 65536 + staticId)
  end)
  return c
end

-- A component's op names as { { idx, name }, ... }.
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

-- Smallest available body font and its line height, probed once.
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

-- Points a PrettyUI SpriteButton at raw sprite ids. With no `active` art,
-- the hover state is emulated by brightening a dimmed idle.
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
    -- With real hover art, _pvActive holds that art instead of a brightness
    -- lift, so the button still reads "on" while its thing is open.
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
