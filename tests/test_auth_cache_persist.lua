---regression tests for the opt-in cookie persistence gate in packages/auth/lua/auth/cache.lua
---plain luajit: the chained auth (browsers) is stubbed, the cache itself is the real module
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/packages/auth/lua/?.lua;"
  .. REPO .. "/packages/auth/lua/?/init.lua;"
  .. package.path

local reads, writes = {}, {}
local store = {
  [".zhihu.com"] = { z_c0 = "abc" },
  ["www.zhihu.com"] = { d_c0 = "def" },
  ["zhuanlan.zhihu.com"] = { q_c1 = "ghi" },
  ["api.zhihu.com"] = { l_c0 = "jkl" },
}

package.preload["auth.chained"] = function()
  return {
    Auth = function()
      return {
        get_cookies = function(_, host)
          reads[#reads + 1] = host
          return store[host] or {}
        end,
        set_cookies = function(_, host, cookies)
          writes[#writes + 1] = { host = host, cookies = cookies }
          return true
        end,
      }
    end,
  }
end

local Auth = require("auth.cache").Auth

return {
  name = "auth cache persistence gate",
  run = function(t)
    -- 1. browser cookies stay off disk unless the user opts in
    local cached = Auth()
    t.eq("persist defaults to false", cached.persist, false)

    local cookies = cached:get_cookies(".zhihu.com")
    t.eq("get_cookies returns the delegate cookies", cookies.z_c0, "abc")
    t.eq("reading with persist=false does not write to disk", #writes, 0)

    cached:get_cookies(".zhihu.com")
    t.eq("get_cookies memoizes the delegate result", #reads, 1)

    -- 2. the same read path writes once persistence is opted into
    --    (each host here is distinct because cookies_map lives on the class table)
    local persisting = Auth({ persist = true })
    t.eq("persist=true is stored per instance", persisting.persist, true)
    local fresh_cookies = persisting:get_cookies("www.zhihu.com")
    t.eq("persist=true still returns the cookies", fresh_cookies.d_c0, "def")
    t.eq("persist=true writes the cookies to disk", #writes, 1)
    t.eq("the write targets the same host", writes[1] and writes[1].host, "www.zhihu.com")
    t.eq("the write carries the cookie values", writes[1] and writes[1].cookies.d_c0, "def")

    -- 3. opting in at runtime (what zhihu.setup does) works too
    local late = Auth()
    late.persist = true
    late:get_cookies("zhuanlan.zhihu.com")
    t.eq("persist can be enabled on a live instance", #writes, 2)

    -- 4. reading stays a pure read while persistence is off
    Auth():get_cookies("api.zhihu.com")
    t.eq("persist=false instance adds no write", #writes, 2)

    -- 5. set_cookies always delegates, persistence only controls the read path
    local direct = Auth()
    t.eq("set_cookies delegates to the wrapped auth", direct:set_cookies("api.zhihu.com", { a = "b" }), true)
    t.eq("set_cookies delegates exactly once", #writes, 3)
  end,
}
