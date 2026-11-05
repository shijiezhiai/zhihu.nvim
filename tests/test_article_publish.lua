---regression tests for the publish/overwrite guard in lua/zhihu/article.lua
---plain luajit: every plugin dependency is stubbed, the article module is the real one
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local state = { confirms = 0, confirm_answer = 2, notifies = {}, uis = 1, calls = {}, buf_reads = 0 }
local json_state = { publish_question = nil }

local function root_node(text)
  local node = { _text = text or "" }
  node.gettext = function(self) return self._text end
  node.select = function() return {} end
  return setmetatable(node, { __tostring = node.gettext })
end

package.preload["vim.fs"] = function()
  return {
    basename = function(p) return (tostring(p):gsub(".*/", "")) end,
    dirname = function(p) return (tostring(p):gsub("/[^/]*$", "")) end,
  }
end

package.preload["vim.shared"] = function()
  return {
    split = function(s, sep)
      local out = {}
      for part in tostring(s):gmatch("[^" .. sep .. "]+") do
        out[#out + 1] = part
      end
      return out
    end,
  }
end

package.preload["vim.json"] = function()
  return {
    encode = function(v) return v end,
    decode = function()
      return { publish = { id = "123", question = json_state.publish_question } }
    end,
  }
end

package.preload["htmlEntities"] = function()
  return { decode = function(s) return s end }
end

package.preload["datafile"] = function()
  return { open = function() return nil end }
end

package.preload["htmlparser"] = function()
  return { parse = function(text) return root_node(text) end }
end

package.preload["markdown_to_html"] = function()
  return { md_to_html = function(s) return s end }
end

package.preload["zfh"] = function()
  return {
    writer = function(s) return s end,
    reader = function(s) return s end,
  }
end

local function api_mock(name, resp)
  return {
    API = {
      from_article = function()
        return {
          request = function()
            state.calls[name] = (state.calls[name] or 0) + 1
            return resp
          end,
        }
      end,
    },
  }
end

package.preload["zhihu.api.post.article"] = function()
  return api_mock("post_article", { status_code = 200, json = function() return { id = "123" } end })
end
package.preload["zhihu.api.patch"] = function()
  return api_mock("patch", { status_code = 200 })
end
package.preload["zhihu.api.post.answer"] = function()
  return api_mock("post_answer", { status_code = 200 })
end
package.preload["zhihu.api.post.publish"] = function()
  return api_mock("publish", {
    status_code = 200,
    json = function() return { code = 0, data = { result = "{}" } } end,
  })
end

vim = {
  o = { modifiable = true, modified = true, buftype = "" },
  b = {},
  api = {
    nvim_buf_get_lines = function()
      state.buf_reads = state.buf_reads + 1
      return { "# heading", "body" }
    end,
    nvim_list_uis = function()
      local uis = {}
      for i = 1, state.uis do
        uis[i] = {}
      end
      return uis
    end,
  },
  fn = {
    confirm = function()
      state.confirms = state.confirms + 1
      return state.confirm_answer
    end,
  },
  notify = function(msg, level)
    state.notifies[#state.notifies + 1] = { msg = msg, level = level }
  end,
  log = { levels = { WARN = 3, ERROR = 4 } },
  fs = require "vim.fs",
  shared = require "vim.shared",
  json = require "vim.json",
}

local Article = require("zhihu.article").Article

local function new_article(fields)
  local article = fields or {}
  article.root = root_node()
  return Article:new(article)
end

local function reset(uis)
  state.confirms = 0
  state.confirm_answer = 2
  state.notifies = {}
  state.uis = uis or 1
  state.calls = {}
  state.buf_reads = 0
  json_state.publish_question = nil
end

---the state read_cb leaves behind: an article without root, buffer text pending
local function reset_buffer(fields)
  vim.o.modifiable = true
  vim.o.modified = true
  vim.b = { article = fields or { itemId = "42" } }
  state.buf_reads = 0
end

local function error_notifies()
  local n = 0
  for _, item in ipairs(state.notifies) do
    if item.level == vim.log.levels.ERROR then
      n = n + 1
    end
  end
  return n
end

local write_cb = require("zhihu.nvim.callback").write_cb

return {
  name = "article publish guard",
  run = function(t)
    -- 1. a brand new article must never prompt on its first write
    reset()
    local fresh = new_article({})
    t.eq("new article defaults isPublished to false", fresh.isPublished, false)
    local err, aborted = fresh:write()
    t.ok("first write of a new article succeeds", err == nil and aborted == nil, err)
    t.eq("first write does not prompt", state.confirms, 0)
    t.eq("first write marks the article published", fresh.isPublished, true)
    t.eq("first write goes through the publish api", state.calls.publish, 1)

    -- 2. the same article is published now, so a second write asks exactly once
    reset()
    local err2, aborted2 = fresh:write()
    t.eq("second write prompts once", state.confirms, 1)
    t.ok("declining the prompt aborts", aborted2 == true and err2 == nil, err2)
    t.eq("declined write does not publish", state.calls.publish, nil)
    t.eq("declined write leaves the article published", fresh.isPublished, true)

    -- 3. accepting the prompt proceeds with the write
    reset()
    state.confirm_answer = 1
    local err3, aborted3 = fresh:write()
    t.ok("accepted prompt lets the write through", err3 == nil and aborted3 == nil, err3)
    t.eq("accepted prompt publishes again", state.calls.publish, 1)

    -- 4. a server side draft already has an itemId, only data-zop knows it is not published
    reset()
    local draft = new_article({ itemId = "77", isPublished = false })
    t.eq("server draft keeps isPublished false", draft.isPublished, false)
    local derr, daborted = draft:write()
    t.ok("server draft write succeeds", derr == nil and daborted == nil, derr)
    t.eq("server draft write never prompts", state.confirms, 0)
    t.eq("server draft write still publishes", state.calls.publish, 1)

    -- 5. an article rebuilt from itemId alone (the from_id path) counts as published
    reset()
    json_state.publish_question = { id = "9", title = "T" }
    local live = new_article({ itemId = "42", question_id = "9" })
    t.eq("itemId only article isPublished is true", live.isPublished, true)
    local lerr, laborted = live:write()
    t.eq("published article prompts once", state.confirms, 1)
    t.ok("declining the published article aborts", laborted == true and lerr == nil, lerr)

    -- 6. headless: published content is refused with a WARN, new content still publishes
    reset(0)
    local headless = new_article({ itemId = "42" })
    local herr, haborted = headless:write()
    t.ok("headless published write is refused", haborted == true and herr == nil, herr)
    t.eq("headless refusal does not prompt", state.confirms, 0)
    t.eq("headless refusal notifies once", #state.notifies, 1)
    t.eq("headless refusal notifies WARN", state.notifies[1] and state.notifies[1].level, 3)
    local nerr, naborted = new_article({}):write()
    t.ok("headless new article still publishes", nerr == nil and naborted == nil, nerr)
    t.eq("headless new article adds no notification", #state.notifies, 1)

    -- 7. confirm_publish = false opts out for published content
    reset()
    new_article({ itemId = "42", confirm_publish = false }):write()
    t.eq("confirm_publish=false skips the prompt", state.confirms, 0)

    -- 8. an explicit data-zop boolean wins even without an itemId
    reset()
    new_article({ isPublished = true }):write()
    t.eq("explicit isPublished=true is trusted", state.confirms, 1)

    -- 9. draft only writes (publish=false) never prompt, even for published content
    reset()
    local draft_only = new_article({ itemId = "42" })
    local uerr, uaborted = draft_only:write(false)
    t.ok("draft only write of published content succeeds", uerr == nil and uaborted == nil, uerr)
    t.eq("draft only write never prompts", state.confirms, 0)
    t.eq("draft only write patches the draft", state.calls.patch, 1)
    t.eq("draft only write does not publish", state.calls.publish, nil)

    -- 10. buffer level ':w' on published content, answer No: the buffer must stay dirty
    reset()
    reset_buffer()
    write_cb()
    t.eq("declined buffer write reads the buffer", state.buf_reads, 1)
    t.eq("declined buffer write confirms once", state.confirms, 1)
    t.eq("declined buffer write keeps the buffer modified", vim.o.modified, true)
    t.eq("declined buffer write publishes nothing", state.calls.publish, nil)
    t.eq("declined buffer write patches nothing", state.calls.patch, nil)
    -- .root would fall back through __index to the class default, so check the own field
    t.eq("declined buffer write drops the article's own root", rawget(vim.b.article, "root"), nil)
    t.eq("declined buffer write reports no error", error_notifies(), 0)
    t.eq("declined buffer write keeps the article id", vim.b.article.itemId, "42")

    -- 11. answering Yes runs the write and only then clears the modified flag
    reset()
    state.confirm_answer = 1
    reset_buffer()
    write_cb()
    t.eq("accepted buffer write confirms once", state.confirms, 1)
    t.eq("accepted buffer write clears modified", vim.o.modified, false)
    t.eq("accepted buffer write publishes", state.calls.publish, 1)
    t.eq("accepted buffer write reports no error", error_notifies(), 0)

    -- 12. a non modifiable buffer is left alone before anything is read
    reset()
    reset_buffer()
    vim.o.modifiable = false
    write_cb()
    t.eq("unmodifiable buffer write is a no-op", state.buf_reads, 0)
    t.eq("unmodifiable buffer write does not confirm", state.confirms, 0)
    t.eq("unmodifiable buffer write keeps modified", vim.o.modified, true)
    t.eq("unmodifiable buffer write calls no api", state.calls.publish, nil)
  end,
}
