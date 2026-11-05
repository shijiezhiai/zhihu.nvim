---dependency-free test runner: luajit tests/run.lua [file-pattern]
---discovers tests/test_*.lua, each returns { name = string, needs = "nvim"?, run = function(t) }
local function script_path()
  return (debug.getinfo(1, "S").source:gsub("^@", ""))
end

local THIS = script_path()
local TESTS = THIS:match("^(.*)/[^/]+$") or "tests"
local REPO = TESTS:match("^(.*)/[^/]+$") or "."

package.path = table.concat({
  REPO .. "/lua/?.lua",
  REPO .. "/lua/?/init.lua",
  REPO .. "/packages/auth/lua/?.lua",
  REPO .. "/packages/auth/lua/?/init.lua",
  package.path,
}, ";")

--every test file loads its own stubs (a fake `vim`, package.preload entries,
--modules of the plugin); drop whatever a file added so the next one starts clean
local function snapshot()
  local globals, loaded, preload = {}, {}, {}
  for k in pairs(_G) do globals[k] = true end
  for k in pairs(package.loaded) do loaded[k] = true end
  for k in pairs(package.preload) do preload[k] = true end
  return globals, loaded, preload
end

local base_globals, base_loaded, base_preload = snapshot()

local function reset_env()
  for k in pairs(_G) do
    if not base_globals[k] then _G[k] = nil end
  end
  for k in pairs(package.loaded) do
    if not base_loaded[k] then package.loaded[k] = nil end
  end
  for k in pairs(package.preload) do
    if not base_preload[k] then package.preload[k] = nil end
  end
end

local total = { pass = 0, fail = 0, skip = 0 }
local failures = {}

local function quote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function vstr(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  return tostring(v)
end

local function ctx(file)
  local t = {}
  function t.ok(desc, cond, detail)
    if cond then
      total.pass = total.pass + 1
      print("PASS  " .. desc)
      return true
    end
    total.fail = total.fail + 1
    local line = "FAIL  " .. desc .. (detail and ("  -- " .. tostring(detail)) or "")
    print(line)
    failures[#failures + 1] = file .. ": " .. line
    return false
  end
  function t.eq(desc, actual, expected)
    return t.ok(desc, actual == expected, ("expected %s, got %s"):format(vstr(expected), vstr(actual)))
  end
  function t.skip(reason)
    total.skip = total.skip + 1
    print("SKIP  " .. reason)
  end
  return t
end

local function run_module(path, mod)
  local ok, err = pcall(mod.run, ctx(path))
  if not ok then
    total.fail = total.fail + 1
    local line = "FAIL  " .. tostring(mod.name or path) .. " raised: " .. tostring(err)
    print(line)
    failures[#failures + 1] = path .. ": " .. line
  end
end

local function have(cmd)
  local p = io.popen("command -v " .. cmd .. " 2>/dev/null")
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local function run_nvim(path)
  if not have("nvim") then
    ctx(path).skip("nvim not found in PATH, cannot run " .. path)
    return
  end
  local p = io.popen("nvim --headless -u NONE -l " .. quote(path) .. " 2>&1")
  local out = p:read("*a") or ""
  local _, how, code = p:close()
  local seen, child_fail = 0, 0
  for line in out:gmatch("[^\n]+") do
    if line:match("^PASS") then
      seen = seen + 1
      total.pass = total.pass + 1
      print(line)
    elseif line:match("^FAIL") then
      seen = seen + 1
      child_fail = child_fail + 1
      total.fail = total.fail + 1
      print(line)
      failures[#failures + 1] = path .. ": " .. line
    elseif line:match("^SKIP") then
      seen = seen + 1
      total.skip = total.skip + 1
      print(line)
    end
  end
  if seen == 0 then
    total.fail = total.fail + 1
    failures[#failures + 1] = path .. ": nvim child produced no results"
    print("FAIL  nvim child produced no PASS/FAIL/SKIP output (exit: " .. tostring(code) .. ", how: " .. tostring(how) .. ")")
    local shown = 0
    for line in out:gmatch("[^\n]+") do
      if shown >= 20 then
        print("      ... output truncated")
        break
      end
      print("      " .. line)
      shown = shown + 1
    end
  end
end

--a test file marked with a "needs: nvim" header runs in its own nvim process:
--loading it here would abort this runner, and it needs a real vim.uv anyway
local function needs_nvim(path)
  local f = io.open(path)
  if not f then
    return false
  end
  for _ = 1, 5 do
    local line = f:read("*l")
    if not line then
      break
    end
    if line:match("^%-%-%s*needs:%s*nvim") then
      f:close()
      return true
    end
  end
  f:close()
  return false
end

local files = {}
local pattern = arg and arg[1]
do
  local p = io.popen("ls -1 " .. quote(TESTS) .. "/test_*.lua 2>/dev/null")
  for line in p:lines() do
    if not pattern or line:find(pattern, 1, true) then
      files[#files + 1] = line
    end
  end
  p:close()
end
table.sort(files)

if #files == 0 then
  print("FAIL  no test files found under " .. TESTS)
  os.exit(1)
end

for _, path in ipairs(files) do
  reset_env()
  print("\n== " .. path)
  if needs_nvim(path) then
    run_nvim(path)
  else
    local chunk, lerr = loadfile(path)
    if not chunk then
      total.fail = total.fail + 1
      failures[#failures + 1] = path .. ": " .. tostring(lerr)
      print("FAIL  cannot load file: " .. tostring(lerr))
    else
      local ok, mod = pcall(chunk)
      if not ok then
        total.fail = total.fail + 1
        failures[#failures + 1] = path .. ": " .. tostring(mod)
        print("FAIL  file raised while loading: " .. tostring(mod))
      elseif type(mod) ~= "table" or type(mod.run) ~= "function" then
        total.fail = total.fail + 1
        failures[#failures + 1] = path .. ": does not return { name, run }"
        print("FAIL  file must return a table { name = string, run = function(t) }")
      else
        run_module(path, mod)
      end
    end
  end
end

print(("\n-- %d passed, %d failed, %d skipped"):format(total.pass, total.fail, total.skip))
if total.fail > 0 then
  print("-- failures:")
  for _, line in ipairs(failures) do
    print("   " .. line)
  end
  os.exit(1)
end
