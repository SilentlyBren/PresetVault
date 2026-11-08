-- The icon picker window: one persistent window, two modes - the skill-icon
-- grid, and a "custom" page where any sprite id can be typed with a live
-- preview. The Custom/Back buttons swap the window's content in place.
--
-- pvwin.lua requires this module and injects what it owns through
-- M.Configure: host layer and relayout. Callers supply their own anchor
-- coordinates, so this module knows nothing about the windows it serves.
local M = {}

local store = require("core/store")
local uikit = require("ui/uikit")
local bankutil = require("core/bankutil")

local playSfx = uikit.PlaySfx
local centreTitle, syncWindowChrome = uikit.CentreTitle, uikit.SyncWindowChrome

local ICON_SWAP_SFX = 60742 -- plays when an icon is picked (incl. "No icon")

local BORDER, TITLE_H = 8, 32 -- PrettyUI Window chrome metrics

-- Injected by pvwin.lua (see header): { host, relayout() }.
local ctx = nil
M.Configure = function(c)
  ctx = c
end

-- Skill icons assignable to presets: the coloured 25px set the Skills panel
-- itself uses.
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

-- The share format's icon ceiling (sharecode's MAX_ICON): int32 max.
local MAX_CUSTOM_ICON = 0x7FFFFFFF

local picker -- { win } the picker window, built once
local pickerApply = nil -- the commit callback (receives icon id or nil)

local function ensurePicker()
  if picker then return end
  local COLS_P, CELL_P = 6, 36 -- cell pitch drives the window size too
  local PX, PY = 8, 6 -- inner content padding
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

  -- One shared hover highlight, layered ON TOP of the icons (some icons
  -- out-drew an underlay) and slightly oversized so it reads as a glow.
  local HL_PAD = 3
  local highlight = ui.Sprite.new(body)
  highlight:SetSize(CELL_P - 4 + HL_PAD * 2, CELL_P - 4 + HL_PAD * 2)
  highlight.spriteID = 18828
  highlight.clickthrough = true
  highlight.hidden = true
  local hlOwner = nil -- which cell owns the highlight (leave events can
  -- arrive AFTER the next cell's hover when crossing adjacent cells)

  -- Clears the hover highlight by hand, and is exposed so M.Open can do the
  -- same defensively.
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

  -- Everything belongs to one of the two pages; SetMode swaps them.
  local gridParts, customParts = {}, {}

  -- Every skill icon, then one final cell (sprite 9134) that CLEARS the
  -- preset's icon - "no icon" is a grid choice like any other.
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
    spr:SetSize(28, 28) -- slightly over the 25px native art, matches the list icons
    spr.spriteID = cell.sprite
    spr:Subscribe(ui.Hook.ONCLICK, function() pick(cell.icon) end)
    spr:Subscribe(ui.Hook.ONMOUSEOVER, function()
      hlOwner = i
      -- the glow art sits 1px low/right of the icon it frames - nudged back
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

  -- ---- custom page: label, id box, centred preview, Back / Set Icon ----
  -- Accepts a plain integer sprite id within the shareable range, or nil.
  local customField, customPreview
  local function typedId()
    local n = nil
    pcall(function() n = tonumber(customField:GetText()) end)
    if n == nil or n ~= math.floor(n) or n < 0 or n > MAX_CUSTOM_ICON then
      return nil
    end
    return math.floor(n)
  end

  local customLabel = ui.Text.new(body)
  customLabel:SetPos(PX, PY + 2)
  customLabel:SetSize(bodyW - PX * 2, 16)
  customLabel.font = id.Font.MUSEO_SANS_15PT_REGULAR
  customLabel.rgba = 0xE7D7B0FF -- PrettyUI's default text colour, matching
  -- the share/import windows' help lines (prettyui text.lua)
  customLabel.content = "Type a sprite ID"
  customLabel.clickthrough = true
  customParts[#customParts + 1] = customLabel

  customField = prettyui.TextField.new(body, {
    x = PX, y = PY + 24,
    width = bodyW - PX * 2,
    maxLength = 10, -- MAX_CUSTOM_ICON (int32 max) is 10 digits
    -- Live preview: the sprite swaps in as the id is typed, and hides
    -- again the moment the box holds anything unusable.
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

  -- Preview slot: a 28px icon box on a slot sprite (backdrop and border in
  -- one), centred horizontally and centred vertically between the id box
  -- and the bottom button row.
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

  -- ---- mode switch ----
  -- true = the custom page; false = the grid. The custom page always
  -- arrives blank - a stale id would read as a suggestion.
  picker.SetMode = function(customMode)
    picker.ClearHighlight()
    for _, c in ipairs(gridParts) do c.hidden = customMode end
    for _, c in ipairs(customParts) do c.hidden = not customMode end
    customPreview.hidden = true
    pcall(function() customField:SetText("") end)
    -- the grid page is titled for whatever the picker is picking for
    pcall(function() picker.win:SetTitle(customMode and "Custom sprite"
      or picker.gridTitle or "Preset icon") end)
  end

  -- ---- bottom rows (one per page, same geometry) ----
  local customBtn = prettyui.SimpleButton.new(body, "Custom", function()
    local okC, errC = pcall(function() picker.SetMode(true) end)
    if not okC then log(formatStr("[PV] custom page failed: {}", tostring(errC))) end
  end, { x = PX + 2, y = rowY, height = 24 })
  gridParts[#gridParts + 1] = customBtn.root

  local backBtn = prettyui.SimpleButton.new(body, "Back", function()
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

  picker.SetMode(false) -- start on the grid
end

local pickerPlace = {} -- uikit.PlaceSatellite state
-- Opens the picker: `apply` receives the picked sprite id (nil = the "no
-- icon" cell), `title` names the grid page, x/y seed the placement.
M.Open = function(apply, title, x, y)
  ensurePicker()
  pickerApply = apply
  picker.gridTitle = title or "Preset icon"
  picker.SetMode(false) -- always open on the grid, custom page reset
  picker.ClearHighlight() -- never open showing a stale hover glow
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

-- The picker window (or nil), for pvwin's over-a-satellite hit tests.
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
