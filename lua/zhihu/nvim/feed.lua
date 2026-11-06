---pick one entry out of a front page feed and open it
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local M = {}

---@param item table
function M.open(item)
  if item.uri then
    vim.cmd.edit(vim.fn.fnameescape(item.uri))
    return
  end
  if item.url then
    vim.ui.open(item.url)
  end
end

---@param kind string
---@param index integer
---@param item table
---@return string row
local function row(kind, index, item)
  return ("%2d. [%s] %s%s"):format(index, item.tag or kind, item.title, item.meta and ("  · " .. item.meta) or "")
end

---open a picker over one feed
---@param kind "hot"|"recommend"|"follow"
function M.pick(kind)
  local feed = require 'zhihu.api.get.feed'
  local label = feed.tag[kind] or kind
  local ok, items = pcall(feed.fetch, kind)
  if not ok then
    vim.notify(tostring(items), vim.log.levels.ERROR)
    return
  end
  if #items == 0 then
    vim.notify(("zhihu: %s是空的，检查登录态"):format(label), vim.log.levels.WARN)
    return
  end

  local rows, by_row = {}, {}
  for index, item in ipairs(items) do
    local line = row(kind, index, item)
    rows[#rows + 1] = line
    by_row[line] = item
  end

  local prompt = label .. "> "
  -- fzf-lua when it is installed, vim.ui.select otherwise: the plugin must not
  -- grow a hard dependency on a picker
  local has_fzf, fzf = pcall(require, "fzf-lua")
  if has_fzf then
    fzf.fzf_exec(rows, {
      prompt = prompt,
      actions = {
        default = function(selected)
          local item = by_row[selected[1]]
          if item then
            M.open(item)
          end
        end,
      },
    })
    return
  end
  vim.ui.select(rows, { prompt = prompt }, function(choice)
    local item = choice and by_row[choice]
    if item then
      M.open(item)
    end
  end)
end

return M
