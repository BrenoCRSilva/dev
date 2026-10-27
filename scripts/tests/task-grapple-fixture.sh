#!/usr/bin/env bash
# brenocrs/task-grapple.lua with the installed grapple.nvim, in a headless nvim
# whose data folder is temporary: a task root gets one "task"-scope tag per
# worker in .task-worker-order, the user's cwd scope stays empty, and a new
# order file (written by rename, like task-sessionizer.sh) drops a removed repo
# and keeps a tag the user added.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
GRAPPLE="$HOME/.local/share/nvim/lazy/grapple.nvim"
[[ -d "$GRAPPLE" ]] || { printf 'grapple.nvim is not installed at %s\n' "$GRAPPLE" >&2; exit 1; }
command -v nvim >/dev/null || { printf 'nvim is required\n' >&2; exit 1; }
TMP=$(mktemp -d)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)" "$TMP"' EXIT

task="$TMP/task"
mkdir -p "$task/api" "$task/web" "$TMP/data" "$TMP/state"
printf 'api\nweb\nmissing\n' > "$task/.task-worker-order"
: > "$task/AGENTS.md"
cat > "$TMP/init.lua" <<EOF
vim.opt.rtp:prepend("$GRAPPLE")
vim.opt.rtp:prepend("$ROOT/env/.config/nvim")
require("grapple").setup({ scope = "cwd" })
require("brenocrs.task-grapple").setup()
EOF
cat > "$TMP/check.lua" <<EOF
local grapple = require("grapple")
local function names()
	local out = {}
	for _, t in ipairs(grapple.tags({ scope = "task" })) do
		table.insert(out, t.name or vim.fn.fnamemodify(t.path, ":t"))
	end
	return table.concat(out, ",")
end
local function check(cond, msg)
	if not cond then
		io.stderr:write("FAIL: " .. msg .. "\n")
		vim.cmd("cquit 1")
	end
end
check(names() == "api,web", "seeded tags were " .. names())
check(grapple.app().settings.scope == "task", "task nvim does not use the task scope")
check(#grapple.tags({ scope = "cwd" }) == 0, "tags leaked into the cwd scope")
grapple.tag({ path = "$task/AGENTS.md", scope = "task" })
-- A repo is removed: the order file is replaced by a rename.
vim.fn.writefile({ "web" }, "$task/.task-worker-order.tmp")
vim.uv.fs_rename("$task/.task-worker-order.tmp", "$task/.task-worker-order")
check(vim.wait(3000, function() return names() == "web,AGENTS.md" end, 50), "refresh left " .. names())
-- Opening the same root again keeps the tags (saved per task, not per cwd).
vim.cmd("qall!")
EOF
(cd "$task" && XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" \
    nvim --headless -u "$TMP/init.lua" -c "luafile $TMP/check.lua")
out=$(cd "$task" && XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" nvim --headless -u "$TMP/init.lua" \
    -c 'lua io.stdout:write(#require("grapple").tags({ scope = "task" }) .. "\n")' -c 'qall!' 2>&1)
[[ "$out" == *2* ]] || { printf 'FAIL: tags were not kept across starts: %s\n' "$out" >&2; exit 1; }
# Outside a task root nothing changes.
mkdir -p "$TMP/plain"
out=$(cd "$TMP/plain" && XDG_DATA_HOME="$TMP/data" XDG_STATE_HOME="$TMP/state" nvim --headless -u "$TMP/init.lua" \
    -c 'lua io.stdout:write(require("grapple").app().settings.scope .. "\n")' -c 'qall!' 2>&1)
[[ "$out" == *cwd* ]] || { printf 'FAIL: a plain folder switched scope: %s\n' "$out" >&2; exit 1; }
printf 'PASS: task Grapple scope seeds worker tags, follows .task-worker-order, keeps user tags, and leaves plain folders alone\n'
