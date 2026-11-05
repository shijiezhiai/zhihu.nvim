rockspec_format = '3.0'
description = {
  summary = '',
  detailed = '',
  labels = {},
  homepage = 'https://github.com/pxwg/zhihu.nvim',
  license = 'MIT',
}
package = description.homepage:match('/([^/]+)/?$')
version = 'scm-1'
source = {
  -- pinned to the 0.1.5 tag (commit 9f2b3309eed542c1a458dce058e7a5a459db8331):
  -- installing must not silently follow upstream HEAD
  url = 'https://github.com/pxwg/zhihu.nvim/archive/refs/tags/0.1.5.tar.gz',
}

build = {
  type = 'builtin',
  copy_directories = { 'plugin' },
  install = {
    conf = {
      ["Untitled.md"] = "etc/conf/Untitled.md",
    },
  }
}
dependencies = { "lua >= 5.1", "lua-requests-temp", "lua-cjson", "htmlparser", "html-entities", "md5", "sha1", "base64", "uuid", "mimetypes", "auth", "zfh", "datafile" }
