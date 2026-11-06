---where the reader left off: the row they were on, the line they had reached,
---and what they have already opened. Kept in a json file under neovim's state
---directory, so a restart does not send them back to the top of the feed.
---@diagnostic disable: undefined-global
local M = {}

---tests point this at a temporary file
---@type string?
M.path = nil

local data
local dirty = false
local waiting = nil

local function state_dir()
  local ok, dir = pcall(vim.fn.stdpath, "state")
  if ok and type(dir) == "string" and dir ~= "" then
    return dir
  end
  return vim.fn.stdpath "data"
end

---@return string
function M.file()
  return M.path or (state_dir() .. "/zhihu-resume.json")
end

local function empty()
  return { feeds = {}, lines = {}, read = {} }
end

---a corrupt file is worth no more than a missing one: reading a feed must never
---fail because yesterday's progress did not survive
---@return table
function M.load()
  if data then
    return data
  end
  data = empty()
  local path = M.file()
  if vim.fn.filereadable(path) == 0 then
    return data
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or type(raw) ~= "table" then
    return data
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return data
  end
  for _, key in ipairs({ "feeds", "lines", "read" }) do
    if type(decoded[key]) == "table" then
      data[key] = decoded[key]
    end
  end
  return data
end

---@return boolean
function M.save()
  local state = M.load()
  local path = M.file()
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local encoded_ok, encoded = pcall(vim.json.encode, state)
  if not encoded_ok then
    return false
  end
  dirty = false
  return (pcall(vim.fn.writefile, { encoded }, path))
end

---j and k must not write a file per row: the write waits for the reader to stop
local function touch()
  dirty = true
  if waiting then
    return
  end
  waiting = vim.defer_fn(function()
    waiting = nil
    if dirty then
      M.save()
    end
  end, 2000)
end

---@return boolean
function M.flush()
  if not dirty then
    return true
  end
  return M.save()
end

---forget everything this session knows and the file it came from
---@return boolean
function M.forget()
  data = empty()
  dirty = true
  return M.save()
end

---@param kind string
---@return string?
function M.feed(kind)
  return M.load().feeds[kind]
end

---@param kind string
---@param uri string
function M.set_feed(kind, uri)
  if type(kind) ~= "string" or type(uri) ~= "string" then
    return
  end
  local state = M.load()
  if state.feeds[kind] == uri then
    return
  end
  state.feeds[kind] = uri
  touch()
end

---an entry the reader actually opened, not one the cursor happened to pass.
---an older file holds a bare true where a table lives today, and both count
---@param uri string
---@return boolean
function M.read(uri)
  return M.load().read[uri] ~= nil
end

---@class zhihu.ResumeEntry
---@field uri string
---@field at integer
---@field title string?
---@field tag string?
---@field meta string?

---the time is kept because the journal asks what was read in the last few days
---@param uri string
---@param item table? the row that was opened, for the title it carries
function M.mark_read(uri, item)
  if type(uri) ~= "string" then
    return
  end
  local state = M.load()
  local seen = state.read[uri]
  -- a file written before this kept only the fact: it becomes a table now
  if type(seen) ~= "table" then
    seen = {}
  end
  seen.at = os.time()
  if type(item) == "table" then
    for _, key in ipairs({ "title", "tag", "meta" }) do
      local value = item[key]
      if type(value) == "string" and value ~= "" then
        seen[key] = value
      end
    end
  end
  state.read[uri] = seen
  touch()
end

---what was opened in the last `days` days, newest first
---@param days integer?
---@return zhihu.ResumeEntry[]
function M.recent(days)
  days = math.floor(tonumber(days) or 7)
  if days < 1 then
    days = 7
  end
  local cutoff = os.time() - days * 86400
  local entries = {}
  for uri, value in pairs(M.load().read) do
    -- an entry that was read before the time was kept cannot be dated, so it
    -- stays out of a window rather than landing in today's group
    if type(value) == "table" and type(value.at) == "number" and value.at >= cutoff then
      entries[#entries + 1] = {
        uri = uri,
        at = math.floor(value.at),
        title = value.title,
        tag = value.tag,
        meta = value.meta,
      }
    end
  end
  table.sort(entries, function(a, b)
    if a.at ~= b.at then
      return a.at > b.at
    end
    return a.uri < b.uri
  end)
  return entries
end

---@param uri string
---@return integer?
function M.line(uri)
  local line = M.load().lines[uri]
  if type(line) ~= "number" then
    return nil
  end
  return math.floor(line)
end

---@param uri string
---@param line integer
function M.set_line(uri, line)
  if type(uri) ~= "string" or type(line) ~= "number" or line < 1 then
    return
  end
  local state = M.load()
  if state.lines[uri] == line then
    return
  end
  state.lines[uri] = line
  touch()
end

---put the cursor back where this buffer was left, if it was left anywhere
---@param buf integer?
function M.restore(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local line = M.line(vim.api.nvim_buf_get_name(buf))
  if line == nil then
    return
  end
  local total = vim.api.nvim_buf_line_count(buf)
  if total < 2 then
    return
  end
  if line > total then
    line = total
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 })
end

---record the line of the zhihu document in the current window
function M.remember_here()
  local buf = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  -- the two panes of a feed are buffers too, but they are not documents and
  -- their names do not carry the scheme
  if not name:match "^zhihu://" then
    return
  end
  local ok, position = pcall(vim.api.nvim_win_get_cursor, 0)
  if not ok or type(position) ~= "table" then
    return
  end
  M.set_line(name, position[1])
end

return M
