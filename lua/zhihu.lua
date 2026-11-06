---lazy load
local M = {
  opts = {
    ---@type Article
    article = {},
  }
}

---set up
---@param opts table
function M.setup(opts)
  -- luacheck: ignore 111 113
  ---@diagnostic disable: undefined-global
  M.opts = vim.tbl_extend("force", M.opts, opts or {})
  local auth = M.opts.auth or {}
  require 'zhihu.api'.auth.persist = auth.persist == true
end

---override default value, only run once
function M.init_article()
  if M.article_inited then
    return
  end
  local Article = require 'zhihu.article'.Article
  for k, v in pairs(M.opts.article) do
    Article[k] = v
  end
  M.article_inited = true
end

---ask for a query on the command line, then open the search list
function M.prompt_search()
  vim.ui.input({ prompt = "搜索知乎：" }, function(input)
    input = input and vim.trim(input) or ""
    if input == "" then
      return
    end
    return require 'zhihu.nvim.browse'.search(input)
  end)
end

---:Zhihu — one subcommand so far, the site search
function M.create_commands()
  vim.api.nvim_create_user_command("Zhihu", function(command)
    local fargs = vim.deepcopy(command.fargs)
    local sub = table.remove(fargs, 1)
    local browse = require "zhihu.nvim.browse"
    if sub == "search" then
      local query = table.concat(fargs, " ")
      if query ~= "" then
        return browse.search(query)
      end
      -- no words typed: the query is worth asking for rather than refusing
      return M.prompt_search()
    end
    if sub == "log" then
      return require("zhihu.nvim.journal").open(tonumber(fargs[1]))
    end
    if sub == "forget" then
      require("zhihu.nvim.resume").forget()
      return vim.notify("zhihu: 已清掉阅读进度", vim.log.levels.INFO)
    end
    vim.notify("zhihu: 用法 :Zhihu search <关键词> / :Zhihu log [天数] / :Zhihu forget", vim.log.levels.WARN)
  end, { nargs = "*", desc = "zhihu: 搜索（:Zhihu search <关键词>）、阅读日志（:Zhihu log [天数]）" })
end

---default keys: <Plug> is always offered, <leader>zs only when the user has not taken it
function M.create_keymaps()
  vim.keymap.set("n", "<Plug>(zhihu-search)", M.prompt_search, { desc = "zhihu: 搜索（先输入关键词）" })
  if vim.fn.maparg("<leader>zs", "n") == "" then
    vim.keymap.set("n", "<leader>zs", "<Plug>(zhihu-search)", { desc = "zhihu: 搜索（先输入关键词）" })
  end
end

---create autocmds
---@param augroup_id integer?
function M.create_autocmds(augroup_id)
  augroup_id = augroup_id or vim.api.nvim_create_augroup("zhihu", {})
  vim.api.nvim_create_autocmd({ "BufReadCmd", "SessionLoadPost" }, {
    pattern = "zhihu://*",
    group = augroup_id,
    callback = function()
      M.init_article()
      require "zhihu.nvim.callback".read_cb()
      -- the lines took a request to arrive; the cursor is free to go back to
      -- where this document was left
      require("zhihu.nvim.resume").restore()
    end
  })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    pattern = "zhihu://*",
    group = augroup_id,
    callback = function()
      M.init_article()
      require "zhihu.nvim.callback".write_cb()
    end
  })
  ---a document is worth remembering at the moments the reader stops reading it,
  ---not on every j and k
  vim.api.nvim_create_autocmd({ "BufLeave", "CursorHold" }, {
    pattern = "zhihu://*",
    group = augroup_id,
    callback = function()
      require("zhihu.nvim.resume").remember_here()
    end
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup_id,
    callback = function()
      require("zhihu.nvim.resume").flush()
    end
  })
end

return M
