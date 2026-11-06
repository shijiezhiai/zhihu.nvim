---what the reader opened in the last few days, on one page: the resume file
---already records every entry that was opened, this only lays it out
---@diagnostic disable: undefined-global
local M = {}

local DAY = 86400

---@param epoch integer
---@param now integer
---@return string
local function day_label(epoch, now)
  local day = os.date("%Y-%m-%d", epoch)
  if day == os.date("%Y-%m-%d", now) then
    return "今天"
  end
  if day == os.date("%Y-%m-%d", now - DAY) then
    return "昨天"
  end
  return day
end

---@param entry zhihu.ResumeEntry
---@return string
local function row(entry)
  local title = entry.title
  if title == nil or title == "" then
    title = entry.uri
  end
  local facts = {}
  if entry.tag ~= nil and entry.tag ~= "" then
    facts[#facts + 1] = entry.tag
  end
  if entry.meta ~= nil and entry.meta ~= "" then
    facts[#facts + 1] = entry.meta
  end
  -- the character count is counted in cells, a chinese title is not twice as
  -- long as it looks
  local line = ("- [%s](%s)"):format(require("zhihu.nvim.browse").truncate(title, 60), entry.uri)
  if #facts > 0 then
    line = line .. " · " .. table.concat(facts, " · ")
  end
  return line
end

---@param entries zhihu.ResumeEntry[]?
---@param now integer?
---@param days integer?
---@return string[]
function M.lines(entries, now, days)
  entries = entries or {}
  now = now or os.time()
  days = days or 7
  local head = ("# 最近 %d 天读了 %d 条"):format(days, #entries)
  if #entries == 0 then
    return { head, "", "这段时间还没打开过正文：在列表里按 <CR> 把一条正文拉下来，它就会记在这里。" }
  end
  local lines = { head, "" }
  local day
  for _, entry in ipairs(entries) do
    local label = day_label(entry.at, now)
    if label ~= day then
      if day ~= nil then
        lines[#lines + 1] = ""
      end
      day = label
      lines[#lines + 1] = "## " .. label
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = row(entry)
  end
  return lines
end

local opened

---show the page in the current window, read only; <CR> opens the row's entry
---@param days integer?
---@return integer buf
function M.open(days)
  local resume = require "zhihu.nvim.resume"
  days = math.floor(tonumber(days) or 7)
  if days < 1 then
    days = 7
  end
  local lines = M.lines(resume.recent(days), os.time(), days)
  local buf = opened
  if buf ~= nil and vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "zhihu-journal")
    vim.bo[buf].filetype = "markdown"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.keymap.set("n", "<CR>", function()
      require("zhihu.nvim.list").open_entry()
    end, { buffer = buf, desc = "zhihu: 打开光标下的条目" })
    opened = buf
  end
  vim.api.nvim_win_set_buf(0, buf)
  return buf
end

return M
