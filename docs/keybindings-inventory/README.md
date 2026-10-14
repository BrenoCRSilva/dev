# Binding inventory snapshots

Read-only snapshots collected on 2026-10-13 from the running Omarchy desktop and deployed user configuration. Commands and methods:

- `tmux-list-keys-all.txt`: `tmux list-keys -a` (all active tmux tables; 280 lines).
- `herdr-default.toml`: `herdr --default-config` from Herdr 0.8.2. `herdr-user.toml` is the authored/deployed explicit user config (102 lines); the default file contains the full built-in schema/defaults.
- `hyprland-binds-runtime.json`: read-only runtime snapshot (263 entries, captured before the current task-picker change). `omarchy-menu-keybindings.txt` is the corresponding `omarchy menu keybindings --print` output (262 rendered entries; that interface resolves Lua callback bindings whose physical key is missing from Hyprland's JSON row). The current prepared worktree removes the Tasks and sessions dashboard, leaves `Super+D` free, and keeps `Super+S` as the task picker and `Super+Shift+D` as Development. The raw snapshots remain historical evidence until the map is deployed and recaptured.
- `omarchy-stock-binding-declarations.txt`: all installed packaged default Hyprland binding declarations from `/usr/share/omarchy/default/hypr/bindings/*.lua`, including bindings overridden by the user and loop templates.
- `ghostty-default-keybinds.txt`: all 72 `ghostty +show-config --default` keybind rows. `ghostty-current-keybinds.txt`: all 74 keybind rows in the current `ghostty +show-config` resolved output. The current config includes Omarchy's generated theme config and the authored `Shift+Insert=paste_from_clipboard` override; this is runtime effective-config output, not only lines from the authored Ghostty file. Clipboard payload was not read or exercised.
- `nvim-live-rpc.json`: read-only keymap metadata queried over all five active Neovim sockets. It contains global mappings for modes `n,v,x,s,o,i,c,t,l`, plus buffer-local mappings for every valid loaded buffer. It stores buffer number and filetype, never buffer names or contents. Key and RHS strings are display-sanitized; callbacks are represented as booleans. Lazy plugin specs not loaded in a server are inventoried separately from source.
- `nvim-authored-maps.md`: full authored/core, LazyLoad and plugin-spec map inventory, with scope, mode, action and source notes.

The authored binding sources live in `../..` under `env/.config/`. Runtime/default snapshots may include package defaults and plugin-generated maps, not just authored mappings. Inactive standalone binding fragments are excluded from the effective Hyprland inventory.

The captured tmux `prefix+C` entry was replaced with the stock `new-window`
binding after removing the unavailable external command it previously invoked.

The audit and applied desktop map is [../keybindings-audit.md](../keybindings-audit.md).
