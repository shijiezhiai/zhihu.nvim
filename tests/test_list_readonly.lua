---the neovim side of a list buffer: a read only snapshot plus a buffer local <CR>
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local state = {
  set_lines = {},
  notifications = {},
  edits = {},
  mappings = {},
  confirms = 0,
  current_line = "",
}

_G.vim = {
  log = { levels = { INFO = 1, WARN = 3, ERROR = 4 } },
  o = { modifiable = true, modified = false },
  b = {},
  api = {
    nvim_buf_set_lines = function(buf, first, last, strict, lines)
      state.set_lines[#state.set_lines + 1] =
        { buf = buf, first = first, last = last, strict = strict, lines = lines }
    end,
    nvim_get_current_line = function() return state.current_line end,
    nvim_buf_get_name = function() return "" end,
  },
  notify = function(msg, level)
    state.notifications[#state.notifications + 1] = { msg = msg, level = level }
  end,
  cmd = {
    edit = function(url) state.edits[#state.edits + 1] = url end,
  },
  keymap = {
    set = function(mode, lhs, rhs, opts)
      state.mappings[#state.mappings + 1] = { mode = mode, lhs = lhs, rhs = rhs, opts = opts }
    end,
  },
  fn = {
    confirm = function()
      state.confirms = state.confirms + 1
      return 0
    end,
  },
}

local list = require("zhihu.nvim.list")

local function fake_list(lines)
  return { get_lines = function() return lines end }
end

local function last(t)
  return t[#t]
end

return {
  name = "list buffer is read only",
  run = function(t)
    local lines = { "# 如何评价测试驱动开发？", "答案 1–2 / 共 137 · 第 1 页" }
    local handle = fake_list(lines)
    list.read_cb(handle)

    local wrote = last(state.set_lines)
    t.eq("read_cb replaces the whole buffer", wrote.buf, 0)
    t.eq("read_cb starts at line 0", wrote.first, 0)
    t.eq("read_cb ends at -1", wrote.last, -1)
    t.eq("read_cb sets lines strictly", wrote.strict, true)
    t.eq("read_cb writes the rendered lines", wrote.lines, lines)
    t.eq("read_cb publishes the list on the buffer", vim.b.zhihu_list, handle)
    t.eq("read_cb locks the buffer", vim.o.modifiable, false)

    local mapping = last(state.mappings)
    t.eq("the mapping is normal mode", mapping.mode, "n")
    t.eq("the mapping is <CR>", mapping.lhs, "<CR>")
    t.eq("the mapping is buffer local", mapping.opts.buffer, true)
    t.eq("the mapping does not wait", mapping.opts.nowait, true)
    t.eq("read_cb installs exactly one mapping", #state.mappings, 1)

    -- the write path: warn, return, touch nothing
    vim.o.modified = true
    local before_lines = #state.set_lines
    list.write_cb()
    local warned = last(state.notifications)
    t.eq("write_cb warns once", #state.notifications, 1)
    t.eq("write_cb says the buffer is read only", warned.msg, "zhihu: 列表缓冲区是只读的")
    t.eq("write_cb warns at WARN level", warned.level, vim.log.levels.WARN)
    t.eq("write_cb writes no lines", #state.set_lines, before_lines)
    t.eq("write_cb keeps the buffer locked", vim.o.modifiable, false)
    t.eq("write_cb leaves the modified flag alone", vim.o.modified, true)
    t.eq("write_cb asks nothing", state.confirms, 0)
    t.eq("write_cb sends no request", package.loaded["requests"], nil)
    t.eq("write_cb never edits", #state.edits, 0)

    -- <CR> on an entry line opens it, on anything else it warns
    state.current_line = "1. **先说结论。** — @张三 · 赞 1234 · 评论 56"
    t.eq("a summary line carries no uri", list.entry_url(state.current_line), nil)
    state.current_line = "    `zhihu://www.zhihu.com/question/19550517/answer/40211301.md`"
    t.eq("an entry line carries its uri", list.entry_url(state.current_line),
      "zhihu://www.zhihu.com/question/19550517/answer/40211301.md")
    t.eq("a pager line stops at the closing paren",
      list.entry_url("[下一页](zhihu://www.zhihu.com/question/19550517/answers-20.md)"),
      "zhihu://www.zhihu.com/question/19550517/answers-20.md")
    t.eq("a foreign uri is ignored", list.entry_url("[x](https://example.com/a.md)"), nil)

    state.current_line = "[下一页](zhihu://www.zhihu.com/question/19550517/answers-20.md)"
    list.open_entry()
    t.eq("open_entry edits the uri under the cursor", last(state.edits),
      "zhihu://www.zhihu.com/question/19550517/answers-20.md")
    t.eq("open_entry edits once", #state.edits, 1)

    state.current_line = "# 如何评价测试驱动开发？"
    list.open_entry()
    t.eq("open_entry without a uri edits nothing", #state.edits, 1)
    t.eq("open_entry without a uri says so", last(state.notifications).msg, "zhihu: 光标下没有知乎链接")

    t.eq("the nvim side loads no http client", package.loaded["requests"], nil)
  end,
}
