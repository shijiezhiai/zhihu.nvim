-- needs: nvim
---the resume file is read and written with the real vim.json and vim.fn, so this
---one wants a real neovim: nvim --headless -u NONE -l tests/test_resume.lua
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()

if vim == nil then
  print("SKIP  the resume file needs vim.json, run: nvim --headless -u NONE -l tests/test_resume.lua")
  os.exit(0)
end

package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

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

local tmp = vim.fn.tempname() .. "-resume.json"

---a module with nothing in memory, so what it answers comes from the file
local function fresh()
  package.loaded["zhihu.nvim.resume"] = nil
  local module = require "zhihu.nvim.resume"
  module.path = tmp
  return module
end

local default_path = (function()
  package.loaded["zhihu.nvim.resume"] = nil
  return require("zhihu.nvim.resume").file()
end)()

local resume = fresh()
ok("the file sits under neovim's state directory", default_path:match "zhihu%-resume%.json$" ~= nil, default_path)
eq("the override is what gets written", resume.file(), tmp)

eq("a feed nothing was remembered of is nil", resume.feed "recommend", nil)
eq("an entry never opened is not read", resume.read "zhihu://a.md", false)
eq("a document never opened has no line", resume.line "zhihu://a.md", nil)

local answer = "zhihu://www.zhihu.com/question/1/answer/2.md"
resume.set_feed("recommend", answer)
resume.set_feed("hot", "zhihu://www.zhihu.com/question/3/answer/4.md")
resume.mark_read(answer)
resume.set_line(answer, 37)

eq("each feed keeps its own row", resume.feed "recommend", answer)
eq("and does not borrow another's", resume.feed "hot", "zhihu://www.zhihu.com/question/3/answer/4.md")
eq("an opened entry is read", resume.read(answer), true)
eq("the line is the one that was set", resume.line(answer), 37)

resume.set_line("zhihu://b.md", 12.7)
eq("a fractional line is rounded down", resume.line "zhihu://b.md", 12)
resume.set_line("zhihu://c.md", 0)
eq("a line below one is refused", resume.line "zhihu://c.md", nil)
resume.set_line(nil, 4)
eq("a nil uri is refused", resume.line "zhihu://d.md", nil)

ok("saving says it worked", resume.save())
ok("the file is on disk", vim.fn.filereadable(tmp) == 1)

local again = fresh()
eq("the row survives a restart", again.feed "recommend", answer)
eq("so does the line", again.line(answer), 37)
eq("and what was read", again.read(answer), true)

-- a file that cannot be parsed must not cost the reader the feed
vim.fn.writefile({ "{ this is not json" }, tmp)
local broken = fresh()
eq("a corrupt file reads as empty", broken.feed "recommend", nil)
eq("and still refuses to call anything read", broken.read "zhihu://a.md", false)
broken.set_feed("follow", "zhihu://e.md")
ok("a corrupt file is replaced on the next write", broken.save())
ok("with content that parses", (function()
  local parsed, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(tmp), "\n"))
  return parsed and type(decoded) == "table" and decoded.feeds.follow == "zhihu://e.md"
end)())

ok("forget writes", broken.forget())
eq("nothing is left to resume", broken.feed "follow", nil)
eq("and nothing is left marked read", broken.read "zhihu://a.md", false)

-- the buffer helpers
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(buf, answer)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three", "four", "five" })
broken.set_line(answer, 4)
vim.api.nvim_set_current_buf(buf)
broken.restore(buf)
eq("the cursor goes back to the remembered line", vim.api.nvim_win_get_cursor(0)[1], 4)

broken.set_line(answer, 99)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
broken.restore(buf)
eq("a line past the end is clamped to the document", vim.api.nvim_win_get_cursor(0)[1], 5)

vim.api.nvim_win_set_cursor(0, { 2, 0 })
broken.remember_here()
eq("leaving a document records the line", broken.line(answer), 2)

local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(other, REPO .. "/README.md")
vim.api.nvim_set_current_buf(other)
broken.remember_here()
eq("a buffer that is not zhihu is not recorded", broken.line(REPO .. "/README.md"), nil)

-- the journal window: when it was read, and what the row was called
local jr = fresh()
jr.mark_read("zhihu://old.md", { title = "旧条目", tag = "回答", meta = "@作者 · 3 赞" })
jr.mark_read("zhihu://stale.md")
jr.load().read["zhihu://stale.md"] = { at = os.time() - 30 * 86400, title = "三十天前" }

local recent = jr.recent(7)
eq("a week keeps only what was read inside it", #recent, 1)
eq("with the title the row carried", recent[1].title, "旧条目")
eq("and what it was", recent[1].tag, "回答")
eq("and who wrote it", recent[1].meta, "@作者 · 3 赞")
eq("a wider window reaches further back", jr.recent(60)[2].title, "三十天前")
eq("no argument means a week", #jr.recent(), 1)
eq("a window of zero days is not taken literally", #jr.recent(0), 1)

-- a file written before the time was kept holds a bare true
jr.load().read["zhihu://legacy.md"] = true
eq("an undated entry still counts as read", jr.read "zhihu://legacy.md", true)
eq("but it cannot be put in a window", #jr.recent(7), 1)
jr.mark_read("zhihu://legacy.md", { title = "旧的" })
eq("opening it again gives it a date", type(jr.load().read["zhihu://legacy.md"]), "table")
eq("and it joins the window", #jr.recent(7), 2)

vim.fn.delete(tmp)

print(("-- %d passed, %d failed"):format(results.pass, results.fail))
os.exit(results.fail > 0 and 1 or 0)
