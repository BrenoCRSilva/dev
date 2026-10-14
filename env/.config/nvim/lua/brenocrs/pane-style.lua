local M = {}

M.winhighlight = table.concat({
	"Normal:AuxPaneNormal",
	"NormalNC:AuxPaneNormal",
	"EndOfBuffer:AuxPaneNormal",
	"SignColumn:AuxPaneNormal",
	"StatusLine:AuxPaneNormal",
	"StatusLineNC:AuxPaneNormal",
	"WinBar:AuxPaneNormal",
	"WinBarNC:AuxPaneNormal",
	"WinSeparator:AuxPaneSeparator",
}, ",")

local aux_pane_filetypes = {
	grapple = true,
	NeogitStatus = true,
	NeogitPopup = true,
	NeogitCommitMessage = true,
	NeogitCommitView = true,
	NeogitDiffView = true,
	NeogitLogView = true,
	NeogitReflogView = true,
	NeogitGitCommandHistory = true,
	qf = true,
	trouble = true,
	Trouble = true,
}

function M.apply()
	local separator = "%#AuxPaneSeparator#%{repeat('─', winwidth(0))}"
	if vim.bo.filetype == "grapple" then
		vim.opt_local.statusline = "%#Normal#"
		vim.opt_local.winbar = ""
	elseif vim.bo.filetype:match("^Neogit") then
		vim.opt_local.winhighlight = M.winhighlight
		vim.opt_local.statusline = separator
		vim.opt_local.winbar = ""
	else
		vim.opt_local.winhighlight = M.winhighlight
		vim.opt_local.statusline = "%#AuxPaneNormal#"
		vim.opt_local.winbar = separator
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "FileType", "BufWinEnter", "WinEnter" }, {
		pattern = "*",
		callback = function()
			if aux_pane_filetypes[vim.bo.filetype] then
				M.apply()
			end
		end,
	})
end

return M
