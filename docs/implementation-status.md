# Implementation status

**Updated:** 2026-10-13

## Deployment and ownership

The prepared source is deployed. Final `scripts/envctl apply --host
omarchy-workstation` applied six Neovim files and created the complete backup
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T023327.672872707Z`.
Its metadata records `scope=apply`, `host=omarchy-workstation`, and
`complete=yes`. `scripts/envctl diff --host omarchy-workstation` now reports
`0 path(s) differ`.

`dotfiles/env` plus `scripts/envctl` is the verified canonical mirror and
deployment owner. The prepared tree includes the reconciled live Neovim files,
the theme template/hook, shell and terminal consumers, and allowlisted authored
configuration. `PontuArch/env` remains present as an old source copy. The
PontuArch agent completed duplicate capture/apply/sync CLI ownership retirement;
its compatibility fixture and shell syntax checks passed, as did explicit
force-mode verification. Its Omarchy output gate is implemented in source and
passed 5/5 checks, but has not been installed with a live daemon. The cross-repo
ownership handoff is complete; the old PontuArch env source copy was preserved.

Current metadata-only runtime inspection found no PontuArch-named process and
no matching system or user service unit in the service manager. This reports
only visible process/unit names; it does not prove that an unrelated or
renamed process could not write theme state.

The corrected theme hook was backed up and applied as the final deployment
change. Its backup is
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T023715.795478049Z`
(`complete=yes`, `scope=apply`, `host=omarchy-workstation`). The preceding
six-file Neovim deployment backup remains
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T023327.672872707Z`.

For a full migration rollback, restore the apply snapshots in reverse
chronological order (newest first), using `scripts/envctl restore BACKUP`:

1. `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T023715.795478049Z` — the corrected theme hook only.
2. `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T023327.672872707Z` — six Neovim files.
3. `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T022711.869374457Z` — Mason/LSP config and theme hook.
4. `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T022259.187380360Z` — initial 14-path deployment.

The last hook snapshot alone does not roll back the migration; each earlier
snapshot restores the prior state for paths changed in that deployment pass.

The live theme-set directory contains exactly one active Neovim reload hook,
`reload-nvim`; there is no obsolete `reload-nvim-theme.hook`. The notification
example remains a `.sample` file. No VectorCode-named file or VectorCode
reference exists in either the live Neovim tree or `dotfiles/env`.

No running editor was restarted or terminated. The theme hook was invoked
after the final deployment and reloaded its existing Neovim server. LSP
configuration changes take effect in newly started Neovim processes; an
existing editor can be restarted later at the user's convenience.

## Neovim and message checks

The behavioral test exercises the actual staged `lua/pontuarch.lua`, Lualine,
and Noice files. It passed native Catppuccin dark and light selection,
unsupported-theme and missing-state fallback, native plugin failure fallback,
and statusline/notification refresh. The hook fixture reached two already
running isolated Neovim servers, invalidated a cached old `pontuarch` module,
loaded the new state reader, then applied a second palette change.

The full staged startup smoke used the installed plugin tree in a temporary
HOME/XDG environment, with copies of the current live Omarchy theme name and
Neovim palette (network/update and parser installation were disabled only in
that copy). Startup selected the installed native `gruvbox` colorscheme for
the active Omarchy theme. One Neovim process opened two Lua files sequentially,
a plain text file, then a QML file. `lua_ls`, StyLua `--lsp`, and `qmlls`
attached. The captured `:messages` snapshots after each open were empty; the
smoke's own client summary was printed after the snapshot and is not part of the
messages. No warning or error remained in that run. The isolated LSP check also confirmed
the `rust_analyzer` config identifier/settings and graceful QML-unavailable
case. System `qmlls` is selected when available, and StyLua has an executable,
Lua filetype, root selection, and explicit enablement.

This verifies the recurring warning is absent in the tested staged startup and
sequential file-open cases. The exact warning previously seen in the user's
interactive session was not supplied, so this does not establish that every
project-specific or existing-session warning is resolved. No messages were
read from or buffers changed in the user's active editor sessions.

## Theme source and desktop consumers

Omarchy is the sole active theme-state producer. The adapter reads
`$XDG_STATE_HOME/omarchy/current/theme.name` and the generated
`.../current/theme/nvim-palette.lua`; the installed theme-set hook notifies
existing Neovim servers and does not require the PontuArch daemon. Adapter and
hook checks passed without changing the active theme.

At the preceding desktop-consumer validation, the active theme was `gruvbox`.
Its staged palette outputs were present:
`tmux-palette.sh`, `shell-colors.zsh`, and `ghostty.conf`. The deployed tmux
theme script sources the staged tmux palette, `.zshrc` sources the staged shell
colors, and Ghostty includes the staged `ghostty.conf`. Their generated
background/foreground/accent values match the active Omarchy Gruvbox palette.
The final deployed hook reloads the tmux shell-driven theme script with
`tmux run-shell`. A prior attempt used `tmux source-file`, which rejected this
script; the hook was corrected and rerun. Live tmux now reports status
background `#282828` and active pane border `#7daea3`, matching Gruvbox. The
hook's Nvim remote eval reports the existing server PID and `gruvbox` without
reading or changing buffers. `omarchy restart terminal` exited successfully;
the installed command reloads supported terminals by signaling Ghostty and
does not terminate its sessions. No theme switch or browser restart occurred.

## Verification run

- `scripts/tests/envctl-fixture.sh`: passed no-op capture/apply, private and
  incomplete backup behavior, failed-copy rollback, dangling symlink restore,
  host metadata, and scoped prune cases.
- `scripts/tests/theme-hook-fixture.sh`: passed multi-server migration and
  subsequent theme-switch reload.
- After the hook's tmux `run-shell` correction,
  `scripts/tests/theme-hook-fixture.sh` and `bash -n` for the hook, envctl, and
  hook fixture passed again.
- `scripts/tests/nvim-theme-adapter-check.sh`: passed native/fallback mapping
  and Lualine/notify behavior using the actual adapter and UI config files.
- `scripts/tests/nvim-lsp-check.sh`: passed Lua, StyLua, QML, Rust identity,
  and missing-QML checks.
- `scripts/tests/nvim-startup-smoke.sh`: passed installed-plugin startup and
  sequential file opens with empty captured `:messages`.
- `bash -n scripts/envctl scripts/tests/*.sh` and `git diff --check`: passed.

The applied source is backed up and live diff is zero. Exactly one active
Neovim reload hook exists. Cross-repo CLI ownership retirement is complete;
PontuArch's output-gate change remains source-only and does not require
deleting or rewriting its old env source copies.

## Follow-up integrations and bar validation

The accepted follow-up changes were applied to eight canonical paths under
`env/`: the search/workspace/system-monitor plugins, Omarchy shell layout and
menu, `.zshrc`, and Neovim clipboard provider setup/helper. The complete apply
snapshot is
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T031851.691107655Z`
(`scope=apply`, `host=omarchy-workstation`, `complete=yes`). Its manifest records
the prior state, including that the new clipboard helper did not exist before
deployment. Live files match the canonical tree and `envctl diff` reports zero
drift.

Focused checks already passed for Zsh syntax and bindings (Ctrl-T/Ctrl-R kept
their existing widgets; fzf uses free Alt-F/Alt-H in vi maps), remote clipboard
selection/fallbacks, staged Neovim startup, and menu routes. The search plugin
imports `Quickshell.Hyprland` and handles unavailable focused-monitor lookup;
sys-monitor no longer registers a global IPC target from each monitor widget.
Quick Settings uses native `omarchy-shell shell toggle <id> '{}'` routes for
audio, network, Bluetooth, display, sys-monitor, and nightlight. Notification
history opens `omarchy-shell shell toggle foamy.notification-center '{}'`, OCR
is exposed through `omarchy-capture-text`, and the stock system-update
indicator is included conditionally.

The live bar initially still looked opaque after plugin hot reload, so
`omarchy restart shell` was used once. A bar-only crop afterward shows wallpaper
texture through the workspace backing with a subtle theme-colored tint; the
sys-monitor glyphs match their normal metric text color. The workspace and
sys-monitor backing rectangles each use the current `Color.bar.background`
with one `opacity: 0.10`; no layout or full-bar transparency setting changed.
The restart refreshed the visible QML; the evidence establishes that hot reload
had not refreshed the rendered workspace appearance, but does not identify a
deeper Quickshell cache mechanism. Recent Quickshell output contained no target
plugin/IPC errors; it did contain a Qt portal app-ID registration warning.
Temporary bar-only captures were removed from `/tmp`.

## Task windows and external theme collection

The task launcher is authored at
`env/.config/tmux/scripts/task-sessionizer.sh`. Its focused isolated tmux
fixture passed single- and multi-repository ordering, `nvim .` launch cwd,
busy `srv-<repo>` re-entry, active-window focus, and preservation of extra and
existing editor windows. The live `omarchy-ricing` session was reconciled to
`agent`, `nvim-dotfiles`, `nvim-PontuArch`, `srv-dotfiles`, and `srv-PontuArch`
in that order. Existing panes/editors and two unrelated windows remained
present; the original PontuArch editor was retained as `preserved-srv-PontuArch`.
The launcher was deployed in
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T144609.167557594Z`.

The `bjarneo/100-themes` collection is installed separately from the authored
mirror. Its source checkout is
`/home/pontual/.local/share/100-themes` at commit
`3bc337833cc1025a66b68e4d8c06d2899fd1d860`; the reviewed installer SHA-256 is
`32b21838164a3aa060f097be9963b9fdda8f62c445e84504cbccf22af6abc0cb`. The
installation uses `--all --link` and does not pass `--set`. Omarchy discovers
the 500 user theme links under `~/.config/omarchy/themes`; these represent 100
families with five variants each. All 500 `colors.toml` files parse, each
variant has a backgrounds directory, and the collection contains 1,500
background files. There are 22 stock themes, no name collisions, and Omarchy
lists 522 themes after installation. The user's theme directory was empty
before installation, so there were no preexisting authored user themes to
replace; stock themes remain unshadowed.
The upstream [README](https://raw.githubusercontent.com/bjarneo/100-themes/main/README.md)
documents the collection and linked install mode. The
[installer source](https://raw.githubusercontent.com/bjarneo/100-themes/main/install.sh)
was reviewed before execution and verified by hash at the pinned commit.

Source and rollback provenance are recorded in
`/home/pontual/.local/state/omarchy/theme-install-backups/100-themes-20261013T144827.596860908Z`.
The metadata includes the upstream commit, installer hash, names, and exact
symlink targets. The checkout is the update source; pin its recorded commit to
reproduce this install. To roll the collection back, remove only the 500
destination symlinks listed in `installed-links.tsv`; retain the source clone
if rollback may need to be reversed. The clone is third-party source, not part
of `env/`.

The canonical deployment CLI is source-only at
`/home/pontual/tasks/omarchy-ricing/dotfiles/scripts/envctl`; no `envctl`
executable is installed on `PATH`. Its manifest allows authored Omarchy theme
files, while path enumeration now skips external theme/background symlinks and
their glob-expanded descendants. Authored theme files remain eligible for
capture/apply. The envctl fixture covers external links, descendants, authored
themes, and rejection of arbitrary outward symlinks. On the live host,
`capture --dry-run` completed and listed three unrelated live-only paths, none
from the collection: `.config/hypr/bindings.lua.bak.1791665400`,
`.config/tmux/scripts/search-identity.py`, and
`.config/tmux/scripts/task-sessionizer.sh.bak.1791674638996495363`. They were
not captured or overwritten. The dated task-sessionizer path is a backup, not
the launcher source; no launcher source/live conflict was demonstrated.
`apply --dry-run` and `diff` report zero differences. Apply does not prune
unmanaged files, and explicit prune remains limited to previously managed
paths.

At collection preflight `omarchy theme current` reported `Nord`; the final
runtime check reports `Ethereal`. The collection installer was invoked without
`--set`, and I did not run a theme-set command. The active state file changed
during the installation interval, but its cause is unverified, so this report
does not claim that the active theme remained unchanged. I left the observed
`Ethereal` state untouched.

### Theme picker follow-up

The installed Omarchy picker failed with the full 522-theme row payload but
opened with the same rows through short cache paths. A count sweep succeeded at
500 rows and timed out at 510+, while compact paths opened all 522; this points
to serialized IPC payload size, not missing theme assets. I deployed a scoped
wrapper at `/home/pontual/.config/omarchy/bin/omarchy-theme-switcher-compact`
and overrode only `style.theme` in the existing menu extension. The native
icon, label, aliases, and all other menu extensions remain in place. Ordinary
Theme selection and `omarchy menu summon style.theme` use that same overridden
action. The wrapper sets `XDG_CACHE_HOME` only for the stock picker process and
reuses the existing cache through a private short symlink in
`$XDG_RUNTIME_DIR`.

The deployed picker layer opened from `omarchy menu summon style.theme`; the
active theme remained Ethereal. The menu parser accepted the extension refresh,
the wrapper environment check showed the child using `/run/user/1000/c` while
the parent retained `/home/pontual/.cache`, and `scripts/envctl diff` reports
zero differences. Deployment backup:
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T150504.080496371Z`.
Interactive search and Escape were not claimed as passed: the picker layer did
not take keyboard focus from Ghostty during this direct IPC summon. It was
closed through the image-selector cancellation IPC, without applying a theme.

### Strata file manager

Installed Strata v1.0.0 from the official stable release using the reviewed
upstream installer as the desktop user. Source commit: `6662d8d4bd4cb3cdec3f10f918f3b4c92b18cdcc`.
The release archive checksum passed; its asset SHA-256 is
`e15095a201165132a88032df15ecbeab795a13d6cacc4ebb943e276c35ff492e`. The
installer SHA-256 was `2d3345496e32af74a2a236c815646ec866226e3aa969b43a4964eb2f847b55f4`.
GitHub CLI was unauthenticated, so signature attestation was not checked. The
installer source and provenance are at the official [Strata repository](https://github.com/lgse/strata),
[installer](https://github.com/lgse/strata/blob/main/install.sh), and
[v1.0.0 release](https://github.com/lgse/strata/releases/tag/v1.0.0).

The authorized Omarchy package transaction used `pkexec /usr/share/omarchy/bin/omarchy pkg add`
for `gst-libav`, `gst-plugins-good`, and `gtksourceview5`; pacman also installed
their seven missing runtime libraries. Strata is at `~/.local/bin/strata`.
The official installer created its desktop entry, icon, and per-user
`org.freedesktop.FileManager1` service. Its generated desktop and service files
are mirrored as owned paths in `env/.local/share/`; the icon, executable, and
Strata first-run state remain installed/generated assets outside `env/`.
`~/.config/mimeapps.list` now assigns `inode/directory` to
`io.github.lgse.Strata.desktop`; the full file, including preexisting
browser/mail/handler choices, is captured at `env/.config/mimeapps.list` and
listed in the env manifest.

The authored integration changes only `env/.config/hypr/bindings.lua` and the
two manager actions in `env/.config/omarchy/extensions/omarchy-menu.jsonc`.
`SUPER+ALT+F` and the Files menu open Strata at Home;
`SUPER+ALT+SHIFT+F` and the cwd menu action open the terminal directory.
`SUPER+SHIFT+F` remains the existing Fullscreen binding. No Omarchy keybind
installer, chooser portal replacement, SMB/RAW/unlock integration, or Nautilus
removal was used.

Strata v1.0.0 supports Omarchy Quattro theme following. Its official
[theme guide](https://github.com/lgse/strata/blob/v1.0.0/docs/themes.md) says
fresh installs default to following when a valid current-theme state exists;
the installed source implements this by selecting Omarchy mode when
`settings.toml` is absent and the Quattro palette loads
([preference normalization](https://github.com/lgse/strata/blob/v1.0.0/src/ui/preferences.rs#L522)).
At verification, `~/.config/strata/settings.toml` was absent, Omarchy's current
palette parsed successfully, and `omarchy theme current` reported Rose Pine
Dark. No Strata preference override was needed or created: the first-run
default uses Omarchy as the theme source, and the app monitors theme state
changes. This is built-in consumer behavior, with no second theme producer.

Validation: `strata --version` reports 1.0.0; `xdg-open "$HOME"` opened Strata
and loaded the home directory; `omarchy-menu summon pontual-files.manager`
executed the configured leaf action and produced a Strata window. The live
keybinding menu lists both Strata chords and retains `SUPER+SHIFT+F` as
Fullscreen. `hyprctl reload` returned `ok`, `hyprctl configerrors` was empty,
the desktop file passed `desktop-file-validate` with only its optional category
hint, and `scripts/envctl diff --host omarchy-workstation` reports zero
differences after the MIME file was added to the authored mirror.

FileManager1 handoff is pending for the current session. A harmless
`ShowFolders(file:///home/pontual)` call succeeded, but its existing name owner
is Nautilus (PID 897505). The compositor reports one Nautilus window and no
copy/move/delete/progress-like window title; FileManager1 itself exposes window
locations but no active-operation status. Because a window is open, this is not
the idle/no-window case, so I left the process and window intact. Strata's
per-user activation service is installed but has not taken ownership of the
already-held bus name. Recheck after Nautilus releases the name or at the next
session before claiming external “Open file location” calls reach Strata.

Pre-install MIME snapshot:
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/strata-preinstall-20261013T151644Z`.
Authored config apply backup:
`/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T151739.416452847Z`.
To restore the previous folder handler, run
`xdg-mime default org.gnome.Nautilus.desktop inode/directory`. After closing
Strata, remove its user binary, desktop entry, icon, FileManager1 service, and
`~/.config/strata/portal-opt-in-v1` if a full app rollback is desired; the
package dependencies can remain installed if other apps use them.
