---regression tests for cookie scoping: lua/zhihu/api.lua and lua/zhihu/api/put.lua
---plain luajit: auth and the HTTP layer are stubbed, cookie derivation is the real code
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

local captured = {}
local cookie_lookups = {}

local function copy(tbl)
  local out = {}
  for k, v in pairs(tbl or {}) do
    out[k] = v
  end
  return out
end

local function capture(verb)
  return function(api)
    captured[verb] = { url = api.url, headers = copy(api.headers) }
    return { status_code = 200 }
  end
end

package.preload["requests"] = function()
  return {
    get = capture("get"),
    post = capture("post"),
    patch = capture("patch"),
    put = capture("put"),
  }
end

package.preload["sha1"] = function()
  return { hmac_binary = function() return "hmac" end }
end

package.preload["vim.base64"] = function()
  return { encode = function(s) return "signature" end }
end

package.preload["vim.json"] = function()
  return {
    encode = function(v) return v end,
    decode = function() return {} end,
  }
end

--the cache is the only thing standing between us and a network call, stub it and
--make the returned cookie jar print the host it was asked for
package.preload["auth.cache"] = function()
  return {
    Auth = function()
      return {
        get_cookies = function(_, host)
          cookie_lookups[#cookie_lookups + 1] = host
          return setmetatable({}, {
            __tostring = function() return tostring(host) end,
          })
        end,
      }
    end,
  }
end

vim = { json = require "vim.json" }

local API = require("zhihu.api")
local Get = require("zhihu.api.get").API
local Post = require("zhihu.api.post").API
local Patch = require("zhihu.api.patch").API
local Put = require("zhihu.api.put").API

return {
  name = "cookie scope",
  run = function(t)
    -- 1. the cookie domain is derived from the request url
    local mapping = {
      { "https://www.zhihu.com/x", ".zhihu.com" },
      { "https://zhuanlan.zhihu.com/p/123", ".zhihu.com" },
      { "https://api.zhihu.com/images/1", ".zhihu.com" },
      { "https://sub.zhihu.com/a", ".zhihu.com" },
      { "https://www.zhihu.com:443/x?y=1", ".zhihu.com" },
      { "https://zhihu.com/", ".zhihu.com" },
      { "https://evil.example.com/x", ".example.com" },
      { "localhost:8080/x", "localhost" },
      { "http://localhost/x", "localhost" },
    }
    for _, case in ipairs(mapping) do
      t.eq(("cookie domain of %q is %s"):format(case[1], case[2]), API.dumps_cookies_for_url(case[1]), case[2])
    end
    t.eq("an empty url falls back to .zhihu.com", API.dumps_cookies_for_url(""), ".zhihu.com")
    t.eq("a nil url falls back to .zhihu.com", API.dumps_cookies_for_url(nil), ".zhihu.com")

    -- 2. every zhihu verb authenticates with the Cookie header
    Get.from_id("123"):request()
    t.eq("GET requests the expected url", captured.get.url, "https://zhuanlan.zhihu.com/p/123")
    t.eq("GET sets the Cookie header", captured.get.headers.Cookie, ".zhihu.com")

    Get({ url = "https://a.example.com/x" }):request()
    t.eq("GET scopes the Cookie header to the request host", captured.get.headers.Cookie, ".example.com")

    Post({ url = "https://www.zhihu.com/api/v4/content/publish" }):request()
    t.eq("POST sets the Cookie header", captured.post.headers.Cookie, ".zhihu.com")

    Patch({ url = "https://zhuanlan.zhihu.com/api/articles/1/draft" }):request()
    t.eq("PATCH sets the Cookie header", captured.patch.headers.Cookie, ".zhihu.com")

    -- 3. the OSS upload must never ship zhihu credentials
    local put = Put.from_access_token("data", "image/png", "obj/key", "access-id", "access-token", "access-key")
    t.ok("OSS PUT builds an Authorization header",
      type(put.headers["Authorization"]) == "string" and put.headers["Authorization"]:match("^OSS access%-id:") ~= nil,
      put.headers["Authorization"])
    t.ok("OSS PUT headers carry no Cookie", put.headers.Cookie == nil)

    local lookups_before = #cookie_lookups
    put:request()
    t.ok("OSS PUT request carries no Cookie", captured.put.headers.Cookie == nil)
    t.eq("OSS PUT never asks the cookie cache", #cookie_lookups, lookups_before)
    t.ok("OSS PUT class headers stay cookie free", Put.headers.Cookie == nil)
  end,
}
