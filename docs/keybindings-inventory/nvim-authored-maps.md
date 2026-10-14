# Authored Neovim keymap inventory

Source is the deployed canonical `env/.config/nvim`; the live `/home/pontual/.config/nvim` tree matches it. `<leader>` is Space. This source inventory complements `nvim-live-rpc.json`, which records runtime maps from the five existing servers. Lazy-loaded/plugin-spec maps may not be installed in every server until their plugin loads.

## Core maps: `lua/brenocrs/remap.lua`

| Mode | Map | Action | Notes |
|---|---|---|---|
| Normal | `<leader>s` | `:w` | Save |
| Normal | `<leader>q` | `:wq!` | Write current buffer, then quit current window |
| Visual | `J`, `K` | Move selected lines down/up | Reselects and reindents |
| Normal | `Ctrl-D`, `Ctrl-U` | Page down/up and center cursor | Vim motions preserved with `zz` |
| Visual | `<leader>p` | Paste without replacing unnamed register | Deletes selected text to blackhole first |
| Normal/Visual | `n` | No-search-aware expression mapping | Echoes when search is empty, otherwise advances search |
| Normal | `<leader>rw` | Replace word under cursor | Interactive replacement prompt |
| Normal | `<leader>wo` | Close other windows | Maps to built-in `Ctrl-W o` |
| Normal | `<leader>wh/wj/wk/wl` | Focus window left/down/up/right | Maps to built-in `Ctrl-W` motions |
| Normal/Operator/Visual | `&` | `^` | First nonblank |
| Normal/Operator/Visual | `$` | `g_` | Last nonblank |
| Normal | `<leader>P` | Paste system clipboard | Temporarily enables paste option |

## LazyLoad maps: `lua/brenocrs/plugin-keymaps.lua`

| Plugin / scope | Mode | Maps | Action |
|---|---|---|---|
| Oil, after `oil.nvim` LazyLoad | Normal | `<leader>o` | Open Oil |
| Noice, after `noice.nvim` LazyLoad | Normal | `<leader>nl` | Open Noice message view |
| Undotree, after load | Normal | `<leader>u` | Toggle undo tree |
| Grapple, after load | Normal | `<leader>a`, `<leader>e`, `<leader>1..5` | Toggle current tag, toggle tag list, jump to numbered tag |
| Telescope, after load | Normal | `<leader>fa`, `ff`, `fh`, `fc` | Find files in home, cwd, help tags, Neovim config |
| Telescope, after load | Normal | `<leader>fb`, `fw`, `fW` | Search word under cursor in current file, cwd, cwd using WORD |
| Telescope, after load | Normal | `<leader>fG`, `fg` | Interactive grep current file, multi-grep from cwd (supports pattern plus glob) |
| Neogit, global | Normal | `<leader>gm`, `gp`, `go`, `gb`, `gD` | Open Neogit split, push, push and set upstream, choose/create branch, delete merged branches |
| Neogit buffer | Normal | `<leader>gp`, `<leader>go` | Push actions also available within Neogit buffers |
| Trouble, after load | Normal | `Ctrl-N`, `Ctrl-P` | Next/previous Trouble item only while Trouble is open; otherwise no-op |
| Trouble, after load | Normal | `<leader>cq`, `<leader>tt`, `<leader>th`, `<leader>tf` | Clear quickfix, toggle diagnostics, buffer diagnostics, quickfix views |
| UFO folding, after load | Normal | `<leader>do`, `<leader>dF`, `<leader>da` | Open all folds, close all folds, toggle all folds |
| UFO editor buffers | Normal, buffer-local | `Enter` | Toggle fold in supported editable buffers |
| Neo-tree, after load | Normal | `<leader>nt` | Toggle/reveal tree, with special handling from Oil buffers |
| Go tags, Go buffers | Visual, buffer-local | `<leader>tg`, `<leader>tgr` | Add/remove Go tags |
| SQLFluff, global | Normal | `<leader>lf` | Prompt dialect and run SQLFluff fix on current file |
| 99, after load | Visual | `<leader>vp` | Invoke 99 visual selection action |

The unusual `gD` in Neogit is `<leader>gD`, distinct from the plain normal-mode LSP `gD` declaration map.

## Plugin-spec maps outside `plugin-keymaps.lua`

| Plugin | Mode | Map | Action |
|---|---|---|---|
| Mason/LSP `on_attach` | Normal, buffer-local | `<leader>fr`, `<leader>fi`, `<leader>rn` | References, implementations, rename |
| Mason/LSP `on_attach` | Normal, buffer-local | `gd`, `gD`, `K` | Definition, declaration, hover; no leader prefix |
| Dadbod | Normal, lazy key | `<leader>db`, `<leader>df` | Toggle DB UI, find DB buffer |
| GitGraph | Normal, lazy key | `<leader>gl` | Draw graph |
| Blink completion | Insert | `Ctrl-K`, `Ctrl-J`, `Ctrl-Space`, `Ctrl-H` | Previous/next item, accept completion, show/hide docs (with configured fallbacks) |
| Telescope picker | Insert | `Ctrl-I` | Trouble quickfix integration |
| Ultimate-autopair | Insert/command | `Ctrl-E`, `Ctrl-L` | Plugin-specific pair actions |

## Descriptions versus mappings

`lua/plugins/which-key.lua` contains discoverability labels, not all actual maps. Current mismatches include `<leader>gP` labeled Pull-Rebase without a matching mapping, `<leader>dt` labeled Toggle Fold while fold actions are `do/dF/da`, and a broad `<leader>r` “Refactor” group containing word replacement and LSP rename. The `<leader>gs` Neogit map is actively deleted immediately, scheduled, and again after 500 ms in `plugin-keymaps.lua`; preserve that workaround until its load-order cause is understood.

## Runtime coverage and limits

The live RPC file contains global mappings by mode and every valid loaded buffer's maps across all five active sockets. Buffer IDs and filetypes are included; names and text are omitted. Callback entries are marked as callbacks rather than serialized as functions. This is a point-in-time runtime inventory: unloaded lazy plugins and unentered filetype/autocmd contexts are represented by their source declarations above, not claimed as active in every session. Built-in Vim commands remain available unless a specific mapping overrides them; this table only enumerates the configured mappings and does not attempt to list Vim's whole command vocabulary.
