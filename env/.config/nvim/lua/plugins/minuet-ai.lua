return {
	{
		"milanglacier/minuet-ai.nvim",
		dependencies = {
			"nvim-lua/plenary.nvim",
		},
		config = function()
			require("minuet").setup({
				provider = "codestral",
				request_timeout = 3,
				throttle = 1000,
				add_single_line_entry = false,
				n_completions = 3,
				provider_options = {
					codestral = {
						model = "codestral-latest",
						end_point = "https://codestral.mistral.ai/v1/fim/completions",
						api_key = "CODESTRAL_API_KEY",
						stream = true,
						template = {
							prompt = function(ctx)
								return ctx
							end,
							suffix = function(ctx)
								return ctx
							end,
						},
						optional = {
							max_tokens = 256,
							stop = { "\n\n" },
						},
					},
				},
			})
		end,
	},
}
