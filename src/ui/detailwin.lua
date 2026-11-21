-- The preset detail window: one preset's name, icon, worn doll and backpack
-- or Beast of Burden grid. ui/pvwin configures it through M.Configure; this
-- module must never require ui/pvwin back.
local M = {}

local store = require("core/store")
local uikit = require("ui/uikit")
local sharewin = require("ui/sharewin")
local iconwin = require("ui/iconwin")

local playSfx = uikit.PlaySfx
local centreTitle, syncWindowChrome = uikit.CentreTitle, uikit.SyncWindowChrome
local setButtonSprites = uikit.SetButtonSprites
local attachDelayedTooltip = uikit.AttachDelayedTooltip
local CLICK_SFX = uikit.CLICK_SFX

local BORDER, TITLE_H = 8, 32
local DETAIL_W = 324
local SLOT = 42

local TITLE_BTN_SIZE = 24
local TITLE_BTN_X, TITLE_BTN_Y = 8, 4
local TITLE_DRAG_INSET = TITLE_BTN_X + TITLE_BTN_SIZE + 4
local SHARE_SPRITE, SHARE_SPRITE_HOVER = 26769, 26770

-- { host, anchor(), relayout(), onClosed(), renameRow(id, name) };
-- anchor returns x, y or nil.
local ctx = nil
M.Configure = function(c)
  ctx = c
end

local detail
local detailPreset = nil

-- Called from onClose and from M.Hide; both are needed, because hiding an
-- already hidden window fires no onClose.
local function closeChildren()
  iconwin.Close()
  pcall(sharewin.CloseShare)
end

-- Every tick: PrettyUI resets its title drag handle from closures that
-- cannot be hooked, and the handle swallows clicks on the share button.
uikit.AddTicker("pvDetailTitleInset", function()
  if detail ~= nil and detail.shareBtn ~= nil then
    uikit.ApplyTitleInset(detail.win, TITLE_DRAG_INSET)
  end
end)

-- Must stay declared above makeDetailSlot, which reads them as upvalues.
local WORN_SLOT = 40
local WORN_ICON_W, WORN_ICON_H = 32, 32
local WORN_ICON_DX, WORN_ICON_DY = 4, 4
local SLOT_BG_SPRITE = prettyui.Sprites.ITEM_SLOT_BACKGROUND

local function detailSlotHover(slot, body)
  slot.bg.clickthrough = false
  attachDelayedTooltip(slot.bg, function()
    local e = slot.entry
    if e == nil then return nil end
    if (e.count or 1) > 1 then return formatStr("{} x{}", e.name, e.count) end
    return e.name
  end, body)
end

local function makeDetailSlot(body, x, y, placeholderSprite, box, iw, ih, dx, dy)
  box = box or WORN_SLOT
  iw, ih = iw or WORN_ICON_W, ih or WORN_ICON_H
  dx, dy = dx or WORN_ICON_DX, dy or WORN_ICON_DY
  local slot = {}
  slot.bg = ui.Sprite.new(body)
  slot.bg:SetPos(x, y)
  slot.bg:SetSize(box, box)
  slot.bg.spriteID = SLOT_BG_SPRITE
  if placeholderSprite then
    slot.ph = ui.Sprite.new(body)
    slot.ph:SetPos(x + dx, y + dy)
    slot.ph:SetSize(iw, ih)
    slot.ph.spriteID = placeholderSprite
    slot.ph.clickthrough = true
    pcall(function() slot.ph.alpha = 0.6 end)
  end
  slot.item = ui.Sprite.new(body)
  slot.item:SetPos(x + dx, y + dy)
  slot.item:SetSize(iw, ih)
  slot.item.clickthrough = true
  slot.item.hidden = true
  detailSlotHover(slot, body)
  return slot
end

local function setDetailSlot(slot, entry)
  slot.entry = entry
  if slot.ph then slot.ph.hidden = entry ~= nil end
  if entry then
    slot.item.hidden = false
    pcall(function()
      slot.item:SetAssociatedObject(entry.obj)
      slot.item.associatedObjectQuantity = entry.count
      slot.item.associatedObjectQuantityMode = ui.ObjectQuantityDisplayMode.MULTIPLE
    end)
  else
    slot.item.hidden = true
  end
end

-- The 32 pooled slots serve both views: Backpack shows 28, a Beast of
-- Burden view shows preset.bob.size.
local function applyDetailContainer()
  if detail == nil or detailPreset == nil then return end
  local bob = detailPreset.bob
  local showBob = detail.showBob == true and bob ~= nil
  local entries = showBob and bob.items or detailPreset.backpack
  local visCount = 28
  if showBob then
    local n = math.floor(tonumber(bob.size) or 32)
    if n < 1 then n = 1 end
    if n > 32 then n = 32 end
    visCount = n
  end
  local bySlot = {}
  for _, e in ipairs(entries or {}) do
    bySlot[e.slot] = e
  end
  for i = 1, 32 do
    local slot = detail.packSlots[i]
    if i <= visCount then
      slot.bg.hidden = false
      setDetailSlot(slot, bySlot[i])
    else
      slot.bg.hidden = true
      slot.item.hidden = true
      slot.entry = nil
    end
  end
  pcall(function()
    detail.packLabel.content = showBob and "Beast of Burden" or "Backpack"
    local b = detail.bobBtn
    b.bg.hidden = bob == nil
    b.icon.hidden = bob == nil
    b.ring.hidden = bob == nil or not showBob
  end)
  pcall(function()
    local py = detail.PY or 6
    local rows = (visCount > 28) and 5 or 4
    local slotsBottom = py + 320 + (rows - 1) * SLOT + 40
    detail.win:SetSize(DETAIL_W, TITLE_H + slotsBottom + 12 + BORDER)
    centreTitle(detail.win)
  end)
end

local WGAP = 6
local WCOLGAP = 6
local WPITCH = WORN_SLOT + WGAP
local WNEAR, WFAR = WORN_SLOT + WCOLGAP, WORN_SLOT + 28
local WCOL = { c = 0, nl = -WNEAR, nr = WNEAR, fl = -WFAR, fr = WFAR }
local WROW = { 0, WPITCH, WPITCH * 2, WPITCH * 3, WPITCH * 4 }
-- idx is the engine slot index; x and y are relative to DOLL_X / DOLL_Y.
-- Placeholder sprites are pinned by number: their enum names register only
-- once the worn assets load, and resolve to -1 before that.
local WORN_LAYOUT = {
  { idx = 1, x = WCOL.c, y = WROW[1], ph = 24431 },   -- head
  { idx = 18, x = WCOL.nr, y = WROW[1], ph = 24443 }, -- pouch
  { idx = 2, x = WCOL.nl, y = WROW[2], ph = 24432 },  -- cape
  { idx = 3, x = WCOL.c, y = WROW[2], ph = 24433 },   -- neck
  { idx = 14, x = WCOL.nr, y = WROW[2], ph = 24441 }, -- ammo
  { idx = 4, x = WCOL.fl, y = WROW[3], ph = 24434 },  -- main hand
  { idx = 5, x = WCOL.c, y = WROW[3], ph = 24436 },   -- body
  { idx = 6, x = WCOL.fr, y = WROW[3], ph = 24437 },  -- off hand
  { idx = 8, x = WCOL.c, y = WROW[4], ph = 24438 },   -- legs
  { idx = 10, x = WCOL.fl, y = WROW[5], ph = 24439 }, -- gloves
  { idx = 11, x = WCOL.c, y = WROW[5], ph = 24440 },  -- boots
  { idx = 13, x = WCOL.fr, y = WROW[5], ph = 24435 }, -- ring
}

-- { x, y, w, h, sprite }, x relative to the centre column's left edge.
local WORN_CONNECTORS = {}
do
  local T = 10
  local mid = (WORN_SLOT - T) // 2
  for r = 1, 4 do
    WORN_CONNECTORS[#WORN_CONNECTORS + 1] =
      { mid, WROW[r] + WORN_SLOT, T, WGAP, 29316 }
  end
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] =
    { -WCOLGAP, WROW[2] + mid, WCOLGAP, T, 29313 }
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] =
    { WORN_SLOT, WROW[2] + mid, WCOLGAP, T, 29313 }
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] =
    { -(WFAR - WORN_SLOT), WROW[3] + mid, WFAR - WORN_SLOT, T, 29313 }
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] =
    { WORN_SLOT, WROW[3] + mid, WFAR - WORN_SLOT, T, 29313 }
  local runY, runH = WROW[3] + WORN_SLOT, WROW[5] - (WROW[3] + WORN_SLOT)
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] = { WCOL.fl + mid, runY, T, runH, 29316 }
  WORN_CONNECTORS[#WORN_CONNECTORS + 1] = { WCOL.fr + mid, runY, T, runH, 29316 }
end
local DOLL_X = 8 + (7 * SLOT) // 2 - WORN_SLOT // 2
local DOLL_Y = 54

local function ensureDetail()
  if detail then return end
  local PX, PY = 8, 6
  local ok, err = pcall(function()
    local w = prettyui.Window.new(ctx.host, {
      categoryID = "auto",
      title = "Preset",
      x = 460, y = 140,
      width = DETAIL_W,
      height = TITLE_H + 504 + BORDER,
      minWidth = DETAIL_W, minHeight = 160,
      scrollable = false,
      onClose = function()
        detailPreset = nil
        closeChildren()
        ctx.onClosed()
      end,
    })
    centreTitle(w)
    local body = w.content
    local fieldW = 266

    detail = { win = w, wornSlots = {}, packSlots = {}, showBob = false, PX = PX, PY = PY }

    detail.nameField = prettyui.TextField.new(body, {
      x = PX, y = PY + 2,
      width = fieldW,
      maxLength = 25,
      placeholder = "Preset name",
      onChange = function(_, _, content)
        local okR, errR = pcall(function()
          if not detailPreset then return end
          local name = store.CleanName(content)
          if name ~= content then detail.nameField:SetText(name) end
          if name == "" then name = "Untitled" end
          store.Rename(detailPreset.id, name)
          detailPreset.name = name
          detail.win:SetTitle(name)
          ctx.renameRow(detailPreset.id, name)
        end)
        if not okR then log(formatStr("[PV] rename failed: {}", tostring(errR))) end
      end,
      onSubmit = function()
        ctx.relayout()
      end,
    })

    local swapBtn = prettyui.SpriteButton.new(body, "SWAP", function()
      playSfx(CLICK_SFX)
      local okP, errP = pcall(function()
        if detailPreset then
          iconwin.OpenForPreset(detailPreset, detail.win.root.x, detail.win.root.y)
        end
      end)
      if not okP then log(formatStr("[PV] icon picker failed: {}", tostring(errP))) end
    end, { x = PX + fieldW + 3, y = PY + 3, size = 28 })
    setButtonSprites(swapBtn, 36153)
    attachDelayedTooltip(swapBtn.root, "Choose a skill icon for this preset", body)

    prettyui.Text.new(body, { text = "Worn", x = PX, y = PY + 40, height = 16 })
    -- created before the slots so the slot art draws over the line ends
    for _, c in ipairs(WORN_CONNECTORS) do
      local line = ui.Sprite.new(body)
      line:SetPos(DOLL_X + c[1], DOLL_Y + c[2])
      line:SetSize(c[3], c[4])
      line.spriteID = c[5]
      pcall(function() line.alpha = 0.5 end)
      line.clickthrough = true
    end
    for _, spec in ipairs(WORN_LAYOUT) do
      detail.wornSlots[spec.idx] =
        makeDetailSlot(body, DOLL_X + spec.x, DOLL_Y + spec.y, spec.ph,
          WORN_SLOT, WORN_ICON_W, WORN_ICON_H, WORN_ICON_DX + 1, WORN_ICON_DY + 1)
    end

    detail.packLabel = prettyui.Text.new(body, { text = "Backpack", x = PX, y = PY + 300, height = 16 })
    local BOB_SIZE, BOB_RING = 30, 38
    local bx = PX + 7 * SLOT - 6 - BOB_SIZE
    local by = PY + 289
    local function mkBobSprite(spriteId, x, y, size, clickthrough)
      local s = ui.Sprite.new(body)
      s:SetPos(x, y)
      s:SetSize(size, size)
      s.spriteID = spriteId
      s.clickthrough = clickthrough
      s.hidden = true
      return s
    end
    local bob = {}
    bob.ring = mkBobSprite(9805, bx - (BOB_RING - BOB_SIZE) / 2,
      by - (BOB_RING - BOB_SIZE) / 2, BOB_RING, true)
    bob.bg = mkBobSprite(18621, bx, by, BOB_SIZE, true)
    bob.icon = mkBobSprite(18855, bx, by, BOB_SIZE, false)
    bob.icon:Subscribe(ui.Hook.ONCLICK, function()
      playSfx(CLICK_SFX)
      local okT, errT = pcall(function()
        detail.showBob = not detail.showBob
        applyDetailContainer()
      end)
      if not okT then log(formatStr("[PV] bob toggle failed: {}", tostring(errT))) end
    end)
    -- hover art rides the tooltip's subscription: a second subscription on
    -- the same hook is unreliable
    attachDelayedTooltip(bob.icon, function()
      return detail.showBob and "Show backpack" or "Show Beast of Burden"
    end, body,
      function() pcall(function() bob.icon.spriteID = 18856 end) end,
      function() pcall(function() bob.icon.spriteID = 18855 end) end)
    detail.bobBtn = bob

    for i = 1, 32 do
      local col = (i - 1) % 7
      local row = math.floor((i - 1) / 7)
      detail.packSlots[i] = makeDetailSlot(body, PX + col * SLOT, PY + 320 + row * SLOT,
        nil, nil, nil, nil, WORN_ICON_DX + 1, WORN_ICON_DY + 1)
      if i > 28 then
        detail.packSlots[i].bg.hidden = true
      end
    end

    -- On the window root, not the content: content is clipped to its own
    -- bounds and cannot reach the title bar. prettyui.NewComponent exists
    -- from PrettyUI 1.3; ui.Sprite.new is the fallback for 1.2.
    detail.shareBtn = prettyui.NewComponent
        and prettyui.NewComponent(ui.Sprite, w.root)
        or ui.Sprite.new(w.root)
    detail.shareBtn:SetPos(TITLE_BTN_X, TITLE_BTN_Y)
    detail.shareBtn:SetSize(TITLE_BTN_SIZE, TITLE_BTN_SIZE)
    detail.shareBtn.spriteID = SHARE_SPRITE
    -- must be set explicitly, or the hover and click hooks never fire
    detail.shareBtn.clickthrough = false
    attachDelayedTooltip(detail.shareBtn, "Share this preset as a code", body,
      function()
        pcall(function() detail.shareBtn.spriteID = SHARE_SPRITE_HOVER end)
      end,
      function()
        pcall(function() detail.shareBtn.spriteID = SHARE_SPRITE end)
      end)
    detail.shareBtn:Subscribe(ui.Hook.ONCLICK, function()
      playSfx(CLICK_SFX)
      local okS, errS = pcall(function()
        if detailPreset then sharewin.OpenShare(detailPreset) end
      end)
      if not okS then log(formatStr("[PV] share failed: {}", tostring(errS))) end
      return false
    end)
    detail.shareBtn:MoveToFront()
  end)
  if not ok then
    log(formatStr("[PV] detail build failed: {}", tostring(err)))
    detail = nil
  end
end

M.Hide = function()
  if detail and detail.win.root and not detail.win.root.hidden then
    pcall(function() detail.win:Close() end)
  end
  detailPreset = nil
  closeChildren()
end

M.Show = function(preset)
  ensureDetail()
  if not detail then return end
  local ok, err = pcall(function()
    detailPreset = preset
    detail.win:SetTitle(preset.name)
    detail.nameField:SetText(preset.name)
    local byIdx = {}
    for _, e in ipairs(preset.equipment) do
      byIdx[e.slot] = e
    end
    for _, spec in ipairs(WORN_LAYOUT) do
      setDetailSlot(detail.wornSlots[spec.idx], byIdx[spec.idx])
    end
    detail.showBob = false
    applyDetailContainer()
    local ax, ay = ctx.anchor()
    if ax then detail.win.root:SetPos(ax, ay) end
    syncWindowChrome(detail.win)
    detail.win:Show()
  end)
  if not ok then log(formatStr("[PV] detail show failed: {}", tostring(err))) end
end

M.Window = function()
  return detail and detail.win or nil
end

-- x, y, or nothing when the window has never been built.
M.Position = function()
  if detail then return detail.win.root.x, detail.win.root.y end
end

M.Destroy = function()
  if detail then
    pcall(function() detail.win:Destroy() end)
    detail = nil
    detailPreset = nil
  end
end

return M
