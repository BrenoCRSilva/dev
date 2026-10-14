-- ============================================
-- CORE KEYMAPS (no plugin dependencies)
-- ============================================

-- File operations
vim.keymap.set("n", "<leader>s", "<cmd>w<CR>")
-- Save and quit a file; a panel (Neogit, Noice, Trouble, help, diffview...) just closes.
vim.keymap.set("n", "<leader>q", function()
	if vim.bo.buftype == "" and vim.api.nvim_buf_get_name(0) ~= "" then
		vim.cmd("wq!")
		return
	end
	if package.loaded["diffview"] and require("diffview.lib").get_current_view() then
		vim.cmd("DiffviewClose")
		return
	end
	if #vim.api.nvim_tabpage_list_wins(0) > 1 then
		vim.cmd("close")
	else
		vim.cmd("quit")
	end
end, { desc = "Save and quit / close panel" })

-- Movement and editing
vim.keymap.set("v", "J", ":m '>+1<CR>gv=gv", { silent = true })
vim.keymap.set("v", "K", ":m '<-2<CR>gv=gv", { silent = true })
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("x", "<leader>p", [["_dP]])
vim.keymap.set(
	{ "n", "x" },
	"n",
	[[@/ == '' ? ':echo "/ is empty"<Cr>' : 'n']],
	{ expr = true, noremap = true, silent = true }
)

-- Replace word (only in regular Neovim, not VSCode)
if not vim.g.vscode then
	vim.keymap.set("n", "<leader>rw", function()
		local replace_word = vim.fn.expand("<cword>")
		if replace_word == "" then
			return
		end

		local escaped = vim.fn.escape(replace_word, "/\\.*$^~[]")

		-- Match word that's bounded by non-alphanumeric chars
		-- \zs and \ze mark start/end of match (don't include boundaries in match)
		local pattern = "\\([^a-zA-Z0-9]\\|^\\)\\zs" .. escaped .. "\\ze\\([^a-zA-Z0-9]\\|$\\)"

		vim.fn.setreg("/", pattern)
		vim.o.hlsearch = true
		vim.cmd("redraw")

		local target_word = vim.fn.input("Replace '" .. replace_word .. "' with: ")
		if target_word == "" then
			return
		end

		vim.cmd("%s/" .. pattern .. "/" .. target_word .. "/gI")
		vim.fn.setreg("/", "")
		vim.o.hlsearch = false
	end, { desc = "Replace Word" })
end

-- Window management
vim.keymap.set("n", "<leader>wo", "<C-w>o")
vim.keymap.set("n", "<leader>wl", "<C-w>l")
vim.keymap.set("n", "<leader>wk", "<C-w>k")
vim.keymap.set("n", "<leader>wj", "<C-w>j")
vim.keymap.set("n", "<leader>wh", "<C-w>h")

-- Movement remaps
vim.keymap.set({ "n", "o", "v" }, "&", "^")
vim.keymap.set({ "n", "o", "v" }, "$", "g_")

-- Clipboard paste
vim.keymap.set("n", "<leader>P", function()
	vim.opt.paste = true
	vim.cmd('normal! "+p')
	vim.opt.paste = false
end, { desc = "Paste from clipboard" })
