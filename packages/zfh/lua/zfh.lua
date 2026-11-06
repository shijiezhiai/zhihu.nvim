---default reader/writer
---@module zfh
local Translator = require 'zfh.translator'.Translator
local html_to_pandoc = require 'zfh.translator.cmd'.readers.pandoc
local pandoc_to_html = require 'zfh.translator.cmd'.writers.pandoc
-- typst is only needed to publish a typst document; loading it here would make every
-- read path require the rock as well
local function compile_typst(text)
  return require('typst').compile { source = text, format = "html" }
end
local html_to_md = require "zfh.generator.markdown".generator
local html_to_typst = require "zfh.generator.typst".generator
local md_to_html = require "markdown_to_html".md_to_html
local M = {
  reader = Translator {
    translators = {
      html = function(...)
        return ...
      end,
      markdown = html_to_md,
      typst = html_to_typst,
      _ = html_to_pandoc,
    }
  },
  writer = Translator {
    translators = {
      html = function(...)
        return ...
      end,
      markdown = md_to_html,
      typst = compile_typst,
      _ = pandoc_to_html,
    }
  },
}
return M
