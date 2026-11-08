# Preset Vault - code overview

An unlimited gear/inventory preset manager. A preset is a snapshot of worn
equipment, backpack and, when one is carrying, Beast of Burden contents.
The headline feature filters the open bank down to a preset's items as
natively clickable slots - the plugin displays and organises; every
withdrawal is the player's own click.

## Layout

- `main.lua` - entry point: lifecycle, event wiring, window visibility.
- `core/` - data and logic, no drawing. The pure modules touch no game
  globals, so they can be tested outside the client.
- `ui/` - everything that draws.

## core/

| File | Responsibility |
|---|---|
| `snapshot.lua` | Captures worn + backpack + BoB into a preset; familiar capacity read from game config. |
| `store.lua` | All vault persistence: presets, categories and their icons, manual ordering; selects which vault key is in use. |
| `identity.lua` | Character identity via `Player.GetTrackingID()` for per-character vaults; permission and resolve states. |
| `sharecode.lua` | Share-code codec (`PV1-` base64), encode and decode. Pure. |
| `presetview.lua` | The bank-view model both engines consume: geometry, cell building, live top-up satisfaction, the one-click op ladder, badge rules. Pure. |
| `invread.lua` | Inventory readers: totals, per-container carried counts, per-slot contents. |
| `bankutil.lua` | Bank Utils Core connection lifecycle and view control when that plugin is present. |

## ui/

| File | Responsibility |
|---|---|
| `uikit.lua` | Shared plumbing: sounds, tooltips, the single Logic-tick heartbeat, window chrome helpers, the name-search matcher, and the bank-engine reads both engines share. |
| `pvwin.lua` | The main vault window: preset list, categories, search, drag-and-drop. Configures and orchestrates the satellite windows. |
| `detailwin.lua` | The preset detail window: name field, worn doll, backpack/BoB grid, title-bar share button. |
| `iconwin.lua` | The icon picker window: skill-icon grid plus the custom sprite-id page. |
| `sharewin.lua` | The Share Code and Import Code windows. |
| `settings.lua` | The tabbed settings panel. |
| `ribbon.lua` | The ribbon quick-access panel. |
| `bankpage.lua` | The bank preset view, standalone engine: draws the preset over the bank and parks a real bank child under the hovered cell, so clicks, menus and tooltips stay native. |
| `bupage.lua` | The same view rendered through Bank Utils Core's custom-view system when integration is active. |
| `bucolumn.lua` | The Bank Utils Core sidebar column - the in-bank vault UI while integrated. |
| `overlay.lua` | Discrepancy overlay on the bank's own side panels: per-slot status colours against the active preset. |

## How it hangs together

- **Saving**: `pvwin`/`bucolumn` → `snapshot` captures → `store` writes.
- **Storage**: `store` owns every read and write of vault data; `identity`
  decides which vault key it uses (shared, or one per character). Settings
  are plain PersistentDB flags (`ui.*`), written by `settings` and read live
  by whichever module they govern.
- **Bank view**: `presetview` computes everything; `bankpage` (standalone)
  or `bupage` (through Bank Utils Core) draws it. `bankutil` manages the
  Core connection and which engine owns the view; `bucolumn` is the
  in-bank preset list while integrated.
- **Overlay**: `overlay` compares the active preset against live
  inventories (`invread`) and paints the bank's own side panels.
- **Sharing**: `sharewin` is the UI; `sharecode` is the codec.
- `main.lua` wires events into all of the above; `uikit` serves every
  `ui/` module.

The plugin requests one optional permission, `trackingAccess`, used only
for per-character vaults. The tracking id is a local storage key - never
displayed, never written into a preset, never transmitted. The plugin
makes no network calls.

## AI usage
Claude Fable 5.1 was used in this project's phase workflows.
