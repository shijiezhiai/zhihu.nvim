#!/usr/bin/env bash
# Rebuild the parts of this fork that live outside git: the Lua rocks in .deps/
# and the two Rust modules in .crates/. Run it from anywhere; it cds to the repo
# root itself. Idempotent: every step skips work already done.
set -euo pipefail
cd "$(dirname "$0")/.."

SDK=$(xcrun --show-sdk-path)
LUA_DIR=/opt/homebrew/opt/luajit
OPENSSL_DIR=/opt/homebrew/opt/openssl@3
LR=(luarocks --lua-version=5.1 --lua-dir="$LUA_DIR" --tree="$PWD/.deps")

command -v luarocks >/dev/null || brew install luarocks
test -x "$LUA_DIR/bin/luajit" || brew install luajit
test -d "$OPENSSL_DIR" || brew install openssl@3

# pure/sealed rocks; one name per call because luarocks rejects a batch
for rock in lua-cjson htmlparser md5 sha1 base64 uuid mimetypes html-entities datafile platformdirs lsqlite3; do
  "${LR[@]}" install "$rock" --force-lock >/dev/null
done

# lua-requests' own rockspec demands luaossl, whose macOS rockspec looks for
# libstdc++; install it without deps and give it luasec instead
"${LR[@]}" install luasec OPENSSL_DIR="$OPENSSL_DIR" --force-lock >/dev/null
"${LR[@]}" install lua-requests --deps-mode=none --force-lock >/dev/null
# requests requires luaexpat's separate 'xml' rock at load time but only uses it
# for response.xml(); make that require lazy so the module loads without it
sed -i '' "/^local xml = require('xml')$/d" .deps/share/lua/5.1/requests.lua
sed -i '' "s|response.xml = function () return xml.load(response.text) end|response.xml = function () return require('xml').load(response.text) end|" .deps/share/lua/5.1/requests.lua

export CARGO_HOME="${CARGO_HOME:-/tmp/zhihu-cargo-home}"
export CARGO_TARGET_DIR="$PWD/.crates"
cargo build --release --features=luajit --manifest-path packages/auth/crates/chrome_cookie/Cargo.toml
cargo build --release --features=luajit --manifest-path packages/zfh/Cargo.toml

echo "deps ready: $(ls .crates/release/*.dylib | xargs -n1 basename | tr '\n' ' ')"
