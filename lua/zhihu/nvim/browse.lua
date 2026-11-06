---a feed as two panes: the list on the left, whatever the cursor points at on
---the right; the closest a terminal gets to scrolling zhihu
---@diagnostic disable: undefined-global
-- luacheck: ignore 111 113
local M = {
  ---share of the columns the list keeps
  ratio = 0.34,
  ---narrowest list, in columns
  min_width = 26,
  ---rows pulled when the cursor reaches the end of the list: one page of the
  ---story feeds, so a single request per scroll
  batch = 6,
  ---rendered entries kept in memory
  cache_limit = 40,
  ---buffer names must not match zhihu://, the BufReadCmd owns those
  name = "zhihu-feed://",
}

---@type table<string, string[]>
local cache = {}
---@type string[]
local cached_order = {}
---created on first use: the pure helpers below must load without a running nvim
local ns

local resume = require "zhihu.nvim.resume"

---draws the list again once something the rows depend on (a body was opened)
---changes; defined with render_list, called from the fetch path above it
local repaint

---codepoint of one utf8 character
---@param char string
---@return integer
local function codepoint(char)
  local b1, b2, b3, b4 = char:byte(1, 4)
  if b1 < 0x80 then
    return b1
  end
  if b1 < 0xE0 then
    return (b1 - 0xC0) * 0x40 + ((b2 or 0) - 0x80)
  end
  if b1 < 0xF0 then
    return (b1 - 0xE0) * 0x1000 + (((b2 or 0) - 0x80) * 0x40) + ((b3 or 0) - 0x80)
  end
  return (b1 - 0xF0) * 0x40000 + (((b2 or 0) - 0x80) * 0x1000) + (((b3 or 0) - 0x80) * 0x40) + ((b4 or 0) - 0x80)
end

---cells a character takes in a terminal: the wide ranges are enough for the
---titles zhihu hands out
---@param char string
---@return integer
local function char_cells(char)
  local cp = codepoint(char)
  if (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE6F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x20000 and cp <= 0x3FFFD) then
    return 2
  end
  return 1
end

---display cells of a string
---@param text string?
---@return integer
local function cells(text)
  local total = 0
  for char in tostring(text or ""):gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    total = total + char_cells(char)
  end
  return total
end

---collapse whitespace and cut text to width cells, never inside a character
---@param text string?
---@param width integer
---@return string
function M.truncate(text, width)
  -- winbar and statusline reject control characters outright (E539), and a
  -- feed title may carry one
  local line = tostring(text or ""):gsub("%c", " "):gsub("%s+", " ")
  if cells(line) <= width then
    return line
  end
  local out, used = {}, 0
  for char in line:gmatch "[%z\1-\127\194-\244][\128-\191]*" do
    local width_of = char_cells(char)
    if used + width_of > width - 1 then
      break
    end
    used = used + width_of
    out[#out + 1] = char
  end
  return table.concat(out) .. "…"
end

---winbar and statusline read a bare % as the start of a format character, so a
---title such as "5.52%" raises E539 the moment it is set
---@param text string?
---@return string
function M.bar(text)
  local line = tostring(text or ""):gsub("%c", " ")
  return (line:gsub("%%", "%%%%"))
end

---one row of the list
---@param index integer
---@param item table
---@param width integer?
---@return string
function M.row_text(index, item, width)
  local prefix = ("%3d "):format(index)
  local tag = ("[%s]"):format(item.tag or "")
  local room = math.max((width or 80) - cells(prefix) - cells(tag) - 1, 8)
  return ("%s%s %s"):format(prefix, tag, M.truncate(item.title, room))
end

---the line under an entry's title: what it says, then what backs it up; the
---excerpt is the reason a row is worth reading before opening it
---@param item table
---@param width integer?
---@return string
function M.detail_text(item, width)
  local excerpt = tostring(item.excerpt or "")
  local meta = tostring(item.meta or "")
  local indent = "    "
  if excerpt == "" and meta == "" then
    return ""
  end
  -- a pane this narrow would spend the row on "…" and an author name
  if (width or 80) < 16 then
    return ""
  end
  -- an excerpt that opens with the title only repeats what is already above it
  local title = tostring(item.title or "")
  if title ~= "" and excerpt:sub(1, #title) == title then
    excerpt = excerpt:sub(#title + 1):gsub("^%s+", "")
  end
  local room = math.max((width or 80) - cells(indent) - 1, 10)
  if meta == "" then
    return indent .. M.truncate(excerpt, room)
  end
  -- luajit has no integer division: this runs on the nvim lua and on plain luajit
  meta = M.truncate(meta, math.max(math.floor(room / 2), 6))
  if excerpt == "" then
    return indent .. meta
  end
  local gap = 3
  local left = room - cells(meta) - gap
  if left < 8 then
    return indent .. meta
  end
  return indent .. M.truncate(excerpt, left) .. " · " .. meta
end

---the list as it is painted, plus the row to entry map: an entry with an
---excerpt owns two rows, so a cursor row is no longer an item index
---@param items table[]
---@param width integer?
---@return string[] lines
---@return integer[] row_item
function M.rows(items, width, keep)
  local lines, row_item = {}, {}
  for index, item in ipairs(items) do
    -- a skipped entry keeps its number: row_item still points at the item index
    if keep == nil or keep(item) then
      lines[#lines + 1] = M.row_text(index, item, width)
      row_item[#row_item + 1] = index
      local detail = M.detail_text(item, width)
      if detail ~= "" then
        lines[#lines + 1] = detail
        row_item[#row_item + 1] = index
      end
    end
  end
  return lines, row_item
end

---an entry with no article behind it: the reader can only hand it to a browser
---@param item table
---@return boolean
function M.dead(item)
  return item.uri == nil
end

---web address of an item, derived from the reader uri when the feed gave none
---@param item table
---@return string? url
function M.web_url(item)
  if item.url then
    return item.url
  end
  if item.uri == nil then
    return nil
  end
  return "https://" .. tostring(item.uri:gsub("^zhihu://", ""):gsub("%.md$", ""))
end

---@param uri string
---@return string[]? lines
local function remembered(uri)
  return cache[uri]
end

---@param uri string
---@param lines string[]
local function remember(uri, lines)
  if cache[uri] == nil then
    cached_order[#cached_order + 1] = uri
  end
  cache[uri] = lines
  while #cached_order > M.cache_limit do
    cache[table.remove(cached_order, 1)] = nil
  end
end

---@param view table
---@param lines string[]
local function show(view, lines)
  local buf = view.prev_buf
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  -- a buffer line cannot hold a newline: whatever the converter produced, break
  -- it up before handing it to nvim
  local flat = {}
  for _, line in ipairs(lines) do
    for piece in tostring(line):gsub("\r", ""):gmatch "[^\n]+" do
      flat[#flat + 1] = piece
    end
  end
  if #flat == 0 then
    flat = { "" }
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, flat)
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "markdown"
  if vim.api.nvim_win_is_valid(view.prev_win) then
    pcall(vim.api.nvim_win_set_cursor, view.prev_win, { 1, 0 })
  end
end

---@param buf integer
---@param lhs string
---@param rhs function
---@param desc string
local function map(buf, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end

---@param view table
local function focus_list(view)
  if vim.api.nvim_win_is_valid(view.list_win) then
    vim.api.nvim_set_current_win(view.list_win)
  end
end

---the entry the cursor sits on: a detail row belongs to the entry above it, so
---the row to entry map decides, not the line number
---@param view table
---@return integer? index
local function index_under_cursor(view)
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, view.list_win)
  if not ok then
    return nil
  end
  local row = cursor[1]
  local map = view.row_item
  return (map and map[row]) or row
end

---@param view table
---@return table? item
local function item_under_cursor(view)
  local index = index_under_cursor(view)
  if index == nil then
    return nil
  end
  return view.session.items[index]
end

---@param view table
function M.close(view)
  if view.timer then
    view.timer:stop()
    view.timer:close()
    view.timer = nil
  end
  if M.view == view then
    M.view = nil
  end
  for _, win in ipairs({ view.prev_win, view.list_win }) do
    if win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  -- the scratch names stay taken until the buffers are gone, and reopening the
  -- same feed right after closing it would then fail with E95
  for _, buf in ipairs({ view.list_buf, view.prev_buf }) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
end

---a pane closed by hand leaves the view dangling: drop it with the buffer
---@param view table
local function watch_list(view)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = view.list_buf,
    once = true,
    callback = function()
      if M.view == view then
        M.view = nil
      end
    end,
  })
end

---the preview pane is a scratch buffer, but <CR> may replace it with a real
---zhihu buffer: recreate it before painting again
---@param view table
---@return integer buf
local function ensure_preview(view)
  local buf = view.prev_buf
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  view.prev_buf = buf
  if vim.api.nvim_win_is_valid(view.prev_win) then
    vim.api.nvim_win_set_buf(view.prev_win, buf)
  end
  map(buf, "q", function() focus_list(view) end, "zhihu: 回到列表")
  map(buf, "<CR>", function() M.follow_entry(view) end, "zhihu: 打开光标下的条目或链接")
  map(buf, "gy", function() M.yank_quote(view) end, "zhihu: 把正文 yank 成引用块")
  map(buf, "gs", function() M.save_md(view) end, "zhihu: 把正文存成 md")
  return buf
end

---@param view table
local function update_winbar(view)
  if not vim.api.nvim_win_is_valid(view.list_win) then
    return
  end
  local tail
  if view.state == "loading" then
    tail = "加载中…"
  elseif view.state == "error" then
    tail = "拉取失败"
  elseif view.state == "empty" then
    tail = "空"
  else
    local dead, live = 0, 0
    for _, item in ipairs(view.session.items) do
      if M.dead(item) then
        dead = dead + 1
      else
        live = live + 1
      end
    end
    tail = ("%d 条%s"):format(#view.session.items, view.session.done and "" or " …")
    -- only worth saying when folding actually hides something
    if dead > 0 and live > 0 then
      tail = tail .. (", z %s %d 条仅浏览器"):format(view.show_dead and "折叠" or "展开", dead)
    end
  end
  vim.wo[view.list_win].winbar = M.bar((" %s · %s "):format(view.label, tail))
end

---the reader picks its converter from the filetype of the current buffer, so the
---pane has to be the current buffer and claim markdown before the text is built
---@param buf integer
---@param uri string
---@return string[] lines
local function render_into(buf, uri)
  vim.bo[buf].filetype = "markdown"
  return vim.api.nvim_buf_call(buf, function()
    return require 'zhihu.article'.Article:from_url(uri):get_lines()
  end)
end

---render an already downloaded page: the filetype has to be markdown before the
---renderer picks its converter, and the buffer owns that setting
---@param buf integer
---@param html string
---@return string[] lines
local function render_html(buf, html)
  vim.bo[buf].filetype = "markdown"
  return vim.api.nvim_buf_call(buf, function()
    return require 'zhihu.article'.Article:from_html(html):get_lines()
  end)
end

---everything the feed already paid for, laid out as the page the pane shows
---while the body has not been asked for
---@param item table
---@return string[]
function M.card(item)
  local heading = item.title
  if heading == nil or heading == "" then
    heading = item.tag or "这一条"
  end
  local lines = { "# " .. tostring(heading), "" }
  local facts = {}
  if item.tag ~= nil and item.tag ~= "" then
    facts[#facts + 1] = item.tag
  end
  if item.meta ~= nil and item.meta ~= "" then
    facts[#facts + 1] = item.meta
  end
  if #facts > 0 then
    lines[#lines + 1] = table.concat(facts, " · ")
    lines[#lines + 1] = ""
  end
  if item.excerpt ~= nil and item.excerpt ~= "" then
    lines[#lines + 1] = "> " .. item.excerpt
    lines[#lines + 1] = ""
  end
  if item.uri == nil then
    lines[#lines + 1] = item.reason or "这一条没有可渲染的正文，只能在浏览器里读。"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "浏览器打开：" .. (M.web_url(item) or "")
    lines[#lines + 1] = ""
    lines[#lines + 1] = "按 o 打开。"
  else
    lines[#lines + 1] = "按 <CR> 拉这一条的正文。"
  end
  return lines
end

---the body the pane is actually showing, if the pane is showing a body at all
---@param view table
---@return string[]? lines
function M.shown_body(view)
  local item = item_under_cursor(view)
  -- a body still on its way is on screen as a placeholder: not text to carry away
  if item == nil or item.uri == nil or view.fetching ~= nil or view.loaded ~= item.uri then
    return nil
  end
  local buf = view.prev_buf
  if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

---@param item table
---@return string title
local function heading(item)
  local title = item.title
  if title == nil or title == "" then
    return item.tag or "知乎"
  end
  return tostring(title)
end

---the entry as a quote block, ready to drop into a note
---@param item table
---@param body string[]
---@return string[]
function M.quote_lines(item, body)
  local head = "> " .. heading(item)
  if item.meta ~= nil and item.meta ~= "" then
    head = head .. " · " .. item.meta
  end
  local lines = { head, ">" }
  for _, line in ipairs(body or {}) do
    lines[#lines + 1] = (line == "") and ">" or ("> " .. line)
  end
  local url = M.web_url(item)
  if url ~= nil then
    if lines[#lines] ~= ">" then
      lines[#lines + 1] = ">"
    end
    lines[#lines + 1] = "> —— " .. url
  end
  return lines
end

---drop the blank lines a rendered body ends with: a note should not trail off
---@param lines string[]
---@return string[]
local function trimmed(lines)
  local last = #lines
  while last > 0 and (lines[last] == "" or lines[last]:match "^%s*$") do
    last = last - 1
  end
  local out = {}
  for index = 1, last do
    out[index] = lines[index]
  end
  return out
end

---the entry as a standalone note: title, what it is, then the body, source last
---@param item table
---@param body string[]
---@return string[]
function M.md_lines(item, body)
  local lines = { "# " .. heading(item), "" }
  local facts = {}
  if item.tag ~= nil and item.tag ~= "" then
    facts[#facts + 1] = item.tag
  end
  if item.meta ~= nil and item.meta ~= "" then
    facts[#facts + 1] = item.meta
  end
  if #facts > 0 then
    lines[#lines + 1] = table.concat(facts, " · ")
    lines[#lines + 1] = ""
  end
  if item.excerpt ~= nil and item.excerpt ~= "" then
    lines[#lines + 1] = "> " .. item.excerpt
    lines[#lines + 1] = ""
  end
  for _, line in ipairs(trimmed(body or {})) do
    lines[#lines + 1] = line
  end
  local url = M.web_url(item)
  if url ~= nil then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "---"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "来源：" .. url
  end
  return lines
end

---a file name taken from the title, with the characters a file system refuses
---replaced rather than escaped
---@param title string?
---@param fallback string?
---@return string
function M.md_name(title, fallback)
  local text = tostring(title or ""):gsub("[\\/:*?\"<>|%c]", " ")
  text = text:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then
    text = tostring(fallback or "知乎")
  end
  return M.truncate(text, 60):gsub("…$", "") .. ".md"
end

---paint the entry under the cursor: a body already downloaded, otherwise the
---card. passing over rows costs nothing, so scanning the list never waits
---@param view table
local function update_preview(view)
  local item = item_under_cursor(view)
  if item == nil then
    return
  end
  ensure_preview(view)
  if vim.api.nvim_win_is_valid(view.prev_win) then
    vim.wo[view.prev_win].winbar = M.bar((" %s · %s "):format(item.tag or "", M.truncate(item.title, 60)))
  end
  -- a body on its way owns the pane: painting the card over it would throw the
  -- answer away the moment it lands
  if item.uri ~= nil and view.fetching == item.uri then
    return
  end
  if item.uri == nil then
    view.loaded = nil
    return show(view, M.card(item))
  end
  local hit = remembered(item.uri)
  if hit then
    view.loaded = item.uri
    return show(view, hit)
  end
  view.loaded = nil
  show(view, M.card(item))
end

---the pane could not be filled: say why, and stop pretending a body is coming
---@param view table
---@param detail any
---@param uri string
local function broken(view, detail, uri)
  if view.fetching == uri then
    view.fetching = nil
  end
  view.loaded = nil
  show(view, { "# 打不开这一条", "", tostring(detail), "", uri })
end

---the body is downloaded when the reader decides to read it, not while the
---cursor happens to rest on the row
---@param view table
local function fetch_body(view)
  local item = item_under_cursor(view)
  if item == nil or item.uri == nil then
    return
  end
  if view.loaded == item.uri then
    return
  end
  local buf = ensure_preview(view)
  if vim.api.nvim_win_is_valid(view.prev_win) then
    vim.wo[view.prev_win].winbar = M.bar((" %s · %s "):format(item.tag or "", M.truncate(item.title, 60)))
  end
  local hit = remembered(item.uri)
  if hit then
    view.loaded = item.uri
    view.fetching = nil
    return show(view, hit)
  end
  view.loaded = item.uri
  view.fetching = item.uri
  show(view, { "_拉取正文…_" })
  local uri = item.uri
  -- the download runs in a child process so that j and k stay responsive; the
  -- cursor may have moved on by the time it lands
  local function land(lines)
    if #lines == 0 then
      lines = { "（正文是空的）" }
    end
    -- the body is worth keeping even when the reader has moved to another row
    remember(uri, lines)
    resume.mark_read(uri, item)
    -- the row it belongs to now reads as read: show that without making the
    -- reader move off the row they are on
    if repaint and view.state == "ready" then
      repaint(view)
    end
    if view.fetching == uri then
      view.fetching = nil
    end
    if view.loaded ~= uri or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    show(view, lines)
  end
  local http_ok = require("zhihu.nvim.http").available()
  -- a question answers page is a list, not a single article: the uri carries the
  -- page number (answers-20.md) and zhihu.list renders it twenty answers at a time
  local list = require("zhihu.list").List.from_url(uri)
  if list then
    local function landed(rows, err)
      if view.loaded ~= uri or not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if err then
        return broken(view, err, uri)
      end
      land(list:lines(rows))
    end
    if not http_ok then
      local ok, rows = pcall(function()
        return list:parse(list:fetch())
      end)
      if not ok then
        return landed(nil, rows)
      end
      return landed(rows)
    end
    return list:fetch_async(landed)
  end
  if not http_ok then
    local ok, lines = pcall(render_into, buf, uri)
    if not ok then
      return broken(view, lines, uri)
    end
    return land(lines)
  end
  require 'zhihu.article'.Article:fetch_async(uri, function(html, err)
    if view.loaded ~= uri or not vim.api.nvim_buf_is_valid(buf) then
      return
    end
    if err or html == nil then
      return broken(view, err or "空响应", uri)
    end
    local ok, lines = pcall(render_html, buf, html)
    if not ok then
      return broken(view, lines, uri)
    end
    land(lines)
  end)
end

---rows that only a browser can open are folded out of the list, unless folding
---them would leave nothing behind: the hot list is browser rows all the way down
---@param view table
---@return fun(item: table): boolean
local function keep_rows(view)
  if view.show_dead then
    return function()
      return true
    end
  end
  local live = 0
  for _, item in ipairs(view.session.items) do
    if not M.dead(item) then
      live = live + 1
    end
  end
  if live == 0 then
    return function()
      return true
    end
  end
  return function(item)
    return not M.dead(item)
  end
end

---the row an entry sits at: row_item is keyed by row number and every entry
---carries a detail row, so the keys are 1, 3, 5… and never dense
---@param row_item table<integer, integer>?
---@param items table[]
---@param uri string?
---@return integer? row
function M.row_of(row_item, items, uri)
  if type(uri) ~= "string" then
    return nil
  end
  for row, index in pairs(row_item or {}) do
    local item = items[index]
    if item and item.uri == uri then
      return row
    end
  end
  return nil
end

---the row this feed was left at, once: a position is not a read, so nothing is
---fetched for it
---@param view table
local function restore_row(view)
  if view.restored then
    return
  end
  view.restored = true
  local row = M.row_of(view.row_item, view.session.items, resume.feed(view.kind))
  if row then
    pcall(vim.api.nvim_win_set_cursor, view.list_win, { row, 0 })
  end
end

local function render_list(view)
  local width = vim.api.nvim_win_get_width(view.list_win)
  local lines, row_item = M.rows(view.session.items, width, keep_rows(view))
  view.row_item = row_item
  local marks = {}
  -- rows are built from known pieces, so the highlight columns are known too:
  -- no regex to keep in sync with the layout
  local previous = nil
  for row, index in ipairs(row_item) do
    local item = view.session.items[index]
    local prefix = ("%3d "):format(index)
    local tag = ("[%s]"):format(item.tag or "")
    if previous == index then
      -- four spaces of indent, then the excerpt and the meta: context, not the
      -- entry itself, so it is dimmed
      marks[#marks + 1] = { row - 1, 4, { end_col = #lines[row], hl_group = "Comment" } }
    else
      marks[#marks + 1] = { row - 1, 0, { end_col = #prefix - 1, hl_group = "LineNr" } }
      marks[#marks + 1] = { row - 1, #prefix, { end_col = #prefix + #tag - 1, hl_group = "Special" } }
      if M.dead(item) then
        -- nothing to read here: the row itself says so by being dimmed
        marks[#marks + 1] = { row - 1, #prefix + #tag + 1, { end_col = #lines[row], hl_group = "Comment" } }
      elseif item.uri and resume.read(item.uri) then
        -- already opened once: dimmer than the rest, so the unread ones stand out
        marks[#marks + 1] = { row - 1, #prefix + #tag + 1, { end_col = #lines[row], hl_group = "Comment" } }
      end
    end
    previous = index
  end
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  ns = ns or vim.api.nvim_create_namespace "zhihu-feed"
  vim.api.nvim_buf_clear_namespace(view.list_buf, ns, 0, -1)
  -- nvim_buf_set_extmarks (plural) only exists in the newest versions, and a
  -- pcall around it turned every dimmed row into a silent no-op
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(view.list_buf, ns, mark[1], mark[2], mark[3])
  end
end

---the layout of a row does not depend on what it says, so redrawing keeps the
---cursor on the row the reader was looking at
---@param view table
repaint = function(view)
  if not vim.api.nvim_win_is_valid(view.list_win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(view.list_win)[1]
  render_list(view)
  pcall(vim.api.nvim_win_set_cursor, view.list_win, { row, 0 })
end

---@param view table
---@param added table[]
local function grow(view, added)
  if added and #added > 0 then
    render_list(view)
    update_winbar(view)
  end
end

---@param view table
local function maybe_more(view)
  local session = view.session
  if view.state ~= "ready" or session.done or view.growing then
    return
  end
  local index = index_under_cursor(view) or #session.items
  -- a tall window shows six entries and a lot of nothing: keep pulling while the
  -- list does not fill it, then wait for the cursor to come near the end
  local filled = #(view.row_item or {}) > vim.api.nvim_win_get_height(view.list_win)
  if filled and #session.items - index > 3 then
    return
  end
  view.growing = true
  -- without curl the page is fetched in this process, which holds the ui for the
  -- length of the request; with it the list keeps scrolling
  if not require("zhihu.nvim.http").available() then
    local ok, added, err = pcall(session.more, session, M.batch)
    view.growing = false
    if not ok then
      return vim.notify(tostring(added), vim.log.levels.ERROR)
    end
    grow(view, added)
    if err then
      vim.notify(tostring(err), vim.log.levels.WARN)
    end
    return maybe_more(view)
  end
  require("zhihu.api.get.feed").page_async(session.url, function(err, body)
    -- the view may have been closed while the request was in flight
    if not vim.api.nvim_buf_is_valid(view.list_buf) then
      view.growing = false
      return
    end
    if err then
      view.growing = false
      return vim.notify(tostring(err), vim.log.levels.WARN)
    end
    local ok, added = pcall(session.take, session, body)
    view.growing = false
    if not ok then
      return vim.notify(tostring(added), vim.log.levels.ERROR)
    end
    grow(view, added)
    maybe_more(view)
  end)
end

---@param view table
---@param fn function
local function later(view, fn)
  if view.timer == nil then
    view.timer = vim.uv.new_timer()
  else
    view.timer:stop()
  end
  view.timer:start(60, 0, vim.schedule_wrap(fn))
end

---@param view table
local function on_move(view)
  if not vim.api.nvim_win_is_valid(view.list_win) then
    return
  end
  later(view, function()
    if not vim.api.nvim_win_is_valid(view.list_win) then
      return
    end
    update_preview(view)
    -- the search pane shares one key for every query, so only a feed has a
    -- single row worth remembering
    if view.kind ~= "search" then
      local item = item_under_cursor(view)
      if item and item.uri then
        resume.set_feed(view.kind, item.uri)
      end
    end
    maybe_more(view)
  end)
end

---a question row previews its answer list, so the pane carries zhihu uris of its
---own; <CR> opens the one under the cursor the way a list buffer would
---@param view table
function M.follow_entry(view)
  if not vim.api.nvim_win_is_valid(view.prev_win) then
    return
  end
  local line = vim.api.nvim_get_current_line()
  local url = require("zhihu.nvim.list").entry_url(line)
  if url ~= nil then
    vim.cmd.edit(vim.fn.fnameescape(url))
    return
  end
  -- a picture is a line carrying its address: hand it to whatever opens links
  local link = tostring(line):match "https?://[^%s`%)]+"
  if link == nil then
    vim.notify("zhihu: 光标下没有链接", vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(vim.ui.open, link)
  if not ok then
    vim.notify("zhihu: 打不开 " .. link .. "（" .. tostring(err) .. "）", vim.log.levels.WARN)
  end
end

---@param view table
function M.enter(view)
  -- there is no pane worth opening for a row whose only home is a web page
  local item = item_under_cursor(view)
  if item and M.dead(item) then
    return M.open_browser(view)
  end
  if item then
    -- <CR> is a decision, not a pass: this is the row to come back to
    if view.kind ~= "search" then
      resume.set_feed(view.kind, item.uri)
    end
    fetch_body(view)
  end
  if vim.api.nvim_win_is_valid(view.prev_win) then
    vim.api.nvim_set_current_win(view.prev_win)
  end
end

---@param view table
function M.edit_entry(view)
  local item = item_under_cursor(view)
  if item == nil then
    return
  end
  if item.uri == nil then
    M.open_browser(view)
    return
  end
  if vim.api.nvim_win_is_valid(view.prev_win) then
    vim.api.nvim_set_current_win(view.prev_win)
  end
  resume.mark_read(item.uri, item)
  vim.cmd.edit(vim.fn.fnameescape(item.uri))
end

---@param view table
function M.open_browser(view)
  local item = item_under_cursor(view)
  local url = item and M.web_url(item)
  if url == nil then
    vim.notify("zhihu: 这一条没有可以打开的地址", vim.log.levels.WARN)
    return
  end
  vim.ui.open(url)
end

---the reader's own note-taking: a body already on screen is the only thing worth
---carrying away, so both actions ask for one instead of downloading behind the
---reader's back
---@param view table
---@param action string
---@return table? item
---@return string[]? body
local function carry_away(view, action)
  local item = item_under_cursor(view)
  if item == nil then
    return nil
  end
  local body = M.shown_body(view)
  if body == nil then
    vim.notify(("zhihu: 先按 <CR> 把正文拉下来，再 %s"):format(action), vim.log.levels.WARN)
    return nil
  end
  return item, body
end

---yank the entry as a quote block; the unnamed register always gets it, and the
---system clipboard when this build has one
---@param view table
function M.yank_quote(view)
  local item, body = carry_away(view, "yank")
  if item == nil then
    return
  end
  local lines = M.quote_lines(item, body)
  vim.fn.setreg('"', lines, "v")
  if vim.fn.has "clipboard" == 1 then
    pcall(vim.fn.setreg, "+", lines, "v")
  end
  vim.notify(("zhihu: 已 yank 引用块（%d 行），粘贴即可"):format(#lines))
end

---write the entry to a markdown file, asking for the path first
---@param view table
function M.save_md(view)
  local item, body = carry_away(view, "存")
  if item == nil then
    return
  end
  local lines = M.md_lines(item, body)
  local default = vim.fn.expand "~/zhihu" .. "/" .. M.md_name(item.title, item.tag)
  vim.ui.input({ prompt = "存到：", default = default, completion = "file" }, function(input)
    local path = input and vim.trim(input) or ""
    if path == "" then
      return
    end
    -- expand() answers an empty string for a path that does not exist yet
    path = vim.fn.fnamemodify(path, ":p")
    local parent = vim.fn.fnamemodify(path, ":h")
    if parent ~= "" and parent ~= "." then
      vim.fn.mkdir(parent, "p")
    end
    local ok, err = pcall(vim.fn.writefile, lines, path)
    if not ok then
      vim.notify("zhihu: 写不进去：" .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.notify("zhihu: 已存到 " .. path)
  end)
end

---a status page in the list: loading, failure and empty are three different
---situations and only one of them is about the cookie
---@param view table
---@param lines string[]
local function status(view, lines)
  view.row_item = nil
  vim.bo[view.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.list_buf, 0, -1, false, lines)
  vim.bo[view.list_buf].modifiable = false
  ns = ns or vim.api.nvim_create_namespace "zhihu-feed"
  vim.api.nvim_buf_clear_namespace(view.list_buf, ns, 0, -1)
end

---the first page: the panes open at once and the rows arrive afterwards, so a
---slow request never looks like a hung editor or an expired cookie
---@param view table
local function load(view)
  local session = view.session
  view.state = "loading"
  status(view, { ("  正在拉「%s」…"):format(view.label) })
  update_winbar(view)

  local function failed(reason)
    view.state = "error"
    status(view, { "  这一路没拉下来。", "", tostring(reason), "", "  r 重试    q 关掉" })
    update_winbar(view)
  end

  ---the rows are in the session: paint them, or say why there are none
  local function paint()
    if #session.items == 0 then
      -- an empty page is not proof of an expired cookie, and saying so would
      -- send the reader to the browser for nothing
      view.state = "empty"
      status(view, {
        ("  「%s」这一页是空的。"):format(view.label),
        "",
        "  可能是登录态失效，也可能这一路暂时没有内容。",
        "",
        "  r 重试    q 关掉",
      })
      update_winbar(view)
      return
    end
    view.state = "ready"
    render_list(view)
    update_winbar(view)
    restore_row(view)
    update_preview(view)
    maybe_more(view)
  end

  if not require("zhihu.nvim.http").available() then
    -- without curl the page is fetched in this process; the status page is
    -- already painted, so the wait happens on a screen that says so
    local ok, added, err = pcall(session.more, session, M.batch)
    if not ok then
      return failed(added)
    end
    if err then
      return failed(err)
    end
    return paint()
  end
  require("zhihu.api.get.feed").page_async(session.url, function(err, body)
    -- the view may have been closed while the request was in flight
    if not vim.api.nvim_buf_is_valid(view.list_buf) then
      return
    end
    if err then
      return failed(err)
    end
    local ok, message = pcall(session.take, session, body)
    if not ok then
      return failed(message)
    end
    paint()
  end)
end

---re-run a stream that failed or came back empty
---@param view table
function M.reload(view)
  if view.state == "loading" or view.state == "ready" then
    return
  end
  view.fetching = nil
  view.session = view.session_factory and view.session_factory()
    or require("zhihu.api.get.feed").session(view.kind)
  view.loaded = nil
  load(view)
end

---fold the browser-only rows out of the list, or bring them back
---@param view table
function M.toggle_dead(view)
  local item = item_under_cursor(view)
  view.show_dead = not view.show_dead
  if view.state ~= "ready" then
    return update_winbar(view)
  end
  render_list(view)
  update_winbar(view)
  -- the rows move under the cursor: keep the entry the reader was looking at
  if item then
    for row, index in pairs(view.row_item or {}) do
      if view.session.items[index] == item then
        pcall(vim.api.nvim_win_set_cursor, view.list_win, { row, 0 })
        break
      end
    end
  end
  update_preview(view)
end

---open one feed: list on the left, the entry under the cursor on the right
---@param kind "hot"|"recommend"|"follow"
function M.open(kind)
  local feed = require 'zhihu.api.get.feed'
  return M.present {
    kind = kind,
    label = feed.tag[kind] or kind,
    session = feed.session(kind),
    session_factory = function()
      return feed.session(kind)
    end,
    -- 热榜 is a browser launcher by nature: folding its rows would leave two
    -- entries standing in for thirty
    show_dead = kind == "hot",
    buf_name = M.name .. kind,
  }
end

---the same two panes, over the site search
---@param query string
function M.search(query)
  local search = require 'zhihu.api.get.search'
  query = vim.trim(query or ""):gsub("%c", " ")
  if query == "" then
    return
  end
  return M.present {
    kind = "search",
    label = "搜索：" .. M.truncate(query, 40),
    session = search.session(query),
    session_factory = function()
      return search.session(query)
    end,
    show_dead = false,
    buf_name = M.name .. "search:" .. query,
  }
end

---draw the panes and hand them to load(): no request happens here
---@param view table
function M.present(view)
  if M.view then
    M.close(M.view)
  end
  view.state = "loading"
  view.loaded = nil
  view.fetching = nil
  M.view = view

  view.list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(view.list_buf, view.buf_name)
  vim.bo[view.list_buf].bufhidden = "wipe"
  vim.bo[view.list_buf].swapfile = false
  vim.bo[view.list_buf].modifiable = false
  vim.api.nvim_win_set_buf(0, view.list_buf)
  view.list_win = vim.api.nvim_get_current_win()

  vim.cmd "vertical rightbelow split"
  view.prev_win = vim.api.nvim_get_current_win()
  view.prev_buf = nil
  ensure_preview(view)

  vim.wo[view.list_win].cursorline = true
  vim.wo[view.list_win].number = false
  vim.wo[view.list_win].relativenumber = false
  vim.wo[view.list_win].signcolumn = "no"
  vim.wo[view.list_win].wrap = false
  vim.wo[view.list_win].winfixwidth = true
  vim.wo[view.prev_win].wrap = true
  vim.wo[view.prev_win].number = false
  vim.wo[view.prev_win].signcolumn = "no"
  vim.wo[view.prev_win].spell = false

  local width = math.max(M.min_width, math.floor(vim.o.columns * M.ratio))
  pcall(vim.api.nvim_win_set_width, view.list_win, width)
  vim.api.nvim_set_current_win(view.list_win)

  local list_buf = view.list_buf
  map(list_buf, "q", function() M.close(view) end, "zhihu: 关掉这个流")
  map(list_buf, "<CR>", function() M.enter(view) end, "zhihu: 选中这一条并拉正文")
  map(list_buf, "e", function() M.edit_entry(view) end, "zhihu: 用完整缓冲区打开")
  map(list_buf, "o", function() M.open_browser(view) end, "zhihu: 浏览器打开")
  map(list_buf, "r", function() M.reload(view) end, "zhihu: 重试拉取这一路")
  map(list_buf, "z", function() M.toggle_dead(view) end, "zhihu: 折叠/展开仅浏览器条目")

  load(view)
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = list_buf,
    callback = function()
      if vim.api.nvim_get_current_buf() == list_buf then
        on_move(view)
      end
    end,
  })
  watch_list(view)
  return view
end

return M
