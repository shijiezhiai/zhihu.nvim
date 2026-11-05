---the neovim side of a zhihu list buffer
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local M = {}

---the zhihu uri of a rendered line, nil when the line carries none
---@param line string?
---@return string? url
function M.entry_url(line)
  return tostring(line or ""):match "zhihu://[^%s`%)]+"
end

---open the entry under the cursor
function M.open_entry()
  local url = M.entry_url(vim.api.nvim_get_current_line())
  if url == nil then
    vim.notify("zhihu: 光标下没有知乎链接", vim.log.levels.WARN)
    return
  end
  vim.cmd.edit(url)
end

---callback for BufReadCmd of a list uri
---@param list table
function M.read_cb(list)
  -- a failed fetch must not surface as a raw BufReadCmd traceback: the user
  -- would be left with an empty buffer and no reason
  local ok, lines = pcall(list.get_lines, list)
  if not ok then
    vim.notify(lines, vim.log.levels.ERROR)
    vim.api.nvim_buf_set_lines(0, 0, -1, true, {
      "# zhihu 列表加载失败",
      tostring(lines),
      "检查登录态（cookies）后重新 :edit 本 URI",
    })
    vim.b.zhihu_list = list
    vim.o.modifiable = false
    return
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, true, lines)
  vim.b.zhihu_list = list
  -- a list holds a snapshot of the api, editing it cannot mean anything
  vim.o.modifiable = false
  vim.keymap.set("n", "<CR>", M.open_entry, {
    buffer = true,
    nowait = true,
    silent = true,
    desc = "zhihu: open the entry under the cursor",
  })
end

---callback for BufWriteCmd of a list uri
function M.write_cb()
  if vim.b.zhihu_list then
    vim.notify("zhihu: 列表缓冲区是只读的", vim.log.levels.WARN)
    return
  end
end

return M
