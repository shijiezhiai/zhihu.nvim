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
  -- this rockspec is the template lumen-oss rewrites on release, so it only affects
  -- a source install: that must be this fork, which carries the hardening patches
  url = 'git+https://github.com/shijiezhiai/zhihu.nvim.git',
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
