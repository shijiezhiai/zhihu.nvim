<!-- markdownlint-disable MD041 -->
<!-- markdownlint-disable MD033 -->
<p align="center">
  <img width="150" alt="favicon" src="https://github.com/user-attachments/assets/c99c26d9-f07d-4f3e-bdc4-dae632ab8f45"/>
</p>
<!-- markdownlint-enable MD033 -->

# :alien: Zhihu On NeoVim

基于 NeoVim 的知乎客户端提供包括~阅读~，~搜索~，创作，发布等一站式服务，内容加载速度比 Web 端更快，创新的 Markdown-Latex 混合语法让内容创作者更方便地插入代码块，数学公式，并一键发布至知乎平台。

## :zap: Features

- [x] 登录
- [x] 创作
  - [x] 内容创作
  - [x] 内容发布
  - [x] 一键上传图片
  - [ ] 定时发布
- [ ] 浏览

## :key: 登录

按以下顺序搜索登录需要的 cookies :

- 火狐浏览器： `~/.mozilla/firefox/*.default/cookies.sqlite`
- 谷歌浏览器： `~/.config/google-chrome/Default/Cookies`
- 调试： `~/.local/state/nvim/cookies.json`

从浏览器读到的 cookies 默认**不会**落盘：上面的 `cookies.json`
（macOS 为 `~/Library/Application Support/nvim/cookies.json`）只在显式开启持久化后才会生成，
写入时文件权限为 `0600`、父目录为 `0700`：

```lua
require 'zhihu'.setup {
    auth = { persist = true }
}
```

覆盖根据优先级找到的 cookies 是可行的。对于在不同浏览器登录不同的知乎账户的用户，
可以强行指定用谷歌浏览器 cookies 覆盖自动搜索到的 cookies:

```lua
require 'zhihu.api'.auth = require 'auth.chrome'.Auth()
```

更多用法请参考 [auth](packages/auth) 文档。

编辑保护：检测到当前打开的知乎文章、回答的作者不是你时会将缓冲区设为只读模式：

```lua
require 'zhihu'.setup {
    article = {
        authorName = "your zhihu account name"
    }
}
```

TODO: 自动获取用户名。

## :crayon: 内容创作

将你要编辑的知乎回答的 URL 开头的 `http://` 或 `https://` 替换为 `zhihu://`
并添加合适的文件后缀即可：

在 Shell 中：

```bash
vi zhihu://www.zhihu.com/question/question_id/answer/answer_id.md
```

在 Vim 中：

```vim
:edit zhihu://www.zhihu.com/question/question_id/answer/answer_id.md
```

![edit](https://github.com/user-attachments/assets/18640c04-5e02-4f09-9065-3f8dc644afab)

专栏文章同理：

```vim
:edit https://zhuanlan.zhihu.com/p/article_id.md
```

创建新的回答或专栏文章只需把对应的 id 替换为 new :

```vim
:edit https://zhuanlan.zhihu.com/p/new.md
```

编辑不存在的链接时会遇到 404:

```vim
:edit zhihu://0.md
```

```markdown
# 404

你似乎来到了没有知识存在的荒原

[去往首页](https://www.zhihu.com)
```

可以使用 markdown 以外的格式。内置对 typst 和 HTML 的支持。

```vim
:edit zhihu://www.zhihu.com/question/question_id/answer/answer_id.typ
:edit zhihu://www.zhihu.com/question/question_id/answer/answer_id.html
```

对于其他格式，需要安装 pandoc 进行转译：

```vim
:edit zhihu://www.zhihu.com/question/question_id/answer/answer_id.rst
```

可自定义转译方式。比如使用外部的 typst 将 typst 文件转译为 HTML:

```lua
require 'zhihu'.setup {
  article = {
    writer = function(...)
      if vim.o.filetype == 'typst' then
        return require'zfh.translator.cmd'.writer.typst(...)
      end
      return ...
    end
  }
}
```

事实上知乎只接受一种特殊的 HTML ，所有文件格式都需要转换为这种 HTML 才会被接受。
通过测试可以得到一些非官方的[语法规范](packages/zfh)。如果要在 markdown 插入
HTML 也必须遵循该规范。

### 数学公式

该规范仅允许 TeX 格式的数学公式，甚至不支持 HTML 的 MathML 。
对于 typst 也必须使用使用 LaTeX 数学公式：

```typst
#import "@preview/mitex:0.2.7": mi as _mi, mitex as _mitex
#let mitex(it) = context if target() == "html" {
  html.elem("p", attrs: (style: "display: flex; justify-content: center;"))[
    #html.elem("img", attrs: (
      src: "//www.zhihu.com/equation?tex=" + it.text,
      eeimg: "1",
      alt: it.text,
    ))
  ]
} else {
  _mitex(it)
}
#let mi(it) = context if target() == "html" {
  html.elem("img", attrs: (src: "//www.zhihu.com/equation?tex=" + it.text, eeimg: "1", alt: it.text))
} else {
  _mi(it)
}
#mi(`det(A * I) \geqslant det(A) = det(AI)`)
```

### 图片

typst 图片插入要求图片必须在本地。然而知乎要求所有图片必须上传到知乎图床，所以
必须使用如下语法：

```typst
#html.img(alt: "", src: "https://pica.zhimg.com/50/v2-5e6ef69d07eba3e2e69e6b8bddd74e6b_720w.jpg?source=2c26e567")
```

### 代码块

该规范导致必须 typst 要在使用代码块前额外编写如下代码：

``````typst
#show raw.where(block: true): it => context if target() == "html" {
  html.elem("pre", attrs: (lang: it.lang))[#it.text]
} else { it }

```json
{
  "version": "2.0.0",
  "request": {
      "Configuration": { }
    }
}
```
``````

综上所述，所以现在反而是 markdown 在转译生成知乎 HTML 上更加方便。

此外， typst 的语言服务器 tinymist 在检测到 `zhihu://` 开头的文件时会停止工作。
这是上游的 [bug](https://github.com/Myriad-Dreamin/tinymist/issues/2417) 。
因为 markdown 的[语言服务器](https://github.com/jolars/panache)是可以工作的。

中文编辑推荐插件：

中文输入法：

- [rime.nvim](https://github.com/rimeinn/rime.nvim)
- [fcitx5-ui.nvim](https://github.com/black-desk/fcitx5-ui.nvim)
- [ZFVimIM](https://github.com/ZSaberLv0/ZFVimIM)
- [ime.nvim](https://github.com/rimeinn/ime.nvim)
- [fcitx.vim](https://github.com/lilydjwg/fcitx.vim)
- [vim-xkbswitch](https://github.com/lyokha/vim-xkbswitch)

中文分词:

- [jieba.nvim](https://github.com/neo451/jieba.nvim)
- [jieba.vim](https://github.com/kkew3/jieba.vim)

中文标点符号:

- [vim-smartinput-extra](https://github.com/Vim-cn/vim-smartinput-extra)

## :books: 浏览答案与专栏

问题的答案列表和专栏的文章列表也可以直接 `:edit`，只要把知乎网页 URL 开头的 `https://` 换成 `zhihu://`：

```bash
# 问题的前 20 个答案
:edit zhihu://www.zhihu.com/question/question_id/answers.md

# 从第 41 个答案开始
:edit zhihu://www.zhihu.com/question/question_id/answers-40.md

# 专栏的文章列表
:edit zhihu://www.zhihu.com/column/column_slug.md
:edit zhihu://www.zhihu.com/column/column_slug-20.md
```

列表缓冲区是只读的：写入只会给出一条警告，不会发出任何请求。每一条答案或文章下面都带一个 `zhihu://` 链接，
光标停在那一行按 `<CR>` 就能打开它；列表末尾的 `[上一页]` 和 `[下一页]` 同样可以 `:edit` 来翻页。

## :newspaper: 首页 feed

推荐、关注、热榜三条 feed 都能用双窗刷：左边是标题列表，右边是当前那一条。
在列表里 j/k 只是挑，不改右边、也不发请求；按 `<CR>` 选中了一条，才去拉它的正文。
拉过的正文留在这轮会话里，回头再看同一条不再发请求。

```lua
vim.keymap.set("n", "<leader>zf", function() require("zhihu.nvim.browse").open("recommend") end)
vim.keymap.set("n", "<leader>zg", function() require("zhihu.nvim.browse").open("follow") end)
vim.keymap.set("n", "<leader>zh", function() require("zhihu.nvim.browse").open("hot") end)
```

列表窗口：`q` 关掉、`<CR>` 选中这一条并拉正文（焦点同时进右窗）、`e` 用完整缓冲区打开这一条、`o` 交给浏览器、
`z` 折叠/展开只给浏览器的条目、`r` 重新拉这一路。
右边窗口：`q` 回到列表（`<C-w>w` 也行）、`<CR>` 打开光标下的知乎链接（图片行则是图片地址）。光标走到最后三行时会顺着
`paging.next` 自动续页，一次一页（6 条），最多攒到 200 条；窗口高得装不下首屏时也会自己接着补，
一直补到填满窗口为止。

读到正文之后可以带走。右边窗口按 `gy` 把这一条做成引用块 yank 出来：首行 `> 标题 · 作者 · 赞数`，
正文每行前面加 `> `（空行就是一个 `>`），末行 `> —— <链接>`，粘到聊天框里也认得出来源。
按 `gs` 存成 markdown：提示一个路径（默认 `~/zhihu/<标题>.md`，标题里的 `/` `:` 这类字符换成空格、
超过 60 列截断），文件里是 `# 标题`、一行元信息、接口带的摘要、正文，最后一行写来源链接。
正文还没拉下来时这两个键只提示先按 `<CR>`，不会把「拉取正文…」这段占位文字带走。

图片画不出来（Neovide 和终端都不画图片），所以正文里的每张图占一行：`[图片 1] https://picx.zhimg.com/....jpg`，
序号按出现顺序排。光标停在这一行按 `<CR>`，地址交给系统去打开——在 Neovide 里就是系统浏览器。
用 `e` 打开的完整缓冲区里没有这个键，改用 `gx`（Neovim 自带的打开光标下链接）。懒加载的图片取
`data-actualsrc` 里的真实地址；只有 `data:` 内联占位、没有真实地址的图片直接省掉；公式图片照旧由公式那一步吃掉。

读过的条目在列表里暗一档（标题那一段用注释色），重新打开一路 feed 时没读过的一眼就能挑出来。
光标位置按 feed 分开记：推荐、关注、热榜各记自己那一条，下次打开直接落在这路上次停的那一条上——
只挪光标，不替你发请求；那条已经不在首屏了，就停在第一行。`e` 打开的完整正文缓冲区按文档记行号，
下次再打开回到上次读到的那一行。进度写在 `stdpath("state")/zhihu-resume.json`，
`:Zhihu forget` 一次清掉。写盘是攒着写的（停手两秒、离开时各写一次），j/k 不会每挪一行写一个文件。

回头看看这几天读了什么：`:Zhihu log` 打开一页 `zhihu-journal` 缓冲区（`:Zhihu log 30` 换成三十天的窗口），
按天分组（今天 / 昨天 / 日期），一行一条 `- [标题](zhihu://…) · 标签 · 作者 · 赞数`。标题和元信息是拉正文那一刻
顺手记下来的，这一页自己不发请求；光标停在条目行按 `<CR>` 回到那篇文章。页面只读，
再 `:Zhihu log` 一次会就地刷新同一格缓冲区，不会越开越多。

每条占两行：第一行是标签和标题，第二行是知乎给的摘要（`target.excerpt`，去掉 HTML 标签）加上作者 / 赞数 /
回答数 / 热度这类元信息。摘要本身就是接口里带的，显示它不多发一个请求。窗口窄到列表不足 16 列时第二行不画，
免得挤成碎片；摘要是「[视频]」这种标记、或者作者只写了「用户」时，那一段直接省掉。

有些条目没有正文可读，只能交给浏览器：热榜的 19 位新式问题 id、想法（pin）、以及接口没给
`zhihu://` 地址的条目。这些「死行」默认从列表里折掉，winbar 上写明折了几条（`关注 · 22 条, z 展开 7 条仅浏览器`），
按 `z` 展开就能看到它们——展开后标题是暗色的，`<CR>` 直接开浏览器而不是开右边那格，省掉一次没用的跳转。
热榜例外：它三十条里可能只有一两条能读，折起来等于把整屏折没，所以热榜默认展开。

关注流里那种「一条问题」的条目，右边显示的是这个问题的答案列表（每页 20 条，带分页链接），
列表里的每行都附着自己的 `zhihu://` 地址，在右边窗口按 `<CR>` 就能直接跳进去读那一篇；
想分页翻就在列表窗口按 `e` 开成完整缓冲区，那里的 `<CR>` 也认这些链接。

列表和正文都在后台拉：请求交给 `curl` 子进程，编辑器不会在等知乎回复时卡住。打开一条 feed 时
窗口立刻出现，列表里先写「正在拉「推荐」…」，页面到了换成标题。右边在选中之前显示的是 feed 自带的
标题、摘要和元信息（一次请求都不用发），选中之后先写「拉取正文…」，正文到了再换掉。
拉失败和这一路本来就空是两件事，分别写成「拉取失败」和「这一页是空的」，都提示按 `r` 重试、`q` 关掉——
登录态失效不会再被误报成「feed 是空的」。机器上没有 `curl` 时退回同步请求，那时的请求会阻塞界面一两秒。

想一次性挑一条的话，同一套 feed 还有 picker 版本（装了 [fzf-lua](https://github.com/ibhagwan/fzf-lua)
就用它，否则退回 `vim.ui.select`）：

```lua
vim.keymap.set("n", "<leader>z/", function() require("zhihu.nvim.feed").pick("recommend") end)
```

回答和文章直接开成缓冲区；问题打开它的答案列表；想法交给浏览器。热榜条目是 19 位的新式问题 id，
`api/v4` 不认识这个命名空间（问题返回 10003、答案列表返回 4041）而网页能开，所以热榜条目同样交给浏览器。
老式问题 id 的答案列表仍然走 `api/v4/questions/<id>/answers`：带上 `Cookie` 才有数据，
裸请求只会拿回「暂时限制本次访问」，所以这里的请求和别处一样要带登录态。

正文不算从页面上刮的：回答走 `api/v4/answers/<id>?include=content`，文章走
`zhuanlan.zhihu.com/api/articles/<id>`，两者都带登录态、都返回现成的 HTML。原因很直接——
19 位新式 id 的回答页面会回一张反爬验证页（带着 `zh-zse-ck` 的那张），把页面当正文就会在
预览里看到整页 HTML 源码。接口偶尔对密集请求回一次 10003，插件会重试一遍；真的拿不到正文时，
右边窗口写明是验证墙、空响应还是登录态失效，按 `q` 回到列表再按 `o` 到浏览器看。

知乎把每一处公式都写成图片：`<img src="https://www.zhihu.com/equation?tex=%5Cpi" alt="\pi" eeimg="1">`，
懒加载的那些则把真正的地址藏在 `data-actualsrc` 里、`src` 只是一张空白 svg。渲染前会把这类
图片还原成 `$\pi$`：优先取 `actualsrc`/`src` 的 `tex` 参数并做 URL 解码（`+` 是空格、
`%5C` 是反斜杠），取不到就退回 `alt`，两者都没有才原样留下。普通配图不受影响。
（公式只在 `search_v3` 之类的接口返回的正文里才稳定可见，feed 抽样几百条一次都没命中，
所以这条路径是靠搜索接口挖到的样本验证的。）

## :mag: 搜索

```vim
" 搜完之后和 feed 一样是左边列表、右边预览
:Zhihu search 欧拉公式
```

`:Zhihu search` 后面跟多少词都行，用空格拼成一个查询；不带关键词时会弹一个输入框。
结果落在同一套双窗里，键位也一致：`j`/`k` 换条目、`<CR>` 拉正文、`e` 用完整缓冲区打开、
`o` 到浏览器、`z` 折叠只能进浏览器的条目、`r` 重试、`q` 关掉。

搜索也带一个默认键位：`<leader>zs` 直接弹输入框，不占命令行。它挂在一个 `<Plug>` 上，
想换键就映射自己的，想关掉就自己把 `<leader>zs` 用掉（插件不会抢你已经占用的键）：

```lua
vim.keymap.set("n", "<leader>zq", "<Plug>(zhihu-search)", { desc = "知乎：搜索" })
```

接口是 `api/v4/search_v3?t=general&q=…&correction=1`，带登录态就能用，不需要 `x-zse-96` 签名；
翻页跟着返回里的 `paging.next` 走（它会指到 `api.zhihu.com`，同一份 cookie 照样管用）。
标题和摘要里的 `<em>` 是命中高亮，列表会去掉标记但把词留在一起（`上帝<em>公式</em>` → `上帝公式`）。
论文类结果（k-vip 的 `scholar`）只有浏览器能看，和热榜一样算「仅浏览器」条目。

## :envelope_with_arrow: 内容发布

在编辑器预览的插件：

- [math-conceal.nvim](https://github.com/pxwg/math-conceal.nvim)
- [markview.nvim](https://github.com/OXY2DEV/markview.nvim)
- [latex_concealer.nvim](http://github.com/dirichy/latex_concealer.nvim)
- [tex-conceal.vim](https://github.com/KeitaNakamura/tex-conceal.vim)

在网页浏览器预览的插件：

- [coc-markdown-preview-enhanced](https://github.com/weirongxu/coc-markdown-preview-enhanced)
- [markdown-preview.nvim](https://github.com/iamcco/markdown-preview.nvim)

但注意并不是以上插件支持预览的所有 markdown 语法都被知乎支持。比如 Mermaid 。

预览完就可以发布了。发布就像保存一个普通文件一样轻松：

```vim
:write
```

对**已经发布**的内容再 `:write` 会直接覆盖线上正文，所以默认会先弹窗确认：
选择「No」则中止写入且不报错，缓冲区保持未保存状态；无交互环境（如 `nvim --headless`）
会直接拒绝并提示，不会静默发布。
新文章第一次 `:write` 是发布、不是覆盖，因此不弹窗、直接发布。确认也可以关掉：

```lua
require 'zhihu'.setup {
    article = { confirm_publish = false }
}
```

你可以定义快捷键浏览发布后的回答或专栏文章。
如果还未发布，该快捷键会打开对应的问题或首页。

```vim
:nnoremap <localleader>lv :lua require'zhihu.nvim'.open()<CR>
```

定义[菜单栏选项](https://github.com/skywind3000/vim-quickui)也是可以的。

![menu](https://github.com/user-attachments/assets/ff79e942-7221-4caf-bde6-d8d376d0a58b)

对于知乎专栏文章，你在发布前需要额外设置标题：

```vim
:let b:article.title = "Title"
:write
```

TODO： 如果文章标题为空则从第一个 `<h1>` 标签获取标题。

更多选项是可以设置的，例如：

开启送礼物：

```vim
:let b:article.can_reward = v:true
```

允许转载：

```vim
:let b:article.reshipment_settings = "allowed"
```

以上设置是临时的，需要永久设置的话请在配置文件中加入：

```lua
require 'zhihu'.setup {
  article = {
    can_reward = true,
    reshipment_settings = "allowed"
  }
}
```

具体设置参见 `lua/zhihu/_meta.lua` 。

## :bar_chart: 一键上传图片

```lua
:inoremap <C-Q> <C-O>:lua require 'zhihu.nvim'.input()<CR>
```

在对话框中插入本地图片路径开始上传。上传成功后默认会写入到剪贴板。

![image](https://github.com/user-attachments/assets/a6e7bc3e-5243-4d15-82c5-5e9ca676934d)

你可以定义一些上传选项，例如

<!-- markdownlint-disable MD013 -->
```lua
:inoremap <C-Q> <C-O>:lua require 'zhihu.nvim'.input {src_type = 'watermark_src', regnames = {'*', '+', '.', 'a'}}<CR>
```
<!-- markdownlint-enable MD013 -->

会将带有水印的图片路径写入到 2 个系统剪贴板、当前光标所在和 a 号寄存器。

- Unix 有两个系统剪贴板 `*` 和 `+` ，分别通过 `<C-C>`/`<C-V>` 以及鼠标选中/鼠标中键写入和写出。
  在不支持第 2 个剪贴板的操作系统上会被识别为同一个剪贴板。
- `.` 会插入当前光标位置。不建议这样做，因为上传是异步的，很可能你已经编辑到别的位置了。
- a 号寄存器的内容可以通过 `:echo @a` 查看。更多内容请参阅 `:help :registers`
- 无法写入只读寄存器 `%`, `#`, `:`

上传需要时间。如果超时请重试。也可以增大上传次数到 30 和上传间隔时间到 3 秒：

<!-- markdownlint-disable MD013 -->
```lua
:inoremap <C-Q> <C-O>:lua require 'zhihu.nvim'.input {max_retry = 30, sleep_seconds = 3}<CR>
```
<!-- markdownlint-enable MD013 -->

## 插件集成

### [nerdfont.vim](https://github.com/lambdalisue/nerdfont.vim)

```vim
let g:nerdfont#path#pattern#customs = {
      \ '^zhihu://': '',
      \ }
```

### [vim-airline](https://github.com/vim-airline/vim-airline)

```vim
let g:airline#extensions#tabline#formatter = 'zhihu'
```

### [nvim-notify](https://github.com/rcarriga/nvim-notify)

```lua
vim.notify = require "notify"
vim.notify.setup({
    background_colour = "#000000",
})
```

### [vim-browser-search](https://github.com/voldikss/vim-browser-search)

```vim
autocmd BufNewFile zhihu://* let b:browser_search_default_engine = 'zhihu'
```

## API

### Update zhihu article

```lua
local Article = require 'zhihu.article'.Article
local id = "your_article_id"
local article
if id then
  article = Article:from_id(id)
  -- or create an article
else
  article = Article { title = "title" }
end
local f = io.open "/the/path/of/your/article.html"
if f then
  local html = f:read "*a"
  f:close()
  article:set_content(html)
  article:write()
end
```

### Upload image to zhihu

```lua
local Uploader = require 'zhihu.image'.Uploader
local fetch = require 'zhihu.image'.fetch_image_sync
local uploader = Uploader.from_file '/the/path/of/image.png'
local id = tostring(uploader)
local image = fetch(id)
print(image)
-- https://picx.zhimg.com/v2-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
```

### Convert markdown and HTML

```lua
local md_to_html = require 'markdown_to_html'.md_to_html
local html_to_md = function(html)
    return require 'zhihu.article.generator.markdown'.generator:translate(html)
end
local markdown = "# Title"
assert(markdown == html_to_md(md_to_html(markdown)))
```

## Install

> 从本 fork（`shijiezhiai/zhihu.nvim`）安装，跟随本 fork 的 `main`；上游 `pxwg/zhihu.nvim`
> 不含本仓库的加固修复。要固定版本，先在本 fork 上打 tag，再把 rockspec 的 `source.url`
> 换成该 tag 的 tarball。

### rocks.nvim

#### Command style

```vim
:Rocks install zhihu.nvim
```

#### Declare style

`~/.config/nvim/rocks.toml`:

```toml
[plugins]
"zhihu.nvim" = "scm"
```

Then

```vim
:Rocks sync
```

or:

```sh
$ luarocks --lua-version 5.1 --local --tree ~/.local/share/nvim/rocks install zhihu.nvim
# ~/.local/share/nvim/rocks is the default rocks tree path
# you can change it according to your vim.g.rocks_nvim.rocks_path
```

### lazy.nvim

```lua
return {
  "shijiezhiai/zhihu.nvim",
  main = "zhihu",
}
```

## Tests

The regression tests run without luarocks, busted or any plugin dependency: they load the real modules from `lua/` and stub only the rocks that are not installed.

```sh
# article publish guard, cookie scoping, auth cache: plain luajit, no rocks needed
luajit tests/run.lua

# cookie file permissions (0700 dir / 0600 file) need the real vim.uv
nvim --headless -u NONE -l tests/test_auth_persist.lua
```

`tests/run.lua` discovers `tests/test_*.lua`, prints one PASS/FAIL/SKIP line per assertion and exits non-zero on any failure. Files whose first lines carry `-- needs: nvim` are run by the runner through `nvim --headless` automatically. `luajit tests/run.lua <substring>` runs a single file.

## Similar Projects

- [zhihu_obsidian](https://github.com/dongguaguaguagua/zhihu_obsidian)
- [VSCode-Zhihu](https://github.com/niudai/VSCode-Zhihu)
