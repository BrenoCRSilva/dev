-- Go to definition across every attached client, without the duplicate list
-- produced by CommonJS export aliases (`module.exports = { x: x }`) and imports.
local M = {}

local function normalize_locations(result)
	if not result then
		return {}
	end
	if result.uri or result.targetUri then
		return { result }
	end
	return result
end

local function location_uri(location)
	return location.uri or location.targetUri
end

local function location_line(location)
	local range = location.targetSelectionRange or location.range or location.targetRange
	return range and range.start and range.start.line or 0
end

local function line_text(uri, line)
	local bufnr = vim.uri_to_bufnr(uri)
	if vim.api.nvim_buf_is_loaded(bufnr) then
		return vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
	end
	local ok, lines = pcall(vim.fn.readfile, vim.uri_to_fname(uri), "", line + 1)
	return ok and lines[line + 1] or ""
end

local function is_import_line(text)
	return text:match("^%s*import%s") ~= nil or text:match("%sfrom%s+[\"']") ~= nil or text:match("require%(") ~= nil
end

local function is_export_alias_line(text)
	local trimmed = vim.trim(text)
	if trimmed:match("module%.exports") or trimmed:match("^exports%.") then
		return true
	end
	if trimmed:match("^export%s*{") or trimmed:match("^export%s*%*") then
		return true
	end
	local key, value = trimmed:match("^([%w_$]+)%s*:%s*([%w_$]+)%s*,?$")
	if key and key == value then
		return true
	end
	return trimmed:match("^[%w_$]+%s*,?$") ~= nil
end

local function is_alias(entry, current_uri)
	local text = line_text(entry.uri, entry.line)
	if entry.uri == current_uri and is_import_line(text) then
		return true
	end
	return is_export_alias_line(text)
end

local function jump(entry)
	vim.lsp.util.show_document(entry.location, entry.encoding, { focus = true })
end

function M.goto_definition()
	local bufnr = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local current_uri = vim.uri_from_bufnr(bufnr)

	vim.lsp.buf_request_all(bufnr, "textDocument/definition", function(client)
		return vim.lsp.util.make_position_params(win, client.offset_encoding)
	end, function(results)
		local entries = {}
		local seen = {}
		for client_id, response in pairs(results) do
			local client = vim.lsp.get_client_by_id(client_id)
			if client and response.result then
				for _, location in ipairs(normalize_locations(response.result)) do
					local uri = location_uri(location)
					local line = location_line(location)
					local key = uri .. ":" .. line
					if uri and not seen[key] then
						seen[key] = true
						table.insert(
							entries,
							{ location = location, encoding = client.offset_encoding, uri = uri, line = line }
						)
					end
				end
			end
		end

		if #entries == 0 then
			vim.notify("No definition found", vim.log.levels.INFO)
			return
		end

		local kept = vim.tbl_filter(function(entry)
			return not is_alias(entry, current_uri)
		end, entries)
		if #kept == 0 then
			kept = entries
		end

		table.sort(kept, function(a, b)
			if a.uri == b.uri then
				return a.line < b.line
			end
			return a.uri < b.uri
		end)

		local single_file = true
		for _, entry in ipairs(kept) do
			if entry.uri ~= kept[1].uri then
				single_file = false
			end
		end

		if single_file then
			jump(kept[1])
			return
		end

		local items = {}
		for _, entry in ipairs(kept) do
			vim.list_extend(items, vim.lsp.util.locations_to_items({ entry.location }, entry.encoding))
		end
		vim.fn.setqflist({}, " ", { title = "LSP definitions", items = items })
		vim.cmd("copen")
	end)
end

return M
