-- The ribbon quick-access panel: one "Open vault window" button, or a notice
-- when the BankUtil sidebar owns the UI instead.
local M = {}

local window = require("ui/pvwin")
local bankutil = require("core/bankutil")

local ribbonView

M.Build = function(layerComponent)
  if ribbonView then
    pcall(function() ribbonView:Destroy() end)
    ribbonView = nil
  end
  local ok, err = pcall(function()
    local w = layerComponent.width or 400
    local h = layerComponent.height or 300
    local view = prettyui.SimpleView.new(layerComponent,
      { width = w, height = h, categoryID = "auto" })
    view:AddTitle("Preset Vault")
    if bankutil.HasColumn() then
      view:AddText({ text = "BankUtils (Bankcore) integration is on.",
        colour = 0xB8A169CC })
      view:AddText({ text = "Manage presets in the bank's sidebar.",
        colour = 0xB8A169CC })
    else
      view:AddFancyButton("Open", function()
        pcall(window.ForceOpen)
      end, { variant = "positive" })
    end
    ribbonView = view
  end)
  if not ok then log(formatStr("[PV] ribbon build failed: {}", tostring(err))) end
end

return M
