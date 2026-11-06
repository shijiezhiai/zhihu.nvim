---the background fetcher must hand curl a self-contained command line: no
---shell, no cookie file, one argument per header
vim = {
  fn = { executable = function() return 1 end },
  schedule = function(fn) fn() end,
  system = function(args, _, cb)
    vim.system_args = args
    cb { code = 0, stdout = "ok" }
  end,
  uv = { hrtime = os.clock },
}
package.loaded.vim = vim

local M = {
  name = "http",
  run = function(t)
    package.loaded["zhihu.nvim.http"] = nil
    local http = require "zhihu.nvim.http"
    t.ok("curl is reported available", http.available() == true)

    local args = http.args("https://zhihu.test/feed?limit=10&include=data[*].x", {
      Cookie = "__zse_ck=abc; z_c0=def",
      ["User-Agent"] = "Mozilla/5.0 test",
    })
    t.eq("the request keeps the url untouched", args[#args], "https://zhihu.test/feed?limit=10&include=data[*].x")
    t.ok("globbing is off so brackets stay literal", table.concat(args, " "):find("-g", 1, true) ~= nil)
    t.ok("the cookie travels as one argument", table.concat(args, " "):find("Cookie: __zse_ck=abc; z_c0=def", 1, true) ~= nil)
    t.ok("the user agent travels too", table.concat(args, " "):find("User-Agent: Mozilla/5.0 test", 1, true) ~= nil)
    t.ok("no cookie file is written", table.concat(args, " "):find(".txt", 1, true) == nil)

    local bare = http.args("https://zhihu.test/x", {})
    t.eq("a header-less request still ends in the url", bare[#bare], "https://zhihu.test/x")
    t.ok("no empty cookie header is passed", table.concat(bare, " "):find("Cookie:", 1, true) == nil)

    local got
    http.get("https://zhihu.test/x", { Cookie = "a=b" }, function(err, text)
      got = { err = err, text = text }
    end)
    t.ok("a successful fetch hands back the body", got and got.text == "ok", got and tostring(got.text))

    -- without curl the caller falls back to the blocking path instead of hanging
    vim.fn.executable = function() return 0 end
    t.ok("missing curl is detected", http.available() == false)
    local failed
    http.get("https://zhihu.test/x", {}, function(err) failed = err end)
    t.ok("a missing curl is reported, not thrown", type(failed) == "string" and failed:find("curl", 1, true) ~= nil, failed)
  end,
}

return M
