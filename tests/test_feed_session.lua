---paging a feed one page at a time: no network, no nvim
local function repo_root()
  local src = (debug.getinfo(1, "S").source:gsub("^@", ""))
  return src:match("^(.*)/tests/[^/]+$") or "."
end

local REPO = repo_root()
package.path = REPO .. "/lua/?.lua;" .. REPO .. "/lua/?/init.lua;" .. package.path

_G.vim = _G.vim or {
  deepcopy = function(source)
    local copy = {}
    for key, value in pairs(source) do
      copy[key] = value
    end
    return copy
  end,
}

local responses = {}
local requested = {}
package.preload["requests"] = function()
  return {
    get = function(api)
      requested[#requested + 1] = api.url
      return responses[api.url] or { status_code = 404, text = "" }
    end,
  }
end

package.preload["zhihu.api"] = function()
  return { set_cookie_header = function(api) return api end }
end

local feed = require("zhihu.api.get.feed")
feed.decode = function(text)
  local body = responses[text] and responses[text].decoded
  return body or {}
end

local function answer(id)
  return { target = { type = "answer", id = id, title = "标题" .. id, question = { id = 1 } } }
end

return {
  name = "feed paging",
  run = function(t)
    local first, second = "https://zhihu.test/a", "https://zhihu.test/b"
    responses[first] = {
      status_code = 200,
      text = first,
      decoded = { data = { answer(11), answer(12) }, paging = { next = second } },
    }
    responses[second] = {
      status_code = 200,
      text = second,
      decoded = { data = { answer(13) }, paging = {} },
    }
    feed.url.recommend = first

    local session = feed.session "recommend"
    t.eq("a session starts empty", #session.items, 0)
    t.eq("a pull stops once the count is reached", #session:more(1), 2)
    t.eq("the page after it is still pending", #session.items, 2)
    t.eq("a pull continues where the last one stopped", #session:more(5), 1)
    t.eq("everything is on the list", #session.items, 3)
    t.ok("the feed is done once the link runs out", session.done == true)

    -- a broken page after the first one must not throw away what is on screen
    feed.url.recommend = first
    responses[second] = { status_code = 403, text = second }
    local broken = feed.session "recommend"
    broken:more(2)
    local added, err = broken:more(2)
    t.eq("a failed page adds nothing", #added, 0)
    t.ok("a failed page says the cookie expired", tostring(err):find("cookie", 1, true) ~= nil)
    t.ok("a failed page ends the session", broken.done == true)
    t.eq("the rows pulled before the failure survive", #broken.items, 2)

    -- the very first page failing is still an error the caller has to see
    feed.url.recommend = "https://zhihu.test/gone"
    local dead = feed.session "recommend"
    local ok = pcall(dead.more, dead, 2)
    t.ok("a feed that never loads raises", not ok)

    local unknown = pcall(feed.session, "nope")
    t.ok("an unknown feed is refused", not unknown)

    -- the recommend feed keeps handing out links while repeating entries: a walk
    -- that only stops on a missing link would never stop
    for page = 1, 20 do
      local url = ("https://zhihu.test/repeat/%d"):format(page)
      responses[url] = {
        status_code = 200,
        text = url,
        decoded = { data = { answer(99) }, paging = { next = ("https://zhihu.test/repeat/%d"):format(page + 1) } },
      }
    end
    feed.url.recommend = "https://zhihu.test/repeat/1"
    local repeated = feed.session "recommend"
    local calls = #requested
    local grew = repeated:more(20)
    t.eq("a page of repeats adds its one row", #grew, 1)
    t.ok("one call never fetches past its page budget", #requested - calls <= 3, #requested - calls)
    repeated:more(20)
    t.ok("repeats end the session after a few pages", repeated.done == true)
    t.ok("the whole walk stays under five pages", #requested - calls <= 5, #requested - calls)

    -- a hard ceiling on how much one session can hold
    feed.max_items = 2
    local capped = feed.session "recommend"
    capped.url = "https://zhihu.test/many/1"
    for page = 1, 10 do
      local url = ("https://zhihu.test/many/%d"):format(page)
      responses[url] = {
        status_code = 200,
        text = url,
        decoded = { data = { answer(200 + page) }, paging = { next = ("https://zhihu.test/many/%d"):format(page + 1) } },
      }
    end
    capped:more(50)
    t.eq("a session stops at the row ceiling", #capped.items, 2)
    t.ok("the ceiling ends the session", capped.done == true)
    feed.max_items = 200

    -- a page downloaded elsewhere folds in without any network work: this is the
    -- half the background fetcher drives
    local local_session = feed.session "hot"
    local local_calls = #requested
    local_session.url = "https://zhihu.test/background/1"
    local first_page = local_session:take { data = { answer(31) }, paging = { next = "https://zhihu.test/background/2" } }
    t.eq("take adds the page rows", #first_page, 1)
    t.eq("take moves the cursor url", local_session.url, "https://zhihu.test/background/2")
    t.eq("take never touches the network", #requested, local_calls)
    local_same = local_session:take { data = { answer(31) }, paging = { next = "https://zhihu.test/background/3" } }
    t.eq("a repeated page adds nothing", #local_same, 0)
    t.eq("but it still advances the url", local_session.url, "https://zhihu.test/background/3")
    local_session:take { data = { answer(31) }, paging = { next = "https://zhihu.test/background/4" } }
    local_session:take { data = { answer(31) }, paging = { next = "https://zhihu.test/background/5" } }
    t.ok("three empty pages end the session", local_session.done == true)

    -- fetch keeps its one-shot contract on top of the paging session
    feed.url.recommend = first
    responses[second] = {
      status_code = 200,
      text = second,
      decoded = { data = { answer(13), answer(12) }, paging = {} },
    }
    local items = feed.fetch "recommend"
    t.eq("fetch returns one page worth", #items, 3)
    t.ok("fetch keeps the order of the feed", items[3].uri:find("answer/13", 1, true) ~= nil)
  end,
}
