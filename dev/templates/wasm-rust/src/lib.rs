//! __DISPLAY_NAME__ — a Signal K WASM plugin.
//!
//! The server finds the plugin through package.json (keyword
//! `signalk-wasm-plugin`, `wasmManifest`) and talks to it through the
//! exports below. Strings cross the boundary as (pointer, length) pairs in
//! linear memory; `allocate`/`deallocate` let the host place them there.
//! Host functions and further exports (PUT handlers, HTTP endpoints,
//! delta subscriptions): docs/develop/plugins/wasm in signalk-server.

use serde::Deserialize;

#[link(wasm_import_module = "env")]
extern "C" {
    fn sk_debug(ptr: *const u8, len: usize);
    fn sk_set_status(ptr: *const u8, len: usize);
    fn sk_set_error(ptr: *const u8, len: usize);
    fn sk_handle_message(ptr: *const u8, len: usize);
}

fn debug(msg: &str) {
    unsafe { sk_debug(msg.as_ptr(), msg.len()) }
}

fn set_status(msg: &str) {
    unsafe { sk_set_status(msg.as_ptr(), msg.len()) }
}

fn set_error(msg: &str) {
    unsafe { sk_set_error(msg.as_ptr(), msg.len()) }
}

fn handle_message(delta: &str) {
    unsafe { sk_handle_message(delta.as_ptr(), delta.len()) }
}

const PLUGIN_ID: &str = "__PLUGIN_ID__";
const PLUGIN_NAME: &str = "__DISPLAY_NAME__";
const PLUGIN_SCHEMA: &str = r#"{
  "type": "object",
  "properties": {
    "message": {
      "type": "string",
      "title": "Message published on start",
      "default": "Hello from Rust"
    }
  }
}"#;

#[derive(Deserialize)]
struct Config {
    #[serde(default = "default_message")]
    message: String,
}

fn default_message() -> String {
    "Hello from Rust".to_string()
}

#[no_mangle]
pub extern "C" fn allocate(size: usize) -> *mut u8 {
    let mut buf = Vec::<u8>::with_capacity(size);
    let ptr = buf.as_mut_ptr();
    std::mem::forget(buf);
    ptr
}

/// # Safety
/// `ptr` and `size` must come from a matching `allocate` call.
#[no_mangle]
pub unsafe extern "C" fn deallocate(ptr: *mut u8, size: usize) {
    drop(Vec::from_raw_parts(ptr, 0, size));
}

/// Copies `s` into the host's buffer and returns the bytes written.
fn write_string(s: &str, out_ptr: *mut u8, out_max_len: usize) -> i32 {
    let len = s.len().min(out_max_len);
    unsafe { std::ptr::copy_nonoverlapping(s.as_ptr(), out_ptr, len) };
    len as i32
}

#[no_mangle]
pub extern "C" fn plugin_id(out_ptr: *mut u8, out_max_len: usize) -> i32 {
    write_string(PLUGIN_ID, out_ptr, out_max_len)
}

#[no_mangle]
pub extern "C" fn plugin_name(out_ptr: *mut u8, out_max_len: usize) -> i32 {
    write_string(PLUGIN_NAME, out_ptr, out_max_len)
}

#[no_mangle]
pub extern "C" fn plugin_schema(out_ptr: *mut u8, out_max_len: usize) -> i32 {
    write_string(PLUGIN_SCHEMA, out_ptr, out_max_len)
}

/// Receives the plugin's configuration object as JSON; 0 means started.
///
/// # Safety
/// The host passes `config_len` readable bytes at `config_ptr`.
#[no_mangle]
pub unsafe extern "C" fn plugin_start(config_ptr: *const u8, config_len: usize) -> i32 {
    let raw = std::slice::from_raw_parts(config_ptr, config_len);
    let config: Config = match serde_json::from_slice(raw) {
        Ok(config) => config,
        Err(err) => {
            set_error(&format!("Invalid configuration: {err}"));
            return 1;
        }
    };

    let delta = serde_json::json!({
        "context": "vessels.self",
        "updates": [{
            "values": [{
                "path": format!("plugins.{PLUGIN_ID}.message"),
                "value": config.message,
            }]
        }]
    });
    handle_message(&delta.to_string());

    debug("started");
    set_status("Running");
    0
}

#[no_mangle]
pub extern "C" fn plugin_stop() -> i32 {
    set_status("Stopped");
    0
}
