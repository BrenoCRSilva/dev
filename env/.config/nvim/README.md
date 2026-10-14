# Neovim Configuration

Modern Neovim configuration built with Lua, focused on development productivity. Designed to work seamlessly with tmux for terminal multiplexing.

## Requirements

- Neovim 0.11.3+
- Git
- Node.js (for LSP servers)
- ripgrep (for telescope)
- A Nerd Font
- Cargo (for blink.cmp build)
- **tmux** (recommended for optimal workflow)

## Installation

```bash
# Backup existing config
mv ~/.config/nvim ~/.config/nvim.backup

# Clone configuration
git clone https://github.com/BrenoCRSilva/neovimrc ~/.config/nvim

# Start Neovim (plugins will auto-install)
nvim
```

## Tmux Integration

This configuration is designed for tmux with project-based session management.

### Recommended Setup
Use [tmux-sessionizer](https://github.com/ThePrimeagen/tmux-sessionizer) for session management:
- **Sessions** = Projects (one session per codebase)
- **Windows** = Tabs (editor, terminal, logs, etc.)
- **Grapple tags** and **Telescope** are session-scoped

### Why Session-Scoped?
- **Grapple** maintains separate tag lists per tmux session
- **Telescope** searches within session's working directory
- Each project gets isolated file navigation and tagging

## Project Structure

```
nvim/
├── init.lua
└── lua/
    ├── config/
    │   ├── options.lua
    │   ├── keymaps.lua
    │   └── lazy.lua
    └── plugins/
        ├── blink-cmp.lua
        ├── lualine.lua
        ├── lsp.lua
        ├── noice.lua
        ├── telescope.lua
        ├── trouble.lua
        └── ...
```

## Core Plugins

### Completion Engine
**[blink.cmp](https://github.com/saghen/blink.cmp)**
- High-performance completion engine written in Rust
- Copilot integration via blink-copilot
- LuaSnip snippet support
- Built-in cmdline completion

**Key Features:**
- Ghost text completion
- Auto documentation with configurable borders
- Multi-source completion (LSP, Copilot, snippets, buffer, path)
- Custom direction priority for completion menu

**Key Mappings:**
- `<C-k>` - Previous completion
- `<C-j>` - Next completion  
- `<C-Space>` - Accept completion
- `<C-h>` - Show/hide documentation

**Dependencies:**
- `rafamadriz/friendly-snippets` - Snippet collection
- `fang2hou/blink-copilot` - GitHub Copilot integration
- `Exafunction/codeium.nvim` - Codeium AI integration
- `L3MON4D3/LuaSnip` - Snippet engine

**Configuration:** `lua/plugins/blink-cmp.lua`

### Language Server Protocol
**[mason-lspconfig.nvim](https://github.com/williamboman/mason-lspconfig.nvim)**
- Automatic LSP server management
- Integrated tool installer
- Custom diagnostic configuration

**Configured Language Servers:**
- `lua_ls` - Lua with Neovim API support
- `pyright` - Python
- `gopls` - Go
- `ts_ls` - TypeScript/JavaScript
- `bashls` - Bash/Shell
- `postgres_lsp` - PostgreSQL (via postgrestools)

**Auto-installed Tools:**
- `bash-language-server`, `shellcheck`
- `golangci-lint`, `goimports`, `gofumpt`, `golines`, `gomodifytags`, `gotests`
- `prettier`, `eslint`
- `postgrestools`
- `stylua`, `luacheck`

**Key Mappings:**
- `<leader>fr` - Find LSP references (Telescope)
- `<leader>fi` - Find LSP implementations (Telescope)
- `<leader>rn` - Rename symbol
- `gD` - Go to declaration
- `gd` - Go to definition
- `K` - Show hover documentation

**Diagnostic Configuration:**
- Severity sorting enabled
- Virtual text at end of line
- Custom diagnostic signs (error, warn, hint, info)

**Configuration:** `lua/plugins/lsp.lua`

### Status Line
**[lualine.nvim](https://github.com/nvim-lualine/lualine.nvim)**
- Minimalist status line with custom sections
- Oil.nvim path formatting
- Grapple integration for file tagging

**Sections:**
- `lualine_a` - Mode indicator
- `lualine_b` - Grapple tags
- `lualine_c` - Filename with custom Oil path formatting
- `lualine_x` - LSP diagnostics
- `lualine_y` - File progress
- `lualine_z` - Cursor location

**Features:**
- Auto theme detection
- Clean separators
- Oil path preprocessing (removes `oil:///` prefix, converts `/home` to `~`)

**Dependencies:**
- `echasnovski/mini.icons` - Icon support

**Configuration:** `lua/plugins/lualine.lua`

### Enhanced UI
**[noice.nvim](https://github.com/folke/noice.nvim)**
- Modern command line interface
- Enhanced notifications
- Improved LSP hover and signature help

**Features:**
- Centered command palette (40% row, 50% column)
- Transparent command line (20% blend)
- Custom LSP hover with single borders (max 80x20)
- Enhanced markdown rendering
- Bottom search, command palette, long message splitting

**Notification Configuration:**
- Black background for notifications
- Integration with nvim-notify

**Dependencies:**
- `MunifTanjim/nui.nvim` - UI components
- `rcarriga/nvim-notify` - Notification system

**Key Mappings:**
- `<leader>nl` - Open Noice interface

**Configuration:** `lua/plugins/noice.lua`

### Fuzzy Finder
**[telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)**
- Advanced file and text searching
- Custom multi-grep functionality
- Trouble.nvim integration
- FZF native sorting

**Custom Features:**
- Multi-grep: Search with pattern and file filter (`pattern  file_pattern`)
- Trouble integration for quickfix results
- Ascending sort with top prompt position

**Key Mappings:**
- `<leader>ff` - Find files (current directory)
- `<leader>fa` - Find files (home directory, including hidden)
- `<leader>fc` - Find files (Neovim config directory)
- `<leader>fh` - Help tags
- `<leader>fb` - Grep word under cursor in current file
- `<leader>fw` - Grep word under cursor (workspace)
- `<leader>fW` - Grep WORD under cursor (workspace)
- `<leader>fg` - Multi-grep with custom finder
- `<C-i>` - Send results to Trouble quickfix

**Dependencies:**
- `nvim-lua/plenary.nvim` - Utility functions
- `telescope-fzf-native.nvim` - FZF sorter (requires make)
- `echasnovski/mini.icons` - Icons

**Configuration:** `lua/plugins/telescope.lua`

### Diagnostics and Quickfix
**[trouble.nvim](https://github.com/folke/trouble.nvim)**
- Enhanced diagnostics viewer
- Quickfix list management
- Custom exclusive toggle system

**Modes:**
- `diagnostics` - Workspace diagnostics
- `buffer_diagnostics` - Current buffer diagnostics  
- `quickfix` - Quickfix list items

**Features:**
- Auto-close when jumping to location
- No grouping or indent lines for cleaner view
- Exclusive toggle (only one mode open at a time)
- Custom navigation shortcuts

**Key Mappings:**
- `<leader>tt` - Toggle workspace diagnostics
- `<leader>th` - Toggle buffer diagnostics
- `<leader>tf` - Toggle quickfix
- `<leader>cq` - Clear quickfix list
- `<C-n>` - Next item (when Trouble is open)
- `<C-p>` - Previous item (when Trouble is open)
- `<CR>` - Jump to item
- `<Esc>` - Close Trouble

**Configuration:** `lua/plugins/trouble.lua`

### Custom Go Tags Plugin
**Local Plugin: Go Struct Tags Management**
- Add/remove struct tags for Go development
- Support for multiple tag types (json, xml, yaml, toml, db)
- Snake case conversion
- Private field filtering

**Features:**
- Automatic snake_case conversion from field names
- Preserves existing tags and comments
- Visual mode support for multiple lines
- Smart alignment based on longest line
- Configurable private field skipping

**Key Mappings:**
- `<leader>tg` - Add Go tags (visual mode)
- `<leader>tgr` - Remove Go tags (visual mode)

**Supported Tags:**
- `json` - JSON serialization
- `xml` - XML serialization  
- `yaml` - YAML serialization
- `toml` - TOML serialization
- `db` - Database column mapping

**Configuration:** Custom module in lua directory

## Global Key Mappings

### File Operations
| Key | Action |
|-----|--------|
| `<leader>o` | Open Oil file manager |
| `<leader>s` | Save file |
| `<leader>q` | Force quit |

### Text Manipulation
| Key | Action | Mode |
|-----|--------|------|
| `J` | Move line down | Visual |
| `K` | Move line up | Visual |
| `<C-d>` | Page down + center | Normal |
| `<C-u>` | Page up + center | Normal |
| `<leader>p` | Paste without overwriting register | Visual |

### Window Management
| Key | Action |
|-----|--------|
| `<leader>wo` | Close other windows |
| `<leader>wl` | Move to right window |
| `<leader>wk` | Move to up window |
| `<leader>wh` | Move to left window |

### Navigation
| Key | Action | Mode |
|-----|--------|------|
| `*` | Go to line start | Normal/Visual/Operator |
| `$` | Go to line end (excluding whitespace) | Normal/Visual/Operator |

## Language Support

### Pre-configured Languages
- **Go** - gopls, formatting tools, linting, struct tag management
- **TypeScript/JavaScript** - ts_ls, prettier, eslint
- **Python** - pyright
- **Lua** - lua_ls with Neovim support, stylua
- **Bash/Shell** - bashls, shellcheck
- **SQL** - postgres_lsp via postgrestools

### Adding New Languages
1. Install language server via `:Mason`
2. Add to `ensure_installed` in `lua/plugins/lsp.lua`
3. Configure server with `vim.lsp.config()`

## Customization

### Adding Plugins
Create new file in `lua/plugins/`:

```lua
return {
  "author/plugin-name",
  dependencies = { "required-dep" },
  config = function()
    require("plugin-name").setup({})
  end,
}
```

### LSP Configuration
Add server in `lua/plugins/lsp.lua`:

```lua
vim.lsp.config("server_name", {
  on_attach = on_attach,
  settings = {
    -- server settings
  }
})
```

### Key Mappings
Add to `lua/config/keymaps.lua`:

```lua
vim.keymap.set("n", "<leader>x", "<cmd>Command<CR>")
```

## Troubleshooting

### Plugin Issues
```bash
# Clear plugin cache
rm -rf ~/.local/share/nvim/lazy
nvim
```

### LSP Problems
- Check server status: `:LspInfo`
- Install missing servers: `:Mason`
- View logs: `:LspLog`

### Completion Not Working
- Verify blink.cmp build: `:checkhealth blink`
- Rebuild if needed: `:Lazy build blink.cmp`

### Performance Issues
- Profile startup: `nvim --startuptime startup.log`
- Check plugin load times: `:Lazy profile`

## License

MIT License
