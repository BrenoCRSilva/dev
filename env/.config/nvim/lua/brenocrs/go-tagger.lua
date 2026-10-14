local M = {}

local config = {
	skip_private = true,
}

function M.setup(user_config)
	config = vim.tbl_deep_extend("force", config, user_config or {})
end

local function to_snake_case(str)
	str = str:gsub("(%l)(%u)", "%1_%2")
	str = str:gsub("(%u)(%u%l)", "%1_%2")
	return str:lower()
end

local function parse_existing_tags(tag_string)
	local tags = {}
	for tag in tag_string:gmatch("[^%s]+") do
		local key = tag:match("^(.-):")
		if key then
			tags[#tags + 1] = { key = key, raw = tag }
		end
	end
	return tags
end

local function add_tags_to_line(line, tag_input, max_len)
	local field = line:match("^%s*([%w_]+)%s+[%w_%*%[%]]+")
	local tagSet = { ["json"] = true, ["xml"] = true, ["yaml"] = true, ["toml"] = true, ["db"] = true }
	if not tagSet[tag_input] then
		return line
	end
	if not field then
		return line
	end

	if config.skip_private and field:sub(1, 1):lower() == field:sub(1, 1) then
		return line
	end

	local before, existing_tag_str, after = line:match("^(.-)`(.-)`(.*)$")
	local tags = {}
	if existing_tag_str then
		tags = parse_existing_tags(existing_tag_str)
	else
		local beforeComment, afterComment = line:match("^(.-)//(.*)$") -- if line exist comment
		if beforeComment and afterComment then
			before = beforeComment
			after = "//" .. afterComment
		else
			before = line
			after = ""
		end
	end

	local existing_keys = {}
	for _, tag in ipairs(tags) do
		existing_keys[tag.key] = true
	end

	for new_tag in tag_input:gmatch("[^,%s]+") do
		if not existing_keys[new_tag] then
			tags[#tags + 1] = {
				key = new_tag,
				raw = string.format('%s:"%s"', new_tag, to_snake_case(field)),
			}
		end
	end

	local combined_tags = {}
	for _, tag in ipairs(tags) do
		table.insert(combined_tags, tag.raw)
	end
	local str_len = max_len - string.len(before)
	local indent = string.rep(" ", str_len)

	if existing_tag_str and existing_tag_str ~= "" then
		return before .. "`" .. table.concat(combined_tags, " ") .. "`" .. after
	end
	return before .. indent .. "`" .. table.concat(combined_tags, " ") .. "`" .. after
end

local function remove_tags_from_line(line, tag_to_remove)
	local before, tag_str, after = line:match("^(.-)`(.-)`(.*)$")
	if not tag_str then
		return line
	end

	local new_tags = {}
	for tag in tag_str:gmatch("[^%s]+") do
		local key = tag:match("^(.-):")
		if tag_to_remove == "" or (key and key == tag_to_remove) then
		else
			table.insert(new_tags, tag)
		end
	end

	if #new_tags == 0 then
		return before .. after
	else
		return before .. "`" .. table.concat(new_tags, " ") .. "`" .. after
	end
end

local function input_tags(callback)
	vim.ui.input({
		prompt = "Tag(s): ",
	}, function(input)
		if input then
			local tags = input:gsub("%s+", "")
			callback(tags)
		else
			callback(nil) -- User cancelled
		end
	end)
end

local function input_tag_to_remove(callback)
	vim.ui.input({
		prompt = "Tag(s): ",
	}, function(input)
		if input then
			local tag = input:gsub("%s+", "")
			callback(tag)
		else
			callback(nil) -- User cancelled
		end
	end)
end

local function get_max_len(bufnr, start_idx, end_idx)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
	local max_len = 0
	for _, line in ipairs(lines) do
		if string.len(line) > max_len then
			max_len = string.len(line)
		end
	end
	return max_len
end

local function update_lines(bufnr, start_idx, end_idx, transformer)
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
	for i, line in ipairs(lines) do
		lines[i] = transformer(line)
	end
	vim.api.nvim_buf_set_lines(bufnr, start_idx, end_idx, false, lines)
end

function M.add_tags(start_line, end_line)
	local bufnr = vim.api.nvim_get_current_buf()

	if start_line and end_line then
		input_tags(function(tag_input)
			if tag_input == "" or not tag_input then
				return
			end
			local max_len = get_max_len(bufnr, start_line, end_line)
			update_lines(bufnr, start_line, end_line, function(line)
				return add_tags_to_line(line, tag_input, max_len)
			end)
		end)
		return
	end
end

function M.remove_tags(start_line, end_line)
	local bufnr = vim.api.nvim_get_current_buf()

	if start_line and end_line then
		input_tag_to_remove(function(tag_input)
			if tag_input == "" or not tag_input then
				return
			end
			update_lines(bufnr, start_line, end_line, function(line)
				return remove_tags_from_line(line, tag_input)
			end)
		end)
		return
	end
end

return M
