local M = {}

function M.titlecase(str)
	local small_words = {
		["a"] = true,
		["an"] = true,
		["and"] = true,
		["as"] = true,
		["at"] = true,
		["by"] = true,
		["in"] = true,
		["of"] = true,
		["on"] = true,
		["or"] = true,
		["the"] = true,
		["to"] = true,
	}
	local result = string.gsub(str:lower(), "(%a)([%w_']*)", function(first, rest)
		local word = first .. rest
		if small_words[word] then
			return word
		else
			return string.upper(first) .. rest
		end
	end)
	result = string.gsub(result, "^(%a)", string.upper)
	result = string.gsub(result, "-", " ")
	return result
end

return M
