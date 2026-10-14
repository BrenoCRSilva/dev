# Omarchy theme catalog, dictation, and portrait bar

This report records authored worktree changes; this agent did not perform live
configuration writes, theme installation/removal, theme selection, or model
downloads. The orchestrator separately reports that the requested theme
repositories were installed by pinned plain `git clone`, and that curation was
applied using the restore record noted below.

## A. Theme catalog and future palette sources

The upstream 100-themes collection contains 500 entries: 100 dark, 100 day,
100 high-contrast, 100 day-high-contrast, and 100 OLED. The orchestrator reports
the curation has left 200 selectable dark/day links and removed only the 300
entries ending in `-high-contrast`, `-day-high-contrast`, or `-oled`.
[`100-themes-excluded-links.txt`](100-themes-excluded-links.txt) lists the
exact 300 current link names. The orchestrator reports applying the curation;
its restore record is
`~/.local/state/omarchy/100-themes-curation/curation-20261014T182334Z.tsv`.
`scripts/curate-100-themes.sh` previews these
links by default; `--apply` records their exact symlink targets before
unlinking them, and `--restore` recreates them. Neither operation changes the
third-party checkout. This agent did not run it live.

The source checkout remains the installed `/home/pontual/.local/share/100-themes`
at commit `3bc337833cc1025a66b68e4d8c06d2899fd1d860`. External theme links are
excluded by envctl; they stay discoverable to Omarchy without being mirrored.

Requested additions are listed in
[`omarchy-theme-install-list.tsv`](../scripts/omarchy-theme-install-list.tsv).
Installed sources are Monokai Pro, One Dark Pro, Dracula, Solarized
Dark/Light, Ayu Dark/Light/Mirage, and Night Owl. The supplied Night Owl URL was
not correct: `maxberggren/omarchy-night-cat-theme` is Night Cat; the Night Owl
source is `janhesters/omarchy-night-owl-theme`. The orchestrator reports
installing all nine requested theme repositories by plain `git clone`; their
resolved SHAs are recorded in the TSV alongside the existing collection and
Spotlight pins.

The installed `omarchy theme install URL` is not a non-invasive bulk installer:
it clones the URL into a theme-name directory, recursively removes an existing
directory at that name, then immediately invokes `omarchy-theme-set`. That
changes the active theme and the command does not provide a revision-pin
option. Preserve the active theme by preparing pinned sources separately,
reviewing them, and only then using an explicit theme set when requested.

Palette compatibility checked against installed Omarchy:

- Current Monokai Pro, One Dark Pro, Dracula, and Night Owl repositories expose
  native `colors.toml` palettes; Omarchy's Alacritty conversion is not needed.
- Solarized Dark/Light and Ayu Dark/Light/Mirage expose legacy `alacritty.toml`
  palettes with all eight normal ANSI colors. The installed converter also
  accepts optional bright colors and defaults primary/selection values.
- All five legacy Alacritty palettes were converted successfully in scratch;
  no requested source was confirmed to fail conversion. For any legacy theme,
  Omarchy's converter requires all eight normal colors; if any is absent it
  warns and exits successfully without producing `colors.toml`, so validate
  that file before activating a theme.
- Third-party README instructions may describe optional extra hooks or files.
  The installed theme-set flow filters what it stages; it does not run arbitrary
  setup instructions from a README. No optional Dracula unlock/GTK setup is
  enabled here.

Reproducibility sources: [100-themes](https://github.com/bjarneo/100-themes),
[Monokai Pro](https://github.com/bjarneo/omarchy-monokai-theme),
[One Dark Pro](https://github.com/sc0ttman/omarchy-one-dark-pro-theme),
[Dracula](https://github.com/catlee/omarchy-dracula-theme),
[Solarized Dark](https://github.com/Gazler/omarchy-solarized-theme),
[Solarized Light](https://github.com/dfrico/omarchy-solarized-light-theme),
[Ayu Dark](https://github.com/fdidron/omarchy-ayu-dark-theme),
[Ayu Light](https://github.com/fdidron/omarchy-ayu-light-theme),
[Ayu Mirage](https://github.com/fdidron/omarchy-ayu-mirage-theme), and the
[correct Night Owl source](https://github.com/janhesters/omarchy-night-owl-theme).

## B. Voxtype

The live-authoritative `env/.config/voxtype/config.toml` now uses Whisper
`large-v3-turbo` on Vulkan with `language = "pt,en"`. The constrained language
list avoids the prior unrestricted auto-detection result (Turkish at
probability 0.45). Typed output and clipboard fallback remain enabled. The
Quickshell OSD is disabled because voxhud now supplies the dictation HUD.

External plugin `io.github.aashbury.voxhud` is installed at
`7f25cf97752a11411725fb9fa6b3a02a41499992`; its setup installed the
`~/.local/bin/voxhud` symlink. It displays its widget in the bar center and
replaces the Omarchy Dictation indicator, which is hidden in the live
configuration. The checkout is listed by source and commit, and excluded from
the authored mirror. No plugin source is vendored here.

## C. Stock Omarchy bar

The live and mirrored configuration now selects stock `omarchy.bar`, with
`shell.json bar.transparent = false` and `shell.toml [bar]
background-alpha = 0.8`. The background uses Omarchy's generated theme color at
80% opacity. The shared shell settings and the user's existing widget/layout
choices are captured from live config; no third-party bar checkout is required.

## D. Live-authoritative Spotlight and disabled plugin cleanup

Captured the orchestrator's live-authoritative configuration into `env/`:

- `.config/hypr/bindings.lua` (Super+Return Spotlight; no removed Alt+Space
  block), and `.config/hypr/looknfeel.lua` (global blur plus the
  `^omarchy-spotlight$` layer rule). The corresponding live backup is
  `blur-20261014T181151Z`; the removed Alt+Space block backup is
  `altspace-20261014T181253Z`.
- `.config/omarchy/shell.json` (Spotlight enabled, `pontual.search` disabled),
  `.config/omarchy/extensions/omarchy-menu.jsonc` (tasks route), and
  `.config/omarchy/spotlight.json`.

Spotlight and voxhud are external plugin checkouts, not authored mirror
content. Their reproducible source pins are in the install list; envctl and
`.gitignore` exclude both plugin trees, so capture/apply does not vendor their
files. Spotlight's pin is:
`maajix/omarchy-spotlight@a0f7fa746169a933e498037863e3353ede126413`. envctl now
also excludes `aashbury/voxhud@7f25cf97752a11411725fb9fa6b3a02a41499992`.

`pontual.search` stays disabled as requested. After user confirmation, proposed
prune targets are `env/.config/omarchy/plugins/pontual.search/` and
`~/.config/omarchy/plugins/pontual.search/`; neither has been removed. The
already-disabled `pontual.bar` and `pontual.bar-tools` authored directories are
absent from `env/`; their live directories remain separate prune candidates:
`~/.config/omarchy/plugins/pontual.bar/` and
`~/.config/omarchy/plugins/pontual.bar-tools/`.

## E. Host DDC configuration

Captured `~/.config/ddcutil/ddcutilrc` into
`env/hosts/omarchy-workstation/.config/ddcutil/ddcutilrc` and added it to the
host manifest. It contains the host-specific `[global] options: --ignore-bus 8`
setting to avoid DDC/CI writes to the Samsung monitor's bus.

## Prepared deployment / prune lists

New or reconciled authored paths to deploy:

- `.config/hypr/bindings.lua`, `.config/hypr/looknfeel.lua`
- `.config/omarchy/shell.json`, `.config/omarchy/extensions/omarchy-menu.jsonc`,
  `.config/omarchy/spotlight.json`
- `.config/voxtype/config.toml`
- Host overlay `.config/ddcutil/ddcutilrc`

Existing script/fixture and documentation changes accompany the theme-link
curation behavior. No apply or capture was run from this worktree.

Prune only after review/confirmation:

- `~/.config/omarchy/plugins/pontual.search/` (disabled; user confirmation
  requested)
- `~/.config/omarchy/plugins/pontual.bar/`
- `~/.config/omarchy/plugins/pontual.bar-tools/`

Prune is not part of envctl apply; it must be a separate selective removal with
a backup. No live plugin directory or theme link was removed here.
