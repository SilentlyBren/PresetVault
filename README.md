# Preset Vault

Preset Vault saves unlimited gear and inventory presets and filters your open
bank down to one preset's items as native, clickable slots. A preset is a
snapshot of your worn equipment, backpack and, when you are carrying one, your
Beast of Burden. The plugin displays and organises your bank; every withdrawal
is still your own click.

Ever taken a screenshot of a preset because you didn't want to lose it? That is
the problem this solves.

## Features

- Unlimited presets, saved in one click.
- Each preset captures worn equipment, backpack and Beast of Burden contents.
- Filtered bank view: a preset's items laid out as a familiar equipment doll
  and backpack grid, with every slot clickable.
- Live top-up counter that ticks off what you still need as you withdraw.
- Categories, skill icons and drag-to-arrange ordering.
- Share presets with anyone by copy-and-paste code.
- Discrepancy overlay that colours the bank's own side panels by slot status.
- Optional per-character vaults for shared machines or multiple characters.

## Install

Enable **PrettyUI** and **Preset Vault** in your client's plugin manager.
PrettyUI is required; Preset Vault will not load without it.

Manual installation, create a `PresetVault` folder in your client's
development plugins directory and copy `main.lua`, `plugin.json`, `core/` and
`ui/` from this repository into it:

```text
plugins/
  PresetVault/
    main.lua
    plugin.json
    core/
    ui/
```

Install PrettyUI separately. No build step is needed.

## Vault away

1. Open the vault from the plugin's ribbon icon.
2. Click **Save preset** to capture what you are currently wearing and carrying.
3. Give the preset a name, and optionally a category and a skill icon.
4. Open your bank and select a preset to filter the bank down to its items.
5. Withdraw with the bank's normal clicks and menus. The counter tracks what is
   still outstanding.
6. Click a native bank tab to return to the normal bank view.

Drag presets to reorder them, or lock them to alphabetical order in the
settings. The bank view rearranges how your items are shown; it does not create
items or add bank storage.

To share a preset, open it and use the share button in its title bar. Anyone can
paste the resulting code into their own Import Code window.

## Settings / Troubleshoot

The settings panel has four tabs: **General**, **Interface**, **Permissions**
and **Danger Zone**. Interface covers categories, icon alignment, alphabetical
locking, the discrepancy overlay, the wrong-slot guide, exact preset layout in
the bank and an option to disable interface sounds. Danger Zone holds the full
reset, which clears every character's vault and restores defaults.

- **Nothing appears:** check that PrettyUI is enabled, then reload the plugin.
- **The bank view will not open:** select the bank's native All Items tab and
  try again.
- **Multi-character vaults are greyed out:** they need the `trackingAccess`
  permission. Grant it in the plugin's permissions, then return to the tab.
- **A problem after reloading:** reload PrettyUI, then Preset Vault. Keep your
  saved plugin data while investigating.

## Bank Utils Core integration

Preset Vault can render its preset list and bank view through
[Bank Utils Core](https://github.com/RS3-Dev/bank-utils-core) instead of its own
windows, which keeps everything inside the bank window alongside other bank
plugins. The integration is optional and off unless Core is detected; enable it
on the Interface tab. Preset Vault's dedicated windows are hidden while it is
on, and all features remain available.

## Permissions and data

Preset Vault requests one **optional** permission, `trackingAccess`, used only
to tell your characters apart for per-character vaults. It is not required, can
be toggled freely, and with it off every character on the device shares a single
vault. The tracking id is a local storage key: never displayed, never written
into a preset, never transmitted.

Everything is stored locally through the client's plugin storage: preset
snapshots (slot positions, item ids, item names and quantities), your preset
names, categories and chosen icons, and, with multi-character vaults enabled,
your display name and tracking id. None of this data leaves your computer, and
uninstalling or resetting the plugin loses it. Preset Vault requests no HTTP
permission and makes no network requests.

## Code layout

- `main.lua` - entry point: lifecycle, event wiring, window visibility.
- `core/` - data and logic, no drawing. The pure modules touch no game globals,
  so they can be tested outside the client.
- `ui/` - everything that draws.

`PresetVault/overview.md` documents each module and how they fit together.

## License

Copyright (c) 2026 SilentlyBren. Licensed under the
[BSD 2-Clause License](LICENSE) (`BSD-2-Clause`). Include the license when
redistributing.

This plugin uses software licensed by Jagex to the developer under the terms of
the Jagex End User Licence Agreement (EULA) found at
<https://legal.jagex.com/docs/terms/eula> (and all terms incorporated into it by
reference). The development and any use of the plugin is at all times subject to
the Jagex EULA.
