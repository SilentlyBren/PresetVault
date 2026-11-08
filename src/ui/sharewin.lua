-- The two sharing windows: Share Code (export) and Import Code. The codec
-- itself is core/sharecode.
--
-- pvwin.lua requires this module and injects what it owns through
-- M.Configure: host layer, window positions, relayout, collapse-key helper.
local M = {}

local sharecode = require("core/sharecode")
local store = require("core/store")
local uikit = require("ui/uikit")
local bankutil = require("core/bankutil")

local IMPORT_SFX = 31899

local BORDER, TITLE_H = 8, 32 -- PrettyUI Window chrome metrics

-- Injected by pvwin.lua (see header): { host, shareAnchor(), importAnchor(),
-- relayout(), expandUncat() }. Anchor functions return x, y or nil.
local ctx = nil
M.Configure = function(c)
  ctx = c
end

-- uikit.PlaceSatellite state, one table per satellite window.
local sharePlace, importPlace = {}, {}

-- ---- share code window (persistent) -------------------------------------------
-- Shows one preset's share code in a box the player can copy out of but not
-- keep an edit to. Opened from the preset detail window's title bar.
--
-- The box is made read-only by HEALING: any edit is immediately rewritten
-- with the code.
local share -- { win, field, code }
local shareHealing = false -- re-entry guard for the self-healing field
local SHARE_W = 380

local function ensureShareWindow()
  if share then return end
  local PX, PY = 8, 6
  local ok, err = pcall(function()
    local w = prettyui.Window.new(ctx.host, {
      categoryID = "auto",
      title = "Share Code",
      x = 480, y = 260,
      width = SHARE_W,
      height = TITLE_H + 70 + BORDER,
      minWidth = SHARE_W, minHeight = 100,
      scrollable = false,
    })
    uikit.CentreTitle(w)
    local body = w.content
    share = { win = w, code = "" }

    prettyui.Text.new(body, {
      text = "Sharing code for this preset (Ctrl-A + Ctrl-C)",
      x = PX, y = PY + 2, height = 16,
    })

    share.field = prettyui.TextField.new(body, {
      x = PX, y = PY + 24,
      width = SHARE_W - BORDER * 2 - PX * 2,
      maxLength = 2048,
      onChange = function()
        -- Re-entry guard: the heal below writes the field, which can fire
        -- this handler again.
        if shareHealing then return end
        shareHealing = true
        pcall(function()
          if share.field:GetText() ~= share.code then
            share.field:SetText(share.code)
            uikit.PlaySfx(uikit.BLOCKED_SFX)
          end
        end)
        shareHealing = false
      end,
    })
  end)
  if not ok then
    log(formatStr("[PV] share window build failed: {}", tostring(err)))
    share = nil
  end
end

M.OpenShare = function(preset)
  if ctx == nil then return end
  ensureShareWindow()
  if not share then return end
  local ok, err = pcall(function()
    shareHealing = true
    local code, codeErr = sharecode.Encode(preset)
    if code == nil then
      uikit.PlaySfx(uikit.BLOCKED_SFX)
      share.code = ""
      share.field:SetText("")
      share.field:SetPlaceholder("Cannot share: " .. tostring(codeErr))
    else
      -- Handed over wrapped in backticks.
      share.code = sharecode.Wrap(code)
      share.field:SetPlaceholder("")
      share.field:SetText(share.code)
    end
    local ax, ay = ctx.shareAnchor()
    uikit.PlaceSatellite(share.win, sharePlace, bankutil.HasColumn(),
      (ax or 400) + 28, (ay or 200) + 52, 428, 252)
    uikit.SyncWindowChrome(share.win)
    share.win:Show()
  end)
  -- Cleared OUTSIDE the pcall: left stuck true by an error on the way
  -- through, the field would quietly stop healing and become editable.
  shareHealing = false
  if not ok then log(formatStr("[PV] share open failed: {}", tostring(err))) end
end

M.CloseShare = function()
  if share then pcall(function() share.win:Close() end) end
end

-- ---- import code window (persistent) ------------------------------------------
-- Paste a code, get a preset in this vault. Nothing is written until a whole
-- preset has decoded cleanly, so a bad code cannot leave a half-import.
local importWin -- { win, field, status }
local IMPORT_W = 330
-- The last content we know about, plus a guard for our own writes.
local importLastText = ""
local importSuppress = false

local function setImportStatus(text, bad)
  if importWin == nil or importWin.status == nil then return end
  pcall(function()
    importWin.status.content = text or ""
    importWin.status.rgba = bad and 0xFF6060FF or 0x9FD98FFF
  end)
end

-- Writes the code box without the write looking like a player edit, keeping
-- importLastText in step.
local function setImportText(s)
  if importWin == nil or importWin.field == nil then return end
  importSuppress = true
  pcall(function() importWin.field:SetText(s or "") end)
  importLastText = s or ""
  importSuppress = false
end

-- Resets the window to blank.
local function resetImportWindow()
  if importWin == nil then return end
  setImportText("")
  setImportStatus("")
end

local function ensureImportWindow()
  if importWin then return end
  local PX, PY = 8, 6
  local ok, err = pcall(function()
    local w = prettyui.Window.new(ctx.host, {
      categoryID = "auto",
      title = "Import Code",
      x = 480, y = 300,
      width = IMPORT_W,
      height = TITLE_H + 118 + BORDER,
      minWidth = IMPORT_W, minHeight = 120,
      scrollable = false,
      onClose = function() pcall(resetImportWindow) end,
    })
    uikit.CentreTitle(w)
    local body = w.content
    importWin = { win = w }

    prettyui.Text.new(body, {
      text = "Paste a preset code", x = PX, y = PY + 2, height = 16,
    })

    importWin.field = prettyui.TextField.new(body, {
      x = PX, y = PY + 24,
      width = IMPORT_W - BORDER * 2 - PX * 2,
      maxLength = 2048,
      placeholder = "PV1-...",
      -- Clears a stale result as soon as the box is EDITED, gated on the
      -- content actually differing.
      onChange = function(f)
        if importSuppress then return end
        local now = ""
        pcall(function() now = f:GetText() or "" end)
        if now == importLastText then return end
        importLastText = now
        setImportStatus("")
      end,
    })

    importWin.status = prettyui.Text.new(body, {
      text = "", x = PX, y = PY + 58, height = 16,
    })

    local importW = prettyui.FancyButton.getSize("Import")
    prettyui.FancyButton.new(body, "Import", function()
      local okI, errI = pcall(function()
        local raw = importWin.field:GetText()
        local preset, decodeErr = sharecode.Decode(raw, function(obj)
          local name = uikit.ObjName(obj)
          if name == nil then return nil end
          return tostring(name)
        end)
        if preset == nil then
          uikit.PlaySfx(uikit.BLOCKED_SFX)
          -- The specific reason goes to the console; the status line stays
          -- terse.
          log(formatStr("[PV] import rejected: {}", tostring(decodeErr)))
          setImportStatus("Invalid share code", true)
          return
        end
        local stored = store.Import(preset)
        if stored == nil then
          -- A locked vault is NOT an invalid code, and says so separately.
          uikit.PlaySfx(uikit.BLOCKED_SFX)
          setImportStatus("Cannot import - vault locked", true)
          return
        end
        -- Box cleared BEFORE the status is set, via setImportText.
        setImportText("")
        uikit.PlaySfx(IMPORT_SFX)
        setImportStatus("Import success", false)
        -- The detail lives in the console, where it costs no layout.
        local n = #(stored.equipment or {}) + #(stored.backpack or {})
        if stored.bob ~= nil then n = n + #(stored.bob.items or {}) end
        log(formatStr("[PV] imported '{}' ({} items)", stored.name, n))
        -- An import always lands in Uncategorised (codes carry no
        -- category); expand it so the arrival is visible, as Save does.
        ctx.expandUncat()
        ctx.relayout()
      end)
      if not okI then
        log(formatStr("[PV] import failed: {}", tostring(errI)))
        setImportStatus("Import failed - see console", true)
      end
    end, {
      x = IMPORT_W - BORDER * 2 - PX - importW, y = PY + 78,
      variant = "positive",
    })
  end)
  if not ok then
    log(formatStr("[PV] import window build failed: {}", tostring(err)))
    importWin = nil
  end
end

M.CloseImport = function()
  if importWin ~= nil then pcall(function() importWin.win:Close() end) end
end

M.OpenImport = function()
  if ctx == nil then return end
  ensureImportWindow()
  if not importWin then return end
  pcall(function()
    setImportStatus("")
    local ax, ay = ctx.importAnchor()
    uikit.PlaceSatellite(importWin.win, importPlace, bankutil.HasColumn(),
      (ax or 200) + 40, (ay or 140) + 60, 240, 200)
    uikit.SyncWindowChrome(importWin.win)
    importWin.win:Show()
  end)
end

-- The share and import window handles, two values, either possibly nil
-- (never built) - for the vault window's edit-mode occlusion guard.
M.Windows = function()
  return share and share.win, importWin and importWin.win
end

return M
