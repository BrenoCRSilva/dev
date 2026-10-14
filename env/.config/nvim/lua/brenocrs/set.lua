-- Leader key (must be set before plugins load)
vim.g.mapleader = " "

-- ============================================
-- EDITOR BEHAVIOR
-- ============================================

-- Line numbers
vim.o.nu = true
vim.o.relativenumber = false
vim.o.cursorline = true
vim.o.cursorlineopt = "number"

-- Indentation
vim.o.tabstop = 4
vim.o.softtabstop = 4
vim.o.shiftwidth = 4
vim.o.expandtab = true
vim.o.smartindent = true

-- Inherit
vim.g.editorconfig = true

-- Search
vim.o.hlsearch = false

-- Scrolling & viewport
vim.o.scrolloff = 8
vim.o.wrap = false
vim.o.virtualedit = "block"

-- UI & appearance
vim.o.termguicolors = true
vim.o.ruler = false
vim.o.fillchars = [[eob: ,fold: ,foldopen:,foldsep: ,foldclose:,vert:│,horiz:─,horizup:┴,horizdown:┬,vertleft:┤,vertright:├,verthoriz:┼]]

-- Performance
vim.o.updatetime = 50

-- ============================================
-- FILE MANAGEMENT
-- ============================================

vim.o.swapfile = false
vim.o.backup = false
vim.o.undofile = true
vim.o.undodir = os.getenv("HOME") .. "/.nvim/undodir"

-- ============================================
-- FOLDING (UFO)
-- ============================================

vim.o.foldcolumn = "1"
vim.o.foldlevel = 99
vim.o.foldlevelstart = 99
vim.o.foldenable = true

-- ============================================
-- CLIPBOARD (Wayland)
-- ============================================

vim.o.clipboard = "unnamedplus"
vim.g.clipboard = {
	name = "wl-clipboard",
	copy = {
		["+"] = "wl-copy",
		["*"] = "wl-copy",
	},
	paste = {
		["+"] = "wl-paste --no-newline",
		["*"] = "wl-paste --no-newline",
	},
	cache_enable = 0,
}

-- Keep the local wl-clipboard provider above; remote sessions conditionally
-- switch to OSC 52 while preserving local paste where a Wayland clipboard exists.
require("brenocrs.remote_clipboard").setup()

-- ============================================
-- SHELL
-- ============================================

vim.o.shell = os.getenv("SHELL")

-- ============================================
-- PLUGIN CONFIGURATION
-- ============================================

-- Undotree
vim.g.undotree_SetFocusWhenToggle = 1
vim.g.undotree_DiffpanelHeight = 0

-- Netrw
vim.g.netrw_banner = 0
vim.g.netrw_winsize = 25

-- ============================================
-- TASK ROOT (~/tasks/<task> holding one worktree per repo)
-- ============================================

-- AGENTS.md and no .git: cwd is a multi-repo task root, not a repo.
do
	local cwd = vim.uv.cwd()
	if cwd and vim.uv.fs_stat(cwd .. "/AGENTS.md") and not vim.uv.fs_stat(cwd .. "/.git") then
		vim.g.task_root = cwd
	end
end
