---answer and article bodies come from the apis, not from the pages: the pages
---answer a new-format id with an anti-bot challenge
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

-- the module decodes an empty document for the page template it ships with
local state = { matches = {}, bodies = { ["{}"] = {} } }

local function node(text)
  local self = { _text = text or "" }
  self.gettext = function() return self._text end
  -- the page metadata and the body are different selectors in the real parser
  -- called with a colon, so the selector is the second argument
  self.select = function(_, selector)
    if tostring(selector):find("data%-zop") then
      return {}
    end
    return state.matches
  end
  return setmetatable(self, { __tostring = self.gettext })
end

package.preload["vim.fs"] = function()
  return {
    basename = function(p) return (tostring(p):gsub(".*/", "")) end,
    dirname = function(p) return (tostring(p):gsub("/[^/]*$", "")) end,
  }
end

package.preload["vim.shared"] = function()
  return {
    split = function(s)
      local out = {}
      for part in tostring(s):gmatch "[^\n]+" do
        out[#out + 1] = part
      end
      return out
    end,
  }
end

package.preload["vim.json"] = function()
  return {
    encode = function() return "{}" end,
    decode = function(text)
      local value = state.bodies[text]
      if value == nil then
        error("unexpected json " .. tostring(text))
      end
      -- every caller gets its own table: the article constructor mutates it
      local function copy(node)
        if type(node) ~= "table" then
          return node
        end
        local out = {}
        for k, v in pairs(node) do
          out[k] = copy(v)
        end
        return out
      end
      return copy(value)
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
  return { parse = function(text) return node(text) end }
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

vim = { fn = {}, api = {}, o = {} }

local article = require "zhihu.article"

return {
  name = "article bodies",
  run = function(t)
    t.eq("an answer asks the answer api",
      article.api_url { itemId = "42", question_id = "7" },
      "https://www.zhihu.com/api/v4/answers/42?include=content")
    t.eq("an article asks the zhuanlan api",
      article.api_url { itemId = "207" },
      "https://zhuanlan.zhihu.com/api/articles/207")
    t.eq("a uri without an id has no api", article.api_url {}, nil)

    local document = article.body_document "<p>body</p>"
    t.ok("the body arrives wrapped as the page selector expects",
      document:find('class="RichText ztext"', 1, true) ~= nil)
    t.ok("the body survives intact", document:find("<p>body</p>", 1, true) ~= nil)

    -- zhihu renders every formula as an image that carries its own tex: it has
    -- to come back as maths, not as an <img> tag
    local bs = string.char(92)
    local inline = article.equations([[
      <p>直接推荐 <img src="https://www.zhihu.com/equation?tex=%5Cpi" alt="pi" eeimg="1" class="content_image"/></p>]])
    t.ok("an inline formula becomes tex", inline:find("$" .. bs .. "pi$", 1, true) ~= nil)
    t.ok("and its image tag is gone", inline:find("<img", 1, true) == nil)
    local lazy = article.equations([[
      <figure><noscript><img src="https://www.zhihu.com/equation?tex=%5Cpi" alt="pi"/></noscript>
      <img src="data:image/svg+xml;utf8,&lt;svg&gt;" alt="pi" eeimg="1" data-actualsrc="https://www.zhihu.com/equation?tex=%5Cfrac%7B%5Cpi%7D%7B4%7D+%3D+%5Carctan%281%29"/></figure>]])
    t.ok("a lazy formula reads the address it would have loaded",
      lazy:find("$" .. bs .. "frac{" .. bs .. "pi}{4} = " .. bs .. "arctan(1)$", 1, true) ~= nil)
    t.eq("a formula without a tex parameter falls back to its alt",
      article.equations '<img alt="E=mc^2" src="data:image/svg+xml;utf8,equation"/>', "$E=mc^2$")
    t.eq("a plus in the url stands for a space",
      article.equations '<img src="https://www.zhihu.com/equation?tex=a+b%3Dc"/>', "$a b=c$")
    t.eq("an ordinary picture is left alone", article.equations '<img src="https://pic1.zhimg.com/a.png"/>',
      '<img src="https://pic1.zhimg.com/a.png"/>')
    t.eq("markup without formulas is untouched", article.equations "<p>no maths</p>", "<p>no maths</p>")

    t.eq("a picture becomes one line carrying its address",
      article.images '<p>a</p><img src="https://pic1.zhimg.com/a.jpg"/><p>b</p>',
      '<p>a</p>\n\n[图片 1] https://pic1.zhimg.com/a.jpg\n\n<p>b</p>')
    t.eq("the numbers follow the page",
      article.images '<img src="https://pic1.zhimg.com/1.jpg"/><img src="https://pic1.zhimg.com/2.jpg"/>',
      '\n\n[图片 1] https://pic1.zhimg.com/1.jpg\n\n\n\n[图片 2] https://pic1.zhimg.com/2.jpg\n\n')
    t.eq("a lazy picture uses the address it would have loaded",
      article.images '<img src="data:image/svg+xml;utf8,&lt;svg&gt;" data-actualsrc="https://pic2.zhimg.com/b.jpg"/>',
      '\n\n[图片 1] https://pic2.zhimg.com/b.jpg\n\n')
    t.eq("a picture with nothing to open is dropped",
      article.images '<p>a</p><img src="data:image/svg+xml;utf8,&lt;svg&gt;"/><p>b</p>', "<p>a</p><p>b</p>")
    t.eq("the figure around a picture stops reading as an image",
      article.images '<figure data-size="normal"><img src="https://pic1.zhimg.com/c.jpg"/></figure>',
      "<p>\n\n[图片 1] https://pic1.zhimg.com/c.jpg\n\n</p>")
    t.eq("a formula image is left to equations",
      article.images '<img src="https://www.zhihu.com/equation?tex=%5Cpi"/>',
      '<img src="https://www.zhihu.com/equation?tex=%5Cpi"/>')
    t.eq("markup without pictures is untouched", article.images "<p>no pictures</p>", "<p>no pictures</p>")

    state.bodies['{"content":"<p>a</p>"}'] = { content = "<p>a</p>" }
    t.eq("the answer api answers without a wrapper", article.body_content '{"content":"<p>a</p>"}', "<p>a</p>")

    state.bodies['{"data":{"content":"<p>b</p>"}}'] = { data = { content = "<p>b</p>" } }
    t.eq("the article api wraps the body", article.body_content '{"data":{"content":"<p>b</p>"}}', "<p>b</p>")

    t.eq("an error body carries no content", article.body_content '{"error":{"code":10003}}', nil)
    t.eq("a body that is not json carries no content", article.body_content "<!DOCTYPE html>", nil)
    t.eq("an empty content field is not a body", article.body_content '{"content":""}', nil)

    t.ok("a challenge page is named as one",
      article.missing_reason('<meta id="zh-zse-ck">'):find("验证墙", 1, true) ~= nil)
    t.ok("an empty response says so", article.missing_reason(""):find("空响应", 1, true) ~= nil)
    t.ok("anything else blames the login", article.missing_reason("<html></html>"):find("登录态", 1, true) ~= nil)

    -- no body element anywhere: the page is a challenge wall
    state.matches = {}
    local wall = article.Article:from_html('<meta id="zh-zse-ck">')
    t.eq("a page without a body is not rendered", wall.missing ~= nil, true)
    t.eq("and it says so instead of dumping html", wall:get_lines()[1], "# 打不开这一条")

    -- a body element is rendered as usual
    state.matches = { node "<p>text</p>" }
    local real = article.Article:from_html "<div class='RichText ztext'><p>text</p></div>"
    t.eq("a page with a body has nothing missing", real.missing, nil)
  end,
}
