use aes::Aes128;
use aes_gcm::{
  aead::{Aead, KeyInit},
  Aes128Gcm,
};
use base64::{engine::general_purpose, Engine as _};
use block_modes::block_padding::Pkcs7;
use block_modes::{BlockMode, Cbc};
use dirs;
use hmac::Hmac;
use mlua::{Error as LuaError, Lua, Result as LuaResult};
use pbkdf2::{pbkdf2, pbkdf2_hmac};
use rusqlite::Connection;
use serde_json::Value;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::{error::Error, fmt, process::Command};
pub mod encrypt;

const SALT: &[u8] = b"saltysalt";
type Aes128Cbc = Cbc<Aes128, Pkcs7>;

#[derive(Debug)]
pub enum ChromeCookieError {
  CommandFailed(String),
  DecryptionFailed(String),
  Utf8Error(std::string::FromUtf8Error),
  IoError(std::io::Error),
  AesGcmError,
  SqliteError(rusqlite::Error),
  UnsupportedPlatform,
  JsonErr(String),
}
impl fmt::Display for ChromeCookieError {
  fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
    match self {
      ChromeCookieError::CommandFailed(e) => write!(f, "Command failed: {}", e),
      ChromeCookieError::DecryptionFailed(e) => write!(f, "Decryption failed: {}", e),
      ChromeCookieError::Utf8Error(e) => write!(f, "UTF-8 conversion error: {}", e),
      ChromeCookieError::IoError(e) => write!(f, "IO error: {}", e),
      ChromeCookieError::AesGcmError => write!(f, "AES-GCM decryption error"),
      ChromeCookieError::SqliteError(e) => write!(f, "SQLite error: {}", e),
      ChromeCookieError::UnsupportedPlatform => {
        write!(f, "Unsupported platform for Chrome cookies")
      }
      ChromeCookieError::JsonErr(e) => write!(f, "Json error: {}", e),
    }
  }
}
impl Error for ChromeCookieError {}
impl From<std::io::Error> for ChromeCookieError {
  fn from(err: std::io::Error) -> Self {
    ChromeCookieError::IoError(err)
  }
}
impl From<std::string::FromUtf8Error> for ChromeCookieError {
  fn from(err: std::string::FromUtf8Error) -> Self {
    ChromeCookieError::Utf8Error(err)
  }
}
impl From<aes_gcm::Error> for ChromeCookieError {
  fn from(_: aes_gcm::Error) -> Self {
    ChromeCookieError::AesGcmError
  }
}
impl From<rusqlite::Error> for ChromeCookieError {
  fn from(err: rusqlite::Error) -> Self {
    ChromeCookieError::SqliteError(err)
  }
}
impl From<ChromeCookieError> for LuaError {
  fn from(err: ChromeCookieError) -> Self {
    LuaError::external(err)
  }
}

impl From<mlua::Error> for ChromeCookieError {
  fn from(err: mlua::Error) -> Self {
    ChromeCookieError::UnsupportedPlatform
  }
}

impl From<serde_json::Error> for ChromeCookieError {
  fn from(err: serde_json::Error) -> Self {
    ChromeCookieError::JsonErr(err.to_string())
  }
}

/// Get the Chrome password from macOS Keychain (legacy versions)
fn get_chrome_password_macos() -> Result<String, ChromeCookieError> {
  let out = Command::new("security")
    .args(&["find-generic-password", "-w", "-s", "Chrome Safe Storage"])
    .output()?;
  Ok(String::from_utf8(out.stdout)?.trim().to_string())
}

/// Get the Chrome encrypted key from Linux Local State file
fn get_chrome_password_linux() -> Result<String, ChromeCookieError> {
  use serde_json::Value;
  use std::env;
  use std::fs;

  let home_dir = env::var("HOME").map_err(|_| ChromeCookieError::JsonErr("No HOME env".into()))?;
  let local_state_path = format!("{}/.config/google-chrome/Local State", home_dir);
  let data = fs::read_to_string(local_state_path)?;
  let v: Value = serde_json::from_str(&data)?;
  let key = v["os_crypt"]["encrypted_key"]
    .as_str()
    .ok_or_else(|| ChromeCookieError::JsonErr("No encrypted_key found".into()))?;
  Ok(key.to_string())
}

fn get_chrome_password() -> Result<String, ChromeCookieError> {
  #[cfg(target_os = "macos")]
  {
    get_chrome_password_macos()
  }
  #[cfg(target_os = "linux")]
  {
    get_chrome_password_linux()
  }
  #[cfg(not(any(target_os = "macos", target_os = "linux")))]
  {
    Err(ChromeCookieError::UnsupportedPlatform)
  }
}

/// Get the master key for decrypting Chrome cookies on macOS (Unused in legacy versions)
fn get_master_key() -> Result<[u8; 16], ChromeCookieError> {
  let password = get_chrome_password()?;
  let mut ls = PathBuf::from(dirs::home_dir().unwrap());
  ls.push("Library/Application Support/Google/Chrome/Local State");
  let txt = fs::read_to_string(ls)?;
  let json: Value = serde_json::from_str(&txt)
    .map_err(|_| ChromeCookieError::DecryptionFailed("Invalid JSON in Local State".into()))?;
  let b64 = json["os_crypt"]["encrypted_key"]
    .as_str()
    .ok_or_else(|| ChromeCookieError::DecryptionFailed("missing os_crypt.encrypted_key".into()))?;
  let mut blob = general_purpose::STANDARD
    .decode(b64)
    .map_err(|_| ChromeCookieError::DecryptionFailed("Base64 decode error".into()))?;
  if blob.starts_with(b"DPAPI") {
    blob.drain(0..5);
  }
  let mut key = [0u8; 16];
  pbkdf2_hmac::<Sha1>(password.as_bytes(), SALT, 1003, &mut key);
  let nonce = &blob[3..15];
  let ciphertext = &blob[15..];
  let cipher = Aes128Gcm::new(&key.into());
  let plain = cipher
    .decrypt(nonce.into(), ciphertext)
    .map_err(|_| ChromeCookieError::DecryptionFailed("AES-GCM decryption error".into()))?;
  let mut master = [0u8; 16];
  master.copy_from_slice(&plain[..16]);
  Ok(master)
}

/// Decryption function for Chrome cookies on macOS (legacy version)
/// ref: [cyberark](https://www.cyberark.com/resources/threat-research-blog/the-current-state-of-browser-cookies)
/// ref: [chromium](https://source.chromium.org/chromium/chromium/src/+/main:components/os_crypt/sync/os_crypt_mac.mm)
pub fn decrypt_chrome_cookie_macos_legacy(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<String>, ChromeCookieError> {
  Ok(
    decrypt_chrome_cookie_macos_raw(encrypted_value, password)?
      .as_deref()
      .and_then(|raw| to_cookie_string(raw, None)),
  )
}

/// macOS 明文（已去 PKCS#7 padding）。Chrome >= 130 会在明文前置 32 字节 sha256(host_key)。
pub fn decrypt_chrome_cookie_macos_raw(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<Vec<u8>>, ChromeCookieError> {
  const PREFIX: &[u8] = b"v10";
  const IV: [u8; 16] = [b' '; 16];
  const ITERATIONS: u32 = 1003;

  if encrypted_value.len() <= PREFIX.len() || &encrypted_value[..PREFIX.len()] != PREFIX {
    return Ok(None);
  }

  let mut key = [0u8; 16];
  pbkdf2::<Hmac<Sha1>>(password.as_bytes(), SALT, ITERATIONS, &mut key);

  let cipher = Aes128Cbc::new_from_slices(&key, &IV)
    .map_err(|_| ChromeCookieError::DecryptionFailed("AES-CBC init failed".into()))?;
  let decrypted = cipher
    .decrypt_vec(&encrypted_value[PREFIX.len()..])
    .map_err(|_| ChromeCookieError::DecryptionFailed("AES-CBC decrypt failed".into()))?;

  Ok(Some(decrypted))
}

/// 去掉 Chrome >= 130 加在明文前的 sha256(host_key) 前缀。
pub fn strip_host_prefix<'a>(raw: &'a [u8], host_key: &str) -> &'a [u8] {
  let want = Sha256::digest(host_key.as_bytes());
  if raw.len() > 32 && raw[..32] == want[..] {
    &raw[32..]
  } else {
    raw
  }
}

/// 明文转 cookie 字符串；给了 host_key 就先剥前缀。
pub fn to_cookie_string(raw: &[u8], host_key: Option<&str>) -> Option<String> {
  let body = match host_key {
    Some(host) => strip_host_prefix(raw, host),
    None => raw,
  };
  let text = String::from_utf8_lossy(body)
    .trim_end_matches(|c| c == '\0' || c == '`')
    .to_string();
  if text.is_empty() {
    None
  } else {
    Some(text)
  }
}

pub fn derive_linux_key(password: &str) -> [u8; 16] {
  let salt = b"saltysalt";
  let iterations = 1;
  let mut key = [0u8; 16];
  pbkdf2::<Hmac<Sha1>>(password.as_bytes(), salt, iterations, &mut key);
  key
}

/// Decrypt Chrome cookies on Linux
/// ref: [chromium](https://source.chromium.org/chromium/chromium/src/+/main:components/os_crypt/sync/os_crypt_linux.cc)
pub fn decrypt_chrome_cookie_linux(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<String>, ChromeCookieError> {
  Ok(
    decrypt_chrome_cookie_linux_raw(encrypted_value, password)?
      .as_deref()
      .and_then(|raw| to_cookie_string(raw, None)),
  )
}

/// Linux 明文（已去 PKCS#7 padding），同样带 Chrome >= 130 的 sha256(host_key) 前缀。
pub fn decrypt_chrome_cookie_linux_raw(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<Vec<u8>>, ChromeCookieError> {
  // Chrome Linux uses "saltysalt" as salt, 1 iteration, 16-byte key, IV of all spaces
  let iv = [b' '; 16];
  let key = derive_linux_key(password);

  // Check for v10/v11 prefix
  if encrypted_value.len() <= 3 {
    return Ok(None);
  }
  let prefix = &encrypted_value[..3];
  if prefix != b"v10" && prefix != b"v11" {
    return Ok(None);
  }

  let cipher = Aes128Cbc::new_from_slices(&key, &iv)
    .map_err(|_| ChromeCookieError::DecryptionFailed("AES-CBC init failed".into()))?;
  let decrypted = cipher
    .decrypt_vec(&encrypted_value[3..])
    .map_err(|_| ChromeCookieError::DecryptionFailed("AES-CBC decrypt failed".into()))?;

  Ok(Some(decrypted))
}

/// Decrypt cookies for macOS and Linux
pub fn decrypt_chrome_cookie(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<String>, ChromeCookieError> {
  Ok(
    decrypt_chrome_cookie_raw(encrypted_value, password)?
      .as_deref()
      .and_then(|raw| to_cookie_string(raw, None)),
  )
}

/// 平台对应的明文解密（未剥 host 前缀）
pub fn decrypt_chrome_cookie_raw(
  encrypted_value: &[u8],
  password: &str,
) -> Result<Option<Vec<u8>>, ChromeCookieError> {
  #[cfg(target_os = "macos")]
  {
    decrypt_chrome_cookie_macos_raw(encrypted_value, password)
  }
  #[cfg(target_os = "linux")]
  {
    decrypt_chrome_cookie_linux_raw(encrypted_value, password)
  }
  #[cfg(not(any(target_os = "macos", target_os = "linux")))]
  {
    Err(ChromeCookieError::UnsupportedPlatform)
  }
}

/// Chrome stores a cookie set on the registrable domain under a leading dot
/// (`.zhihu.com`) and still sends it to every subdomain (`www.zhihu.com`), while
/// cookies set on the page host carry the bare host. Matching both forms is what
/// makes the login cookie (`z_c0` on `.zhihu.com`) reach the request.
pub fn cookie_host_matches(host_key: &str, host: &str) -> bool {
  let host = host.trim_start_matches('.');
  match host_key.strip_prefix('.') {
    Some(domain) => host == domain || host.ends_with(&format!(".{domain}")),
    None => host_key == host,
  }
}

pub fn get_cookie_value(
  cookie_path: &str,
  password: &str,
  host: &str,
  cookie_name: &str,
) -> Result<Option<String>, ChromeCookieError> {
  let conn = Connection::open(cookie_path)?;
  let mut stmt = conn
    .prepare("SELECT host_key, encrypted_value FROM cookies WHERE name = ?")
    .map_err(ChromeCookieError::SqliteError)?;
  let mut rows = stmt.query([cookie_name])?;
  while let Some(row) = rows.next()? {
    let host_key: String = row.get(0)?;
    if !cookie_host_matches(&host_key, host) {
      continue;
    }
    let encrypted_value: Vec<u8> = row.get(1)?;
    return Ok(
      decrypt_chrome_cookie_raw(&encrypted_value, password)?
        .as_deref()
        .and_then(|raw| to_cookie_string(raw, Some(&host_key))),
    );
  }
  Ok(None)
}

pub fn get_cookies_for_host(
  cookie_path: &str,
  password: &str,
  host: &str,
) -> Result<Vec<(String, String)>, ChromeCookieError> {
  let conn = Connection::open(cookie_path)?;
  let mut stmt = conn.prepare("SELECT host_key, name, encrypted_value FROM cookies")?;
  let mut rows = stmt.query([])?;
  let mut result = Vec::new();
  while let Some(row) = rows.next()? {
    let host_key: String = row.get(0)?;
    if !cookie_host_matches(&host_key, host) {
      continue;
    }
    let name: String = row.get(1)?;
    let blob: Vec<u8> = row.get(2)?;
    let val = decrypt_chrome_cookie_raw(&blob, password)?
      .as_deref()
      .and_then(|raw| to_cookie_string(raw, Some(&host_key)))
      .unwrap_or_else(|| String::from_utf8_lossy(&blob).to_string());
    result.push((name, val));
  }
  Ok(result)
}

/// Get all cookies from the Chrome cookie database
pub fn get_cookies(
  cookie_path: &str,
  password: &str,
) -> Result<Vec<(String, String)>, ChromeCookieError> {
  let conn = Connection::open(cookie_path)?;
  let mut stmt = conn.prepare("SELECT host_key, name, encrypted_value FROM cookies")?;
  let mut rows = stmt.query([])?;
  let mut result = Vec::new();
  while let Some(row) = rows.next()? {
    let host_key: String = row.get(0)?;
    let name: String = row.get(1)?;
    let blob: Vec<u8> = row.get(2)?;
    let val = decrypt_chrome_cookie_raw(&blob, password)?
      .as_deref()
      .and_then(|raw| to_cookie_string(raw, Some(&host_key)))
      .unwrap_or_else(|| String::from_utf8_lossy(&blob).to_string());
    result.push((name, val));
  }
  Ok(result)
}

#[mlua::lua_module]
fn chrome_cookie(lua: &Lua) -> LuaResult<mlua::Table> {
  let exports = lua.create_table()?;

  // decrypt_chrome_cookie(encrypted_value: Vec<u8>, password: String) -> Option<String>
  exports.set(
    "decrypt_chrome_cookie",
    lua.create_function(
      |_, (encrypted_value, password): (Vec<u8>, String)| -> LuaResult<Option<String>> {
        decrypt_chrome_cookie_macos_legacy(&encrypted_value, &password).map_err(LuaError::external)
      },
    )?,
  )?;

  // get_master_key() -> String
  exports.set(
    "get_master_key",
    lua.create_function(|lua, ()| {
      get_master_key()
        .map(|key| lua.create_string(&key).unwrap())
        .map_err(LuaError::external)
    })?,
  )?;

  // get_chrome_password() -> String
  exports.set(
    "get_chrome_password",
    lua.create_function(|_, ()| get_chrome_password().map_err(LuaError::external))?,
  )?;

  // get_cookies(cookie_path: String, password: String) -> table
  exports.set(
    "get_cookies",
    lua.create_function(
      |lua, (cookie_path, password): (String, String)| -> LuaResult<mlua::Table> {
        let cookies = get_cookies(&cookie_path, &password).map_err(LuaError::external)?;
        let table = lua.create_table()?;
        for (name, val) in cookies {
          table.set(name, val)?;
        }
        Ok(table)
      },
    )?,
  )?;

  // get_cookies_for_host(cookie_path: String, password: String, host: String) -> table
  exports.set(
    "get_cookies_for_host",
    lua.create_function(
      |lua, (cookie_path, password, host): (String, String, String)| -> LuaResult<mlua::Table> {
        let cookies =
          get_cookies_for_host(&cookie_path, &password, &host).map_err(LuaError::external)?;
        let table = lua.create_table()?;
        for (name, val) in cookies {
          table.set(name, val)?;
        }
        Ok(table)
      },
    )?,
  )?;

  // get_cookie_value(cookie_path: String, password: String, host: String, name: String) -> Option<String>
  exports.set(
    "get_cookie_value",
    lua.create_function(
      |_,
       (cookie_path, password, host, name): (String, String, String, String)|
       -> LuaResult<Option<String>> {
        get_cookie_value(&cookie_path, &password, &host, &name).map_err(LuaError::external)
      },
    )?,
  )?;

  Ok(exports)
}
