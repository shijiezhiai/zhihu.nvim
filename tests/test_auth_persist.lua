-- needs: nvim
---regression tests for cookie file permissions and merge-on-write in packages/auth/lua/auth/json.lua
---these need a real vim.uv, so luajit tests/run.lua shells out to:
---  nvim --headless -u NONE -l tests/test_auth_persist.lua
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()

if vim == nil then
  print("SKIP  cookie file permissions need vim.uv, run: nvim --headless -u NONE -l tests/test_auth_persist.lua")
  os.exit(0)
end

local uv = vim.uv or vim.loop
local results = { pass = 0, fail = 0 }

local function vstr(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

local function ok(desc, cond, detail)
  if cond then
    results.pass = results.pass + 1
    print("PASS  " .. desc)
    return true
  end
  results.fail = results.fail + 1
  print("FAIL  " .. desc .. (detail and ("  -- " .. tostring(detail)) or ""))
  return false
end

local function eq(desc, actual, expected)
  return ok(desc, actual == expected, ("expected %s, got %s"):format(vstr(expected), vstr(actual)))
end

local function perms(path)
  local stat = uv.fs_stat(path)
  return stat and (stat.mode % 512) or nil
end

local function read_json(path)
  local f = assert(io.open(path, "r"))
  local text = f:read "*a"
  f:close()
  return vim.json.decode(text)
end

local stamp = ("%d-%d"):format(os.time(), math.random(1, 100000))
local machine_dir = "/tmp/zhihu-test-perms-" .. stamp
local hand_dir = "/tmp/zhihu-test-hand-" .. stamp
local loose_dir = "/tmp/zhihu-test-loose-" .. stamp
for _, dir in ipairs { machine_dir, hand_dir, loose_dir } do
  vim.fn.delete(dir, "rf")
end

package.path = REPO .. "/packages/auth/lua/?.lua;"
  .. REPO .. "/packages/auth/lua/?/init.lua;"
  .. package.path

--nvim -l runs before the vim.* lua modules are registered for require();
--the values themselves already exist, so hand them back through package.preload
package.preload["vim.json"] = function() return vim.json end
package.preload["vim.shared"] = function() return vim.shared end

--pin the cookie cache inside /tmp instead of the real user state dir
package.preload["platformdirs"] = function()
  return {
    PlatformDirs = function()
      return { user_state_dir = function() return machine_dir end }
    end,
  }
end
package.preload["auth.auth"] = function()
  return {
    Cookies = function(cookies)
      local out = {}
      for k, v in pairs(cookies or {}) do
        out[k] = v
      end
      return out
    end,
  }
end

local Auth = require("auth.json").Auth
local path = Auth().path

eq("the cookie cache lives in the redirected temp dir", path, machine_dir .. "/cookies.json")

-- 1. a machine written cache is owner only
local auth = Auth()
eq("set_cookies reports success", auth:set_cookies(".zhihu.com", { z_c0 = "first" }), true)
eq("the cache directory is created 0700", perms(machine_dir), 448)
eq("the cache file is written 0600", perms(path), 384)
eq("the cache holds the first host cookie", read_json(path)[".zhihu.com"] and read_json(path)[".zhihu.com"].z_c0, "first")

-- 2. a second host must be merged in, not truncate the file
auth:set_cookies("www.zhihu.com", { d_c0 = "second" })
local merged = read_json(path)
eq("writing a second host keeps the first", merged[".zhihu.com"] and merged[".zhihu.com"].z_c0, "first")
eq("writing a second host adds the second", merged["www.zhihu.com"] and merged["www.zhihu.com"].d_c0, "second")

-- 3. rewriting an existing host replaces only that host
auth:set_cookies(".zhihu.com", { z_c0 = "third" })
local updated = read_json(path)
eq("rewriting a host updates its value", updated[".zhihu.com"] and updated[".zhihu.com"].z_c0, "third")
eq("rewriting a host keeps the other host", updated["www.zhihu.com"] and updated["www.zhihu.com"].d_c0, "second")
eq("the cache directory stays 0700 after a merge", perms(machine_dir), 448)
eq("the cache file stays 0600 after a merge", perms(path), 384)

-- 4. the read path does not care about permissions or the persist gate
uv.fs_chmod(path, 420) -- 0644
eq("a world readable cache is still read", Auth():get_cookies(".zhihu.com").z_c0, "third")

-- 5. a cache dropped in by hand still logs in
vim.fn.mkdir(hand_dir, "p")
local hand_path = hand_dir .. "/cookies.json"
local f = assert(io.open(hand_path, "w"))
f:write(vim.json.encode({ [".zhihu.com"] = { z_c0 = "handmade" } }))
f:close()
uv.fs_chmod(hand_path, 420) -- 0644
eq("a hand written cache is read", Auth({ path = hand_path }):get_cookies(".zhihu.com").z_c0, "handmade")

-- 6. an existing world readable directory is tightened on the next write
vim.fn.mkdir(loose_dir, "p")
uv.fs_chmod(loose_dir, 493) -- 0755
eq("the loose directory starts at 0755", perms(loose_dir), 493)
Auth({ path = loose_dir .. "/cookies.json" }):set_cookies(".zhihu.com", { z_c0 = "x" })
eq("writing tightens an existing directory to 0700", perms(loose_dir), 448)

for _, dir in ipairs { machine_dir, hand_dir, loose_dir } do
  vim.fn.delete(dir, "rf")
end

print(("-- %d passed, %d failed"):format(results.pass, results.fail))
os.exit(results.fail > 0 and 1 or 0)
