# Keybindings audit and applied Omarchy map

**Scope:** layered binding audit plus the explicitly approved desktop map and earlier Ctrl-Alt-Delete / Neovim fixes. No tmux, Herdr, or general navigation remap was made. Full snapshots and machine-readable runtime records are in [keybindings-inventory](keybindings-inventory/README.md).

## Main findings

- **High-impact accepted tmux action: Ctrl-F+d kills the entire tmux server without confirmation.** The user config maps `d` to `kill-server` in `env/.config/tmux/tmux.conf:16-18`; the user explicitly wants this retained as stuck-session recovery. Herdr's analogous `prefix+d` detaches. Document the scope; the user explicitly retained it, so this task leaves it unchanged.
- **Recorded Herdr close tradeoff; no change is prioritized here.** The authored `[ui] confirm_close=false` in `env/.config/herdr/config.toml` makes close-tab, close-workspace and close-pane routes immediate. This remains documented for awareness; the current task prioritizes native desktop routes and makes no Herdr changes.
- **Neovim `<leader>q` now runs `:wq!`.** As explicitly requested, it writes the current buffer then quits the current window. It no longer force-quits without saving; because `!` is present, verify the user's intended overwrite behavior for read-only files before changing it later.
- **Ctrl-Alt-Delete bulk close is removed.** The stock action closed every Hyprland client without confirmation. The authored `hl.unbind("CTRL + ALT + DELETE")` removes that exact chord; the separate `Super+Ctrl+Alt+Delete` display-mirroring action remains.
- **tmux Ctrl-F+d and Ctrl-F+p are intentional user contracts.** Keep `d` as the stuck-session recovery action and `p` as direct Wayland-clipboard-to-tmux-buffer paste. The latter is not interchangeable with Omarchy's universal paste, which injects a terminal paste keystroke. This audit does not propose changing the tmux letter table.
- **tmux's intentional unprefixed Ctrl-T/Ctrl-R bindings take precedence inside every pane.** `C-t`/`C-r` cycle tmux windows (`tmux.conf:12-14`), so Zsh's Ctrl-R history search and Neovim's normal-mode Ctrl-R redo, insert-mode Ctrl-R register insertion, and Ctrl-T indentation cannot receive those keys while tmux is active. This accepted tradeoff is documented, not proposed for change.
- **tmux prefix Ctrl-F also captures Neovim Ctrl-F page-down.** The configured prefix is `C-f` (`tmux.conf:4-10`). Double-prefix `C-f C-f` sends a literal Ctrl-F to the application; it costs an extra chord. Existing `C-d/C-u` centered paging is an alternative in Neovim.
- **Herdr's direct Alt shortcuts collide with Ghostty defaults.** Herdr maps `Alt+1..9` to tab selection and `Ctrl+Alt+Arrow` to pane focus (`env/.config/herdr/config.toml:37-68`). Ghostty defaults already bind `Alt+1..9` to Ghostty tabs and `Ctrl+Alt+Arrow` to Ghostty split navigation (`ghostty-default-keybinds.txt`). When a Herdr client is focused in Ghostty, the terminal consumes those keys first. This is a real terminal-to-app interception; keep it in mind when choosing which layer should own a particular action, without assuming a navigation redesign.
- **Hyprland's Alt-Tab pair is a composed stock action, not a conflict to remove.** The current runtime has 263 entries; the Omarchy binding menu shows `Alt+Tab` as both “Focus on next window” and “Reveal active window on top”, with the analogous pair for `Shift+Alt+Tab`. Both declarations come from the installed default `.../bindings/tiling.lua:44-47`; cycling then raising the active window is the intended composition. There is no evidence of a runtime problem, so preserve it. F9's start-on-press/stop-on-release pair is also intentional.
- **The effective Hyprland map has one submap (`default`).** The active `hyprland.lua` loads Omarchy defaults, then `hypr.bindings`; the personal bindings layer deliberately unbinds/reassigns many stock application keys. The separate `env/.config/hypr/pontuarch/binds.conf` is inactive standalone material, not a live binding source.
- **Super-F is fullscreen again; Super-Shift-F maximizes.** `Super+E` opens Strata; the older `Super+Alt+F` Strata alias and `Super+Alt+Shift+F` terminal-cwd route remain. The alias occupies stock `Super+Alt+F` full-width, while the newly requested `Super+E` is the primary file-manager chord.

## Priority and accepted tradeoffs

The user-approved first-class map is now deployed. tmux and Herdr remain the user's agent/session command center; their current navigation contracts are unchanged. Ghostty interception and Ctrl-T/R effects remain context, not a broad remapping request. The personal Neovim leader map and plugin choices are preserved.

## Detailed layer review

### Hyprland and Omarchy

The live runtime has 263 bindings, all in the default submap. Runtime command origin is resolved from the user load chain, packaged default Lua sources, and `omarchy menu keybindings --print`; the menu output resolves physical keys for Lua callbacks whose JSON rows contain only callback IDs. The menu has 262 rendered rows; the removed bare Ctrl-Alt-Delete no longer appears. The distinct `Super+Ctrl+Alt+Delete` action is labeled “Toggle laptop display mirroring”; it is not the bulk-close action and remains bound. Alt-Tab cycle/raise and F9 press/release are intentional multi-dispatch behaviors, not duplicate mappings to delete.

The personal map at `env/.config/hypr/bindings.lua` centralizes desktop navigation, task/session menus, capture, Strata and app-category routes. The implemented first-class chords are terminal `Super+Space`, personal Spotlight `Super+Return`, screenshot `Super+P`, direct task launcher `Super+S`, existing tasks-and-sessions dashboard `Super+D`, Strata `Super+E`, fullscreen `Super+F`, maximize `Super+Shift+F`, System menu `Super+Escape`, compact theme picker `Super+T`, Omarchy root menu `Super+M`, universal copy/paste `Super+C/V`, and clipboard history `Super+Y`. The Development category remains available on `Super+Shift+D`; Entertainment/Communication and pseudo-window remain on `Super+Shift+E/C/P`. These actions remain discoverable in Omarchy menus/keybinding help.

#### Installed stock Hyprland binding catalog

This is the readable grouped view of the installed packaged declarations, including entries later overridden by personal config. Exact declarations and source line numbers are in [`omarchy-stock-binding-declarations.txt`](keybindings-inventory/omarchy-stock-binding-declarations.txt); the live effective list is separate. Ranges below describe loops in the source, not extra manually declared aliases.

| Stock family | Declared actions and keys |
|---|---|
| Launchers and applications | `Super+Return` terminal; `Super+Shift+Return` browser; `Super+Shift+F` file manager; `Super+Alt+Shift+F` file manager at terminal cwd; `Super+Shift+B` browser; `Super+Shift+Alt+B` private browser; `Super+Shift+N` editor; `Super+Alt+Return` tmux; `Super+Ctrl+Return` Herdr. App/web launchers: `Super+Shift+M` Spotify, `Super+Shift+Alt+M` music TUI, `Super+Shift+D` Docker (overridden by the personal Development category, now on this chord), `Super+Shift+G` Signal, `Super+Shift+O` Obsidian, `Super+Shift+W` Omawrite, `Super+Shift+/` password manager, `Super+Shift+A` ChatGPT, `Super+Shift+Alt+A` Grok, `Super+Shift+C` Calendar, `Super+Shift+E` email, `Super+Shift+Alt+E` compose email, `Super+Shift+Y` YouTube, `Super+Shift+Alt+G` WhatsApp, `Super+Shift+Ctrl+G` Google Messages, `Super+Shift+P` Photos, `Super+Shift+S` Maps, `Super+Shift+X` X, `Super+Shift+Alt+X` compose X post. |
| Menus and desktop utilities | `Super+Space` root Omarchy menu; `Super+Alt+Space` Apps menu; `Super+Ctrl+E` emoji; `Super+Ctrl+C` Capture menu; `Super+Ctrl+O` Toggle menu; `Super+Ctrl+H` Hardware menu; `Super+Shift+code:201` root menu (hardware key code, not a portable key label); `Super+Escape` System menu; `XF86PowerOff` power menu; `Super+K` keybindings; `Super+Alt+K` tmux keybindings; `Super+Ctrl+K` Herdr keybindings; `Super+Ctrl+Q` or `XF86Calculator` calculator. `Super+Shift+Space` toggles bar; `Super+Ctrl+Space` background picker; `Super+Ctrl+Shift+Space` theme picker. `Super+Backspace` window transparency; `Super+Shift+Backspace` gaps; `Super+Ctrl+Backspace` square aspect. |
| Window and workspace control | `Super+W` close; stock `Ctrl+Alt+Delete` close all (now unbound by user config); `Super+J` split; `Super+P` pseudo; `Super+T` float/tile; `Super+F` fullscreen; `Super+Ctrl+F` tiled fullscreen; `Super+Alt+F` maximize/full width; `Super+O` float/pin. `Super+Alt+Home` save width; `Super+Home` restore width; `Super+L` workspace layout. `Super+Arrow` focus; `Super+Shift+Arrow` move/swap; `Super+Shift+Alt+Arrow` move workspace across monitors. `Super+1..0` selects workspaces 1..10; `Super+Shift+1..0` moves windows there; `Super+Shift+Alt+1..0` moves silently. `Super+Tab`, `Super+Shift+Tab`, `Super+Ctrl+Tab` next/previous/former workspace; `Super+S` scratchpad; `Super+Alt+S` move to scratchpad. `Alt+Tab` and `Alt+Shift+Tab` each compose cycle plus bring-to-top. |
| Window sizing, groups and pointer | Super+physical `code:20/21` resize left/right; Shift variants resize vertically; Alt variants resize in 25 px steps; Ctrl variants resize in 300 px steps. `Super+mouse:272/273` drag/resize. `Super+G` group toggle; `Super+Alt+G` ungroup; `Super+Alt+Arrow` move into adjacent group; `Super+Alt+Tab` and `Super+Alt+Shift+Tab` cycle grouped windows; `Super+Ctrl+Left/Right` previous/next group window; `Super+Alt+mouse wheel` previous/next group window. A loop binds `Super+Alt+code:10..18` to group windows 1..9. `Super+Slash` monitor scale up; `Super+Alt+Slash` down. |
| Capture, recording and OCR | `Print` smart screenshot; `Alt+Print` stop current recording or open recording action; `Super+Print` color picker; `Super+Ctrl+Print` OCR. Contextual screenshot picker: `Enter` capture highlighted window; `Ctrl+Enter` fullscreen; `Tab`/`Ctrl+Tab` cycle selected window; arrow keys select a window directionally. These are capture-picker context keys, not global desktop shortcuts. |
| Clipboard and notifications | `Super+C/V/X` universal copy/paste/cut. Copy/paste inject Ctrl+C/Ctrl+V in GUI apps and Ctrl+Insert/Shift+Insert in a terminal; cut injects Ctrl+X. `Super+Ctrl+V` clipboard manager. `Super+,` dismiss last notification; `Super+Shift+,` dismiss all; `Super+Ctrl+,` silence toggle; `Super+Alt+,` invoke last; `Super+Shift+Alt+,` notification history. |
| Lock, display and native panels | `Super+Ctrl+I` idle-lock toggle; `Super+Ctrl+L` lock; `Super+Ctrl+N` nightlight; `Super+Ctrl+Delete` internal laptop display toggle; `Super+Ctrl+Alt+Delete` laptop-display mirroring (distinct from close-all). `Super+Ctrl+A/B/D/W/P` Audio/Bluetooth/Display/Network/Power panels. `Super+Ctrl+Alt+D` Calendar; `Super+Ctrl+T` Activity; `Super+Ctrl+S` Share; `Super+Ctrl+Period` Transcode; `Super+Ctrl+R` set reminder; `Super+Ctrl+Alt+R` show reminders; `Super+Shift+Ctrl+R` clear reminders; `Super+Ctrl+Alt+T` time notification; `Super+Ctrl+Alt+B` battery notification; `Super+Ctrl+Alt+W` weather notification. `Super+Shift+Ctrl+A` agent picker. `Super+Ctrl+Z` zoom in; `Super+Ctrl+Alt+Z` reset zoom. |
| Hardware/media keys | XF86 volume up/down/mute, mic mute, display brightness up/down, Shift brightness max/min, keyboard brightness up/down/backlight cycle, touchpad toggle/on/off, media next/play-pause/previous, eject, calculator, power, and keyboard backlight. Alt+XF86 volume/brightness provides precise ±1 steps; Shift+XF86AudioMute switches audio output; Shift+XF86AudioPlay/Pause switches media source; Alt+Play and Alt+Shift+Play are next/previous track aliases. Volume/brightness keys are marked repeat/locked where declared; lid-switch on/off hooks are locked. |
| Dictation | `Super+Ctrl+X` toggles recording. `F9` starts on press and stops on release (push-to-talk), represented as paired press/release entries. |

The stock file declares 194 rows. Important source patterns: the workspace, resize, group-index and screenshot-picker actions include loop-generated/contextual bindings; press/release and locked/repeating flags affect dispatch semantics. The raw snapshot preserves these implementation details where a short table cannot.

### tmux, Herdr and Ghostty

tmux 3.7c has 280 active key-table rows in the complete snapshot. The custom prefix is Ctrl-F; the literal prefix can be sent with a second Ctrl-F. The root Ctrl-T/Ctrl-R window-cycle bindings are intentional. Other review items:

- `prefix+d` currently kills the whole server; `prefix+k` kills a pane without a confirmation prompt.
- `prefix+c/n/p` currently mean copy-mode/new-window/clipboard-paste. Previous window is no longer bound to `p`; last-window remains a separate tmux action.
- `prefix+F` invokes the older sessionizer while lowercase `prefix+f` opens the task sessionizer. `prefix+C` invokes `pontuarch ipc cursor`; no installed `pontuarch` command was found, so this route appears unavailable on this host. The separate PontuArch repo sessionizer is not the task sessionizer and is not a binding source here.
- Herdr 0.8.2 uses Ctrl-Space as prefix, with `c/r/k` new/rename/close tab, `n/p` next/previous tab, `1..9` tab selection, workspace actions on shifted prefix keys and pane focus/resize on Ctrl-Alt arrows. Herdr's direct Alt-number and Ctrl-Alt-arrow alternatives are shadowed by Ghostty's built-in tab/split bindings while inside Ghostty. Prefix versions avoid that.
- Ghostty 1.3.1 has 72 default keybind rows and the current resolved output has 74. `Shift+Insert` now resolves to `paste_from_clipboard` instead of the default `paste_from_selection` (PRIMARY); `Ctrl+Shift+V` also uses `paste_from_clipboard`. This makes Hyprland's terminal-aware `Super+V` use the regular clipboard. Ghostty's Ctrl-Alt arrows remain terminal split navigation and Ctrl-Shift arrows/page keys navigate tabs. Font-size Ctrl-plus/minus/zero keys remain terminal-scoped; custom `Shift+Enter` sends a newline.

No tmux/Herdr key reassignment is proposed. In particular, retain Ctrl-F+d, Ctrl-F+p, root Ctrl-T and Ctrl-R. Ghostty's shadowing of Herdr's direct Alt-number/Ctrl-Alt-arrow alternatives is a documented scope interaction; Herdr remains the user's primary agent/session command center.

### Zsh

The deployed Zsh uses vi editing mode, Zinit, autosuggestions, fzf-tab, and zoxide. It accepts autosuggestions on Ctrl-Space and adds fzf file/history widgets on Alt-F/Alt-H while preserving preexisting Ctrl-T/Ctrl-R and Alt-C bindings (`env/.zshrc:7-8,54-55,171-200`). Those user maps are intentionally kept. Within tmux, root Ctrl-R is intercepted for window switching before Zsh history search can run; Ctrl-Space belongs to Herdr only while its client is receiving input. This is contextual layering, not a global Zsh-vs-Herdr duplicate.

### Neovim

All five running Neovim servers were queried through read-only RPC without reading buffer names or contents. Four expose the same global totals (`n=123, v=44, x=35, s=15, o=14, i=17, c=7, t=0, l=0`); one prompt/UI server has `i=34, c=23`. Buffer-local totals vary substantially by loaded UI/filetype. The JSON snapshot contains global maps plus every valid loaded buffer's maps, labeled only by buffer number and filetype. These counts include Vim defaults and loaded plugin mappings, not only personal maps. Lazy plugin specs not loaded in a server are inventoried separately from source.

Main authored maps in `env/.config/nvim/lua/brenocrs/remap.lua`:

- `<leader>s` writes and `<leader>q` runs `:wq!` (writes the current buffer, then quits the current window).
- Visual `J/K` move lines; `Ctrl-D/Ctrl-U` recenter paging; visual `<leader>p` pastes without replacing the unnamed register; `<leader>P` pastes from system clipboard.
- `<leader>rw` replaces the word under cursor; `<leader>w{h,j,k,l,o}` controls editor windows; `&` maps to `^`, `$` maps to `g_`.

LazyLoad/plugin additions in `plugin-keymaps.lua` and plugin specs add Oil `<leader>o`, Noice `<leader>nl`, Grapple `<leader>a/e/1..5`, Telescope `<leader>f{a,f,h,c,b,w,W,G,g}`, Neogit `<leader>g{m,p,o,b,D}`, Trouble `<leader>t{t,h,f}` and `<leader>cq`, fold actions `<leader>d{o,F,a}`, Neo-tree `<leader>nt`, and buffer-local LSP references/implementations/rename on `<leader>fr/fi/rn`. LSP definition, declaration and hover are plain normal-mode `gd`, `gD` and `K` (not leader maps). Dadbod uses `<leader>db/df`; GitGraph uses `<leader>gl`. Global normal-mode Ctrl-N/Ctrl-P become Trouble next/previous after Trouble loads, but are no-ops while Trouble is closed. Neo-tree maps Ctrl-F to scroll preview and Ctrl-R to clear its clipboard in its tree buffer; tmux consumes Ctrl-F as its prefix (double Ctrl-F forwards it) and Ctrl-R for previous-window (no configured pass-through).

There is useful cleanup without dropping plugins or editing behavior:

- Update which-key descriptions in `env/.config/nvim/lua/plugins/which-key.lua`: `<leader>gP` is described as Pull-Rebase but has no matching map; `<leader>dt` says Toggle Fold while actual fold maps are `<leader>do/dF/da`; the `<leader>r` group says Refactor although it contains word replacement and LSP rename. Treat which-key declarations as labels, not mappings.
- The Neogit integration repeatedly deletes `<leader>gs` immediately, scheduled, and after 500 ms (`plugin-keymaps.lua:203-212`), suggesting a load-order workaround. It deserves a later focused check, not a broad keymap rewrite.
- Keep Oil as the easy/default explorer if that is current muscle memory; Neo-tree can remain available for its alternate tree view. The current two-explorer setup need not be removed to make the map clearer.
- `<leader>q` is now `:wq!` as requested. It writes the current buffer and quits; the forced-write behavior is an explicit user choice, not a remaining `:q!` mapping.

The personal map remains authored in `env/.config/nvim`; `/home/pontual/.config/nvim` is the deployed canonical tree. The inactive PontuArch env copy is not the owner.

## Recommended order for any later changes

1. The exact Ctrl-Alt-Delete bulk-close chord is removed; Neovim `<leader>q` now writes before quitting. Record tmux `Ctrl-F+d` and Herdr `confirm_close=false` as retained high-impact behavior; no change requested.
2. Keep the existing tmux/Herdr navigation contract while reviewing any specific terminal interception or destructive action in context; no broad navigation remap is proposed here.
3. Root Ctrl-T/Ctrl-R remain unchanged as requested; their editor/shell cost is documented above.
4. Correct which-key labels and review the repeated Neogit `<leader>gs` deletion workaround.

## Installed stock versus current first-class routes

The full installed stock declaration list, including overridden entries and loop templates, is recorded in `keybindings-inventory/omarchy-stock-binding-declarations.txt`. This table compares that stock with the deployed user map; it does not propose changes to tmux, Herdr, or unrelated window/workspace navigation.

| Action | Installed stock | Current deployed route | Details / displaced route |
|---|---|---|---|
| Terminal | `Super+Return` | `Super+Space` | Uses Omarchy's `{ omarchy = "terminal" }` launcher. |
| Personal Spotlight | No stock Spotlight action; `Super+Space` opens searchable Omarchy root menu | `Super+Return` opens personal `pontual.search` | Personal search, not an Omarchy stock action. |
| Omarchy root menu | `Super+Space` | `Super+M` | Searchable root menu; `Super+Alt+Space` Apps menu remains available. |
| File manager | `Super+Shift+F` stock manager; `Super+Alt+Shift+F` at terminal cwd | `Super+E` Strata; legacy `Super+Alt+F` Strata-home and `Super+Alt+Shift+F` cwd aliases remain | Strata is a personal integration. Legacy `Super+Alt+F` still replaces stock full-width; it is a separate retained alias, not a competing action on `Super+E`. |
| Fullscreen / maximize | `Super+F` fullscreen; `Super+Ctrl+F` tiled fullscreen; `Super+Alt+F` full-width | `Super+F` fullscreen; `Super+Shift+F` maximize; `Super+Ctrl+F` tiled fullscreen | Preserves both actions with fullscreen on the stock simple chord. |
| System menu | `Super+Escape` | `Super+Escape` | `Super+X` remains the personal Session and power menu; no universal cut was added on `Super+X`. |
| Screenshot | `Print` smart screenshot; `Super+P` pseudo-window | `Super+P` region screenshot; `Print` region alias remains; `Alt+Print` window/monitor picker; `Ctrl+Print` fullscreen; `Ctrl+Alt+Print` recording | User has no physical Print key, so `Super+P` is the direct capture route. `Super+Shift+P` and the Window/Workspace menu retain pseudo-window. `Super+Print` remains stock color picker; `Super+Ctrl+Print` remains OCR. |
| Theme picker | `Super+Ctrl+Shift+Space` | `Super+T` opens `style.theme` using the user's compact picker; stock chord remains | Opens picker; it does not switch a theme until selection. |
| Task launcher and dashboard | No stock task sessionizer or personal tasks dashboard | `Super+S` launches the existing task-sessionizer popup; `Super+D` opens the existing Tasks and sessions dashboard | Development category moved from `Super+D` to `Super+Shift+D`. The old `Super+Shift+S` dashboard route is removed; no new UI was added. |
| Universal copy | `Super+C` injects Ctrl-C in GUI or Ctrl-Insert in terminal | `Super+C` | Tag-aware focused-surface `send_key_state` helper; no virtual keyboard injection. |
| Universal paste | `Super+V` injects Ctrl-V in GUI or Shift-Insert in terminal | `Super+V` | Ghostty now maps Shift-Insert to `paste_from_clipboard` (not PRIMARY selection), so terminal Super+V uses regular clipboard. This is a convenience path; `Ctrl-F p` still loads Wayland clipboard bytes directly into tmux. |
| Clipboard history | No stock history chord; `Super+Ctrl+V` clipboard manager | `Super+Y` personal clipboard history; `Super+Ctrl+V` stock manager | Moved from personal `Super+Shift+V`; no longer assigned there. |
| Displaced menus | Stock Docker is `Super+Shift+D`; stock Communication/Entertainment/Pseudo/Maps use `Super+Shift+C/E/P/S` | Development category `Super+Shift+D`, Communication `Super+Shift+C`, Entertainment `Super+Shift+E`, pseudo-window `Super+Shift+P` | The stock Maps chord `Super+Shift+S` is unbound by the personal launcher; menu entries and `Super+/` keybinding help retain discoverability. The existing Development menu is preserved. |

This map is deployed and runtime-visible. It keeps `Super+Escape` System menu, existing window/workspace navigation, and tmux/Herdr contracts untouched. The Omarchy Apps menu remains on `Super+Alt+Space` and under the searchable root menu.

### Native utility action catalog (separate from first-class app routes)

These are useful installed Omarchy actions, not personal Spotlight/Tasks/Strata features. Keep the catalog separate from the proposed single-key app routes above:

| Native utility | Installed stock route | Current effective route / note |
|---|---|---|
| Capture and OCR | `Print` smart screenshot; `Super+Ctrl+Print` OCR | User has no physical Print key; region capture is on `Super+P`. Print alias and OCR remain; window/monitor, fullscreen and recording have separate routes. |
| Color picker | `Super+Print` | Same stock route; this map does not displace it. |
| Screen recording | `Alt+Print` stock toggle | Personal `Ctrl+Alt+Print` recording; Alt+Print is the window/monitor picker. |
| Clipboard manager/history | `Super+Ctrl+V` manager; no stock history shortcut | `Super+Ctrl+V` manager; personal history moved to `Super+Y`. Universal paste on `Super+V` injects Shift-Insert in terminals; Ghostty routes it to regular clipboard. tmux `Ctrl-F p` remains direct Wayland-to-buffer paste. |
| Notifications | `Super+Shift+Alt+Comma` calls `showHistory` (toast replay); other Super+Comma variants invoke/dismiss/silence | Personal Foamy notification archive is the archive UI; native daemon, toast replay and dismissal remain separate native behaviors. |
| Nightlight / lock | `Super+Ctrl+N` nightlight; `Super+Ctrl+L` lock | Nightlight stays stock; personal lock is `Super+Alt+L`. |
| System panels | `Super+Ctrl+A/B/D/W/P` audio, Bluetooth, display, network and power | Native controls remain; the user Quick Settings submenu is an additional personal route. |
| Focus and workspaces | `Alt+Tab` focus-cycle/raise; `Super+1..9` workspace selection | Stock composition and workspace routes remain; no proposed navigation remap. |

## Applied changes and verification

The approved map is authored in `env/.config/hypr/bindings.lua`; the accompanying terminal change is `env/.config/ghostty/config`. Initial deployment backup: `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T161222.482747208Z` (`complete=yes`, two paths). A focused ordering correction is backed up at `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T161343.623893051Z` (`complete=yes`, one path). Latest task-dashboard mapping backup: `/home/pontual/.local/state/dotfiles/backups/omarchy-workstation/apply-20261013T161821.154381628Z` (`complete=yes`, one path).

Hyprland reload succeeded and `hyprctl configerrors` is empty. The current keybinding menu shows `Super+S` Task sessionizer, `Super+D` Tasks and sessions, and `Super+Shift+D` Development, alongside the other first-class routes and secondary Entertainment, Communication, and pseudo-window routes. The previous `Super+Shift+S` dashboard route is absent. Runtime count is 263 bindings / 262 menu rows; bare Ctrl-Alt-Delete is absent, while the distinct laptop-display-mirroring Super chord remains. Ghostty was reloaded with `omarchy restart terminal`; its process remained running and effective config reports `shift+insert=paste_from_clipboard` plus `ctrl+shift+v=paste_from_clipboard`. No clipboard contents or MIME data were read or changed, and no paste was sent to a user application; verification is source and effective-binding based. `Ctrl-F+d`, `Ctrl-F+p`, Ctrl-T/R and Neovim `<leader>q` remain unchanged. `scripts/envctl diff --host omarchy-workstation` reports zero paths differing.

The complete inventory has 263 effective Hyprland bindings, 262 readable menu rows, 194 packaged stock declarations (including overridden rows and source loop templates), and 74 current Ghostty keybind rows. Full authored, runtime, package-default, and all-loaded-buffer Neovim metadata inventories are linked above.
