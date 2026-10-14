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

Prepared `env/.config/voxtype/config.toml` for multilingual Whisper `base` with
`language = "auto"`. `base` is the low-latency starting choice because the
installed runtime currently reports CPU AVX2 as the next-launch backend and
does not detect a GPU. The machine has the AMD Vulkan driver and Voxtype reports
its Vulkan backend installed, but `voxtype setup gpu --status` says `GPU: not
detected`; therefore no local GPU speed claim is justified. No multilingual
model was downloaded, so an actual model comparison/latency benchmark was not
possible without fetching models and changing user state. `small` is the next
quality candidate if Portuguese recognition needs improvement and CPU latency
is acceptable; `medium` is not recommended as the first test on this detected
CPU-only path.

Omarchy already binds F9 down/up to `voxtype record start/stop` for push-to-talk.
The config keeps compositor-owned hotkeys disabled, preserving that binding.
Typed insertion and clipboard fallback remain enabled. The existing stock
`omarchy.indicators` widget includes the Dictation indicator, and remains in
the bar configuration. The user reports Voxtype's service is active, but this
session's metadata check showed no running daemon; no service was changed.

After deploying the config, the orchestrator can fetch the selected model with
`voxtype setup --download --model base --no-post-install`; model download is
separate from activation. No further user choice is needed for the selected
starting configuration. An optional later comparison is multilingual `small`
versus `base`, using real Portuguese and English dictation only when the user
is ready to test.

## C. Stock bar on both monitors

Installed Omarchy exposes one `bar.layout` in `shell.json`, shared by the
Quickshell bar instance on each screen. Neither the installed schema nor the
stock `Bar.qml` has a per-monitor widget-list override. `shell.toml` sets shared
bar geometry/typography, not monitor-specific widgets. There is no supported
JSON setting to hide the bar or different widgets on HDMI-A-1 alone without
replacing/forking the bar.

The prepared shared layout keeps the stock `omarchy.bar` base, placement, and
the same widgets on both monitors. The island-shaped workspace group is painted
by the user-owned `pontual.workspaces` widget selected through the supported
`shell.json` plugin/layout configuration; it is not a theme or global bar
shape option. That widget and its island styling stay unchanged. The layout
makes two small width reductions:

- `sys-monitor.showNet = false`: the separate `omarchy.network` widget already
  displays network state, so this removes duplicate live-rate text while
  retaining CPU/RAM, their icons, and the system-monitor details/popout.
- Clock `format = "HH:mm"` and `formatAlt = "d MMM yyyy"`: drops seconds from
  the always-visible center label.

The largest fixed left-side width contributor is `pontual.workspaces`: each
real workspace reserves 28 scaled pixels plus group insets. The right side
also has several independent indicators; the center has media, tray, clock,
and notification-history controls. On a 1080-logical-pixel monitor all three
regions compete for width. Static source/config inspection identifies those
width contributors, but no per-widget runtime geometry or post-deployment
portrait screenshot was available in this worktree-only pass. The two prepared
reductions preserve the custom workspace appearance and avoid hiding unrelated
controls. Validate on HDMI-A-1 after deployment. If overlap remains, the next
supported tradeoff is a shared compact workspace widget (with simpler numeric
workspace labels) or globally moving/removing a lower-priority widget; Omarchy
does not currently offer a per-output list to keep that change on HDMI only.

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

Spotlight is an external plugin checkout, not authored mirror content. Its
reproducible source pin is in the install list:
`maajix/omarchy-spotlight@a0f7fa746169a933e498037863e3353ede126413`. envctl now
excludes that plugin subtree so capture/apply does not vendor its files.

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
