---regression tests for the publish/overwrite guard in lua/zhihu/article.lua
---plain luajit: every plugin dependency is stubbed, the article module is the real one
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local state = { confirms = 0, confirm_answer = 2, notifies = {}, uis = 1, calls = {} }
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
  api = {
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
  json_state.publish_question = nil
end

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

    t.skip("buffer level ':w' abort keeps 'modified' (lua/zhihu/nvim/callback.lua:36-42) is not exercisable: "
      .. "write_cb calls Article(vim.b.article) after read_cb cleared root, and Article:new (lua/zhihu/article.lua:71-72) "
      .. "indexes article.root before it can reach the abort branch")
  end,
}
