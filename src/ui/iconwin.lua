-- The icon picker window: a skill-icon grid and a custom sprite-id page.
-- ui/pvwin configures it through M.Configure; this module must never
-- require ui/pvwin back.
local M = {}

local store = require("core/store")
local uikit = require("ui/uikit")
local bankutil = require("core/bankutil")

local playSfx = uikit.PlaySfx
local centreTitle, syncWindowChrome = uikit.CentreTitle, uikit.SyncWindowChrome

local ICON_SWAP_SFX = 60742
local CLICK_SFX = uikit.CLICK_SFX

local BORDER, TITLE_H = 8, 32

-- { host, relayout() }
local ctx = nil
M.Configure = function(c)
  ctx = c
end

-- Most of these sprite ids are unnamed, so none can be looked up by enum.
local SKILLS = {
  { "Attack", 197 }, { "Strength", 198 }, { "Defence", 199 },
  { "Constitution", 203 }, { "Ranged", 200 }, { "Magic", 202 },
  { "Prayer", 201 }, { "Necromancy", 30934 }, { "Summoning", 222 },
  { "Agility", 204 }, { "Herblore", 205 }, { "Thieving", 206 },
  { "Crafting", 207 }, { "Fletching", 208 }, { "Slayer", 216 },
  { "Mining", 209 }, { "Smithing", 210 }, { "Fishing", 211 },
  { "Cooking", 212 }, { "Firemaking", 213 }, { "Woodcutting", 214 },
  { "Farming", 217 }, { "Runecrafting", 215 }, { "Hunter", 220 },
  { "Construction", 221 }, { "Dungeoneering", 3028 }, { "Divination", 9170 },
  { "Invention", 26541 }, { "Archaeology", 10782 },
}

local picker
local pickerApply = nil

local function ensurePicker()
  if picker then return end
  local COLS_P, CELL_P = 6, 36
  local PX, PY = 8, 6
  local rows = math.ceil((#SKILLS + 1) / COLS_P) -- +1: the no-icon cell
  local pw = COLS_P * CELL_P + BORDER * 2 + 16
  local ph = TITLE_H + PY + 10 + rows * CELL_P + 34 + BORDER

  picker = { win = prettyui.Window.new(ctx.host, {
    categoryID = "auto",
    title = "Preset icon",
    x = 400, y = 200,
    width = pw, height = ph,
    minWidth = pw, minHeight = 120,
    scrollable = false,
  }) }
  centreTitle(picker.win)
  local body = picker.win.content

  local HL_PAD = 3
  local highlight = ui.Sprite.new(body)
  highlight:SetSize(CELL_P - 4 + HL_PAD * 2, CELL_P - 4 + HL_PAD * 2)
  highlight.spriteID = 18828
  highlight.clickthrough = true
  highlight.hidden = true
  -- A cell's leave event can arrive after the next cell's hover.
  local hlOwner = nil

  -- Picking closes the window under the pointer, so ONMOUSELEAVE never fires
  -- for the picked cell; the highlight has to be cleared by hand.
  picker.ClearHighlight = function()
    hlOwner = nil
    highlight.hidden = true
  end

  local function pick(iconId)
    local ok, err = pcall(function()
      if pickerApply then pickerApply(iconId) end
      playSfx(ICON_SWAP_SFX)
      picker.ClearHighlight()
      picker.win:Close()
      ctx.relayout()
    end)
    if not ok then log(formatStr("[PV] icon pick failed: {}", tostring(err))) end
  end

  local gridParts, customParts = {}, {}

  -- The final cell (icon = nil) clears the icon.
  local cells = {}
  for i, skill in ipairs(SKILLS) do
    cells[i] = { sprite = skill[2], icon = skill[2] }
  end
  cells[#cells + 1] = { sprite = 9134, icon = nil }

  for i, cell in ipairs(cells) do
    local col = (i - 1) % COLS_P
    local row = math.floor((i - 1) / COLS_P)
    local cx = PX + col * CELL_P + 2
    local cy = PY + 4 + row * CELL_P + 2
    local spr = ui.Sprite.new(body)
    spr:SetPos(cx + 1, cy + 1)
    spr:SetSize(28, 28)
    spr.spriteID = cell.sprite
    spr:Subscribe(ui.Hook.ONCLICK, function() pick(cell.icon) end)
    spr:Subscribe(ui.Hook.ONMOUSEOVER, function()
      hlOwner = i
      highlight:SetPos(cx - HL_PAD - 1, cy - HL_PAD - 1)
      highlight.hidden = false
      pcall(function() highlight:MoveToFront() end)
    end)
    spr:Subscribe(ui.Hook.ONMOUSELEAVE, function()
      if hlOwner == i then
        hlOwner = nil
        highlight.hidden = true
      end
    end)
    gridParts[#gridParts + 1] = spr
  end

  local rowY = PY + 8 + rows * CELL_P
  local bodyW = pw - BORDER * 2

  -- The typed sprite id, or nil when it is not safe to draw. Everything that
  -- reaches a sprite goes through store.CleanIcon: some ids crash the client.
  local customField, customPreview
  local function typedId()
    local n = nil
    pcall(function() n = store.CleanIcon(customField:GetText()) end)
    return n
  end

  local customLabel = ui.Text.new(body)
  customLabel:SetPos(PX, PY + 2)
  customLabel:SetSize(bodyW - PX * 2, 16)
  customLabel.font = id.Font.MUSEO_SANS_15PT_REGULAR
  customLabel.rgba = 0xE7D7B0FF
  customLabel.content = "Type a sprite ID"
  customLabel.clickthrough = true
  customParts[#customParts + 1] = customLabel

  customField = prettyui.TextField.new(body, {
    x = PX, y = PY + 24,
    width = bodyW - PX * 2,
    maxLength = 10, -- int32 max is 10 digits
    onChange = function()
      pcall(function()
        local id = typedId()
        if id ~= nil then
          customPreview.spriteID = id
          customPreview.hidden = false
        else
          customPreview.hidden = true
        end
      end)
    end,
  })
  customParts[#customParts + 1] = customField.root

  local fieldBottom = PY + 24 + 30
  local bx = math.floor((bodyW - 38) / 2)
  local by = fieldBottom + math.floor((rowY - fieldBottom - 38) / 2)
  local previewSlot = ui.Sprite.new(body)
  previewSlot:SetPos(bx, by)
  previewSlot:SetSize(38, 38)
  previewSlot.spriteID = 26558
  previewSlot.clickthrough = true
  customParts[#customParts + 1] = previewSlot
  customPreview = ui.Sprite.new(body)
  customPreview:SetPos(bx + 5, by + 5)
  customPreview:SetSize(28, 28)
  customPreview.clickthrough = true
  customPreview.hidden = true

  -- true = the custom page, false = the grid
  picker.SetMode = function(customMode)
    picker.ClearHighlight()
    for _, c in ipairs(gridParts) do c.hidden = customMode end
    for _, c in ipairs(customParts) do c.hidden = not customMode end
    customPreview.hidden = true
    pcall(function() customField:SetText("") end)
    pcall(function() picker.win:SetTitle(customMode and "Custom sprite"
      or picker.gridTitle or "Preset icon") end)
  end

  local customBtn = prettyui.SimpleButton.new(body, "Custom", function()
    playSfx(CLICK_SFX)
    local okC, errC = pcall(function() picker.SetMode(true) end)
    if not okC then log(formatStr("[PV] custom page failed: {}", tostring(errC))) end
  end, { x = PX + 2, y = rowY, height = 24 })
  gridParts[#gridParts + 1] = customBtn.root

  local backBtn = prettyui.SimpleButton.new(body, "Back", function()
    playSfx(CLICK_SFX)
    local okB, errB = pcall(function() picker.SetMode(false) end)
    if not okB then log(formatStr("[PV] custom back failed: {}", tostring(errB))) end
  end, { x = PX + 2, y = rowY, height = 24 })
  customParts[#customParts + 1] = backBtn.root
  local setW = prettyui.FancyButton.getSize("Set Icon")
  local setBtn = prettyui.FancyButton.new(body, "Set Icon", function()
    local okS, errS = pcall(function()
      local iconId = typedId()
      if iconId == nil then
        uikit.PlaySfx(uikit.BLOCKED_SFX)
        return
      end
      pick(iconId)
    end)
    if not okS then log(formatStr("[PV] custom icon failed: {}", tostring(errS))) end
  end, {
    x = pw - BORDER * 2 - PX - setW, y = rowY - 2,
    variant = "positive",
  })
  customParts[#customParts + 1] = setBtn.root

  picker.SetMode(false)
end

local pickerPlace = {}
-- `apply` receives the picked sprite id, or nil for the "no icon" cell;
-- x, y are the owner window's position.
M.Open = function(apply, title, x, y)
  ensurePicker()
  pickerApply = apply
  picker.gridTitle = title or "Preset icon"
  picker.SetMode(false)
  picker.ClearHighlight()
  uikit.PlaceSatellite(picker.win, pickerPlace, bankutil.HasColumn(),
    (x or 300) + 30, (y or 160) + 30, 330, 190)
  syncWindowChrome(picker.win)
  picker.win:Show()
end

M.OpenForPreset = function(preset, x, y)
  M.Open(function(iconId)
    store.SetIcon(preset.id, iconId)
    preset.icon = iconId
  end, "Preset icon", x, y)
end

M.OpenForCategory = function(name, x, y)
  M.Open(function(iconId)
    store.SetCategoryIcon(name, iconId)
  end, "Category icon", x, y)
end

M.Close = function()
  if picker then pcall(function() picker.win:Close() end) end
end

M.Window = function()
  return picker and picker.win or nil
end

M.Destroy = function()
  if picker then
    pcall(function() picker.win:Destroy() end)
    picker = nil
    pickerApply = nil
  end
end

return M
