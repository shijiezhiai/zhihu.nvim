---placeholder for markdown <-> html coverage
---both directions of the conversion live in rocks that this suite must not install,
---so there is nothing to assert here without network access
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

return {
  name = "markdown roundtrip",
  run = function(t)
    t.skip("markdown <-> html roundtrip needs the 'markdown_to_html' and 'htmlparser' rocks "
      .. "(lua/zhihu/article.lua:7-8, packages/zfh/lua/zfh/generator/markdown.lua:3): neither is installed "
      .. "here and this suite must run without luarocks or network access")
  end,
}
