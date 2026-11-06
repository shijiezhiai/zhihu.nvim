-- List:fetch_async maps a background body (or transport error) to rows/err
package.preload["requests"] = function()
  return { get = function() error("the async path must not touch requests") end }
end
package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) api.cookie = true end }
end
package.preload["zhihu.api.get.list"] = function()
  return {
    API = {
      from_list = function(list)
        return { url = ("https://example/%s/%s"):format(list.kind, list.id), headers = {} }
      end,
    },
  }
end
local calls = {}
local body, transport_error = nil, nil
package.preload["zhihu.nvim.http"] = function()
  return {
    get = function(url, _, cb)
      calls[#calls + 1] = url
      cb(transport_error, body)
    end,
  }
end
package.preload["vim.json"] = function()
  return {
    decode = function(text)
      if text == "ERR" then
        return { error = { message = "暂时限制本次访问" } }
      end
      if text == "EMPTY" then
        return {}
      end
      return {
        data = {
          { id = 42, excerpt = "一段摘要", author = { name = "某人" }, voteup_count = 7, comment_count = 3,
            question = { id = 656823894, title = "问题标题" } },
        },
        paging = { totals = 21 },
      }
    end,
  }
end

local List = require("zhihu.list").List

return {
  name = "list background fetch",
  run = function(t)
    local list = List.from_url("zhihu://www.zhihu.com/question/656823894/answers.md")
    t.ok("an answers uri parses as a list", list ~= nil)

    body, transport_error = "OK", nil
    local rows, err
    list:fetch_async(function(r, e) rows, err = r, e end)
    t.eq("a good body yields no error", err, nil)
    t.eq("one row comes back", #rows, 1)
    t.eq("the row keeps its id", rows[1].id, "42")
    t.eq("the row keeps its author", rows[1].author, "某人")
    t.eq("the row keeps its votes", rows[1].votes, 7)
    t.eq("the row links the answer itself", rows[1].url,
      "zhihu://www.zhihu.com/question/656823894/answer/42.md")
    t.eq("totals ride along", rows.totals, 21)
    t.ok("the request goes to the answers endpoint",
      tostring(calls[#calls]):find("/answers/656823894", 1, true) ~= nil)

    body = "ERR"
    rows, err = nil, nil
    list:fetch_async(function(r, e) rows, err = r, e end)
    t.eq("an error body yields no rows", rows, nil)
    t.ok("an error body keeps the server message",
      tostring(err):find("暂时限制本次访问", 1, true) ~= nil)

    body = "EMPTY"
    rows, err = nil, nil
    list:fetch_async(function(r, e) rows, err = r, e end)
    t.ok("a body without data is an error",
      tostring(err):find("没有 data", 1, true) ~= nil)

    body, transport_error = nil, "curl: (6) Could not resolve host"
    rows, err = nil, nil
    list:fetch_async(function(r, e) rows, err = r, e end)
    t.ok("a transport error is passed through",
      tostring(err):find("Could not resolve", 1, true) ~= nil)
  end,
}