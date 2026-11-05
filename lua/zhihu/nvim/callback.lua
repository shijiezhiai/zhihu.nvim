---get callbacks for article
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local Article = require 'zhihu.article'.Article
local List = require 'zhihu.list'.List
local M = {}

---callback for BufReadCmd
function M.read_cb()
  vim.o.buftype = "acwrite"
  vim.cmd "filetype detect"

  local list = List.from_url(vim.api.nvim_buf_get_name(0))
  if list then
    require 'zhihu.nvim.list'.read_cb(list)
    return
  end

  local article = Article:from_url(vim.api.nvim_buf_get_name(0))
  local lines = article:get_lines()
  vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)

  article.root = nil
  vim.b.article = article
  if article.authorName ~= (Article.authorName or article.authorName) then
    vim.o.modifiable = false
  end
end

---callback for BufWriteCmd
function M.write_cb()
  -- a list buffer records itself in vim.b when it is read; writing it back must
  -- never fall through to the article path, which would publish rendered lines
  if vim.b.zhihu_list then
    require 'zhihu.nvim.list'.write_cb()
    return
  end
  if vim.o.modifiable == false then
    return
  end
  local article = Article(vim.b.article)
  if vim.o.modified or article.titleImage then
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, true)
    article:set_lines(lines)
  else
    -- nothing need to be updated
    return
  end
  local error, aborted = article:write()
  if aborted then
    -- keep the buffer dirty so the user can retry the write
    article.root = nil
    vim.b.article = article
    return
  end
  if error then
    vim.notify(error, vim.log.levels.ERROR)
  else
    vim.o.modified = false
  end

  article.root = nil
  vim.b.article = article
end

return M
