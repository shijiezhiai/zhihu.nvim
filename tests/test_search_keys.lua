---the default search key: what it asks for, and when it keeps its hands off
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local asked, callback, searched, maps = nil, nil, {}, {}
local taken = ""

_G.vim = {
  trim = function(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
  end,
  ui = {
    input = function(opts, cb)
      asked, callback = opts, cb
    end,
  },
  keymap = {
    set = function(mode, lhs, rhs, opts)
      maps[#maps + 1] = { mode = mode, lhs = lhs, rhs = rhs, desc = opts and opts.desc }
    end,
  },
  fn = {
    maparg = function() return taken end,
  },
  log = { levels = { WARN = 3 } },
  notify = function() end,
}

package.preload["zhihu.nvim.browse"] = function()
  return {
    search = function(query)
      searched[#searched + 1] = query
    end,
  }
end

local zhihu = require("zhihu")

local function by_lhs(lhs)
  for _, map in ipairs(maps) do
    if map.lhs == lhs then
      return map
    end
  end
end

return {
  name = "search key",
  run = function(t)
    zhihu.prompt_search()
    t.eq("the key asks for a query", asked and asked.prompt, "搜索知乎：")

    callback("  欧拉 公式  ")
    t.eq("the answer is trimmed and searched", searched[#searched], "欧拉 公式")
    t.eq("and only once", #searched, 1)

    callback("   ")
    t.eq("blank input searches nothing", #searched, 1)

    callback(nil)
    t.eq("cancelling searches nothing", #searched, 1)

    zhihu.create_keymaps()
    local plug = by_lhs("<Plug>(zhihu-search)")
    t.ok("a plug mapping is always offered", plug ~= nil)
    t.eq("the plug runs the prompt", plug and plug.rhs, zhihu.prompt_search)
    t.eq("it is a normal mode map", plug and plug.mode, "n")

    local leader = by_lhs("<leader>zs")
    t.ok("a free <leader>zs is taken", leader ~= nil)
    t.eq("and points at the plug", leader and leader.rhs, "<Plug>(zhihu-search)")
    t.eq("with a description", leader and leader.desc, "zhihu: 搜索（先输入关键词）")

    maps = {}
    taken = "<Leader>zs"
    zhihu.create_keymaps()
    t.ok("a taken <leader>zs is left alone", by_lhs("<leader>zs") == nil)
    t.ok("the plug is still offered", by_lhs("<Plug>(zhihu-search)") ~= nil)
  end,
}
