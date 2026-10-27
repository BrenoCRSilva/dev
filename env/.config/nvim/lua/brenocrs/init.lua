vim.g.mapleader = " "

if vim.g.vscode then
	-- VSCode/Cursor config
	require("brenocrs.set")
	require("brenocrs.remap")

	-- Thin cursor in insert mode (ver10 = 10% width)
	vim.o.guicursor = "n-v-c-sm:block,i-ci-ve:ver10,r-cr-o:hor20"

	vim.cmd([[
        augroup HighlightYank
        autocmd!
        autocmd TextYankPost * lua vim.hl.on_yank()
        augroup end
    ]])
else
	-- Regular Neovim
	require("brenocrs.set")
	require("brenocrs.remap")
	require("brenocrs.plugin-keymaps")
	require("brenocrs.lazy")
	require("brenocrs.pane-style").setup()
	require("brenocrs.task-grapple").setup()

	vim.cmd([[
        augroup HighlightYank
        autocmd!
        autocmd TextYankPost * lua vim.hl.on_yank()
        augroup end
    ]])

	-- Grapple menu colors are owned by the Omarchy theme adapter (post_apply in
	-- lua/omarchy-theme.lua), driven by the active colorscheme — no hardcode here.

	-- Drop Neovim core's benign "Buffer (id: N) is not attached to client (id: M).
	-- Cannot detach." notice. minuet-ai's LSP detach calls the deprecated
	-- vim.lsp.buf_detach_client on a buffer whose minuet client is mid-teardown;
	-- the message is informational. Wrap on VeryLazy so we sit OUTSIDE the notifier
	-- plugin (and filter before it renders) rather than being replaced by it.
	vim.api.nvim_create_autocmd("User", {
		pattern = "VeryLazy",
		callback = function()
			local inner = vim.notify
			vim.notify = function(msg, level, opts)
				if type(msg) == "string" and msg:find("Cannot detach", 1, true) then
					return
				end
				return inner(msg, level, opts)
			end
		end,
	})

	vim.api.nvim_create_autocmd("QuickFixCmdPost", {
		pattern = "*",
		callback = function()
			vim.cmd("Trouble quickfix")
		end,
	})

	vim.api.nvim_create_autocmd({ "InsertEnter", "CursorMoved" }, {
		pattern = "*",
		callback = function()
			vim.cmd("echo ''")
		end,
	})

	vim.api.nvim_create_user_command("AddGoTags", function(opts)
		require("brenocrs.go-tagger").add_tags(opts.line1 - 1, opts.line2)
	end, { range = true })

	vim.api.nvim_create_user_command("RemoveGoTags", function(opts)
		require("brenocrs.go-tagger").remove_tags(opts.line1 - 1, opts.line2)
	end, { range = true })
end
