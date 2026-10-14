#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$tmp"' EXIT

lazy_root="$HOME/.local/share/nvim/lazy"
[[ -d "$lazy_root/lazy.nvim" ]] || { printf 'installed lazy.nvim plugin tree is missing\n' >&2; exit 1; }
mkdir -p "$tmp/home" "$tmp/config" "$tmp/data/nvim" "$tmp/state" "$tmp/cache" "$tmp/project"
cp -a "$repo/env/.config/nvim" "$tmp/config/nvim"
ln -s "$lazy_root" "$tmp/data/nvim/lazy"
[[ ! -d "$HOME/.local/share/nvim/mason" ]] || ln -s "$HOME/.local/share/nvim/mason" "$tmp/data/nvim/mason"

# Exercise the deployed Omarchy palette in the isolated process without
# pointing Neovim at or writing into the user's real state directory.
mkdir -p "$tmp/state/omarchy/current/theme"
cp "$HOME/.local/state/omarchy/current/theme.name" "$tmp/state/omarchy/current/theme.name"
cp "$HOME/.local/state/omarchy/current/theme/nvim-palette.lua" "$tmp/state/omarchy/current/theme/nvim-palette.lua"

# Use the staged config and installed plugin tree, but prevent the temporary
# smoke process from checking the network or installing parser packages.
sed -i 's/checker = { enabled = true/checker = { enabled = false/' "$tmp/config/nvim/lua/brenocrs/lazy.lua"
sed -i 's/auto_install = true/auto_install = false/' "$tmp/config/nvim/lua/plugins/treesitter.lua"

cat > "$tmp/project/one.lua" <<'EOF'
local value = 1
return value
EOF
cat > "$tmp/project/two.lua" <<'EOF'
local value = 2
return value
EOF
cat > "$tmp/project/view.qml" <<'EOF'
import QtQuick
Item {}
EOF
printf 'plain text buffer\n' > "$tmp/project/notes.txt"
cat > "$tmp/smoke.vim" <<'VIM'
lua vim.wait(5000, function() return #vim.lsp.get_clients() >= 2 end, 50)
lua vim.fn.writefile({vim.g.colors_name or "<unset>"}, vim.env.DOTFILES_SMOKE_COLORSCHEME)
lua vim.g.messages_after_first = vim.fn.execute("messages")
execute 'edit ' . fnameescape($DOTFILES_FILE_TWO)
lua vim.wait(3000, function() return #vim.lsp.get_clients() >= 2 end, 50)
lua vim.g.messages_after_second = vim.fn.execute("messages")
execute 'edit ' . fnameescape($DOTFILES_FILE_TEXT)
lua vim.wait(500)
lua vim.g.messages_after_generic = vim.fn.execute("messages")
execute 'edit ' . fnameescape($DOTFILES_FILE_QML)
lua vim.wait(8000, function() for _, c in ipairs(vim.lsp.get_clients()) do if c.name == "qmlls" then return true end end return false end, 50)
lua local clients={}; for _, c in ipairs(vim.lsp.get_clients()) do clients[#clients+1]=c.name end; local summary="attached clients: " .. table.concat(clients, ","); local m=vim.fn.execute("messages"); local snapshots={"after first Lua open:\n"..(vim.g.messages_after_first or ""), "after second Lua open:\n"..(vim.g.messages_after_second or ""), "after generic text open:\n"..(vim.g.messages_after_generic or ""), "after QML open:\n"..m}; local report=table.concat(snapshots, "\n"); vim.fn.writefile(vim.split(report, "\n", {plain=true}), vim.env.DOTFILES_SMOKE_MESSAGES); print("MESSAGES_BEGIN\n" .. report .. "\nMESSAGES_END"); print(summary)
qa!
VIM

DOTFILES_SMOKE_MESSAGES="$tmp/messages.txt" \
DOTFILES_SMOKE_COLORSCHEME="$tmp/colorscheme.txt" \
DOTFILES_FILE_TWO="$tmp/project/two.lua" DOTFILES_FILE_TEXT="$tmp/project/notes.txt" \
DOTFILES_FILE_QML="$tmp/project/view.qml" \
HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/config" XDG_DATA_HOME="$tmp/data" \
XDG_STATE_HOME="$tmp/state" XDG_CACHE_HOME="$tmp/cache" \
nvim --headless -i NONE -u "$tmp/config/nvim/init.lua" "$tmp/project/one.lua" -S "$tmp/smoke.vim"

# Report exact relevant diagnostics; fail on the previously confirmed launch
# errors without suppressing other warnings from :messages.
if rg -n -v '^after (first Lua|second Lua|generic text|QML) open:$|^$' "$tmp/messages.txt"; then
	printf 'staged full-startup smoke found messages during sequential file opens\n' >&2
	exit 1
fi
if rg -ni 'stylua is not executable|failed to spawn|libodbc\.so\.2|qmlls.*(not found|failed)|lua_ls.*failed' "$tmp/messages.txt"; then
	printf 'staged full-startup smoke found a confirmed server launch error\n' >&2
	exit 1
fi
if [[ "$(cat "$tmp/colorscheme.txt")" != gruvbox ]]; then
	printf 'staged full-startup smoke did not select the active Omarchy Gruvbox scheme (got %s)\n' "$(cat "$tmp/colorscheme.txt")" >&2
	exit 1
fi
printf 'staged full-startup smoke passed; :messages was empty after sequential Lua, generic text, and QML opens\n'
