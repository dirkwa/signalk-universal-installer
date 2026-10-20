# __DISPLAY_NAME__

Signal K WASM plugin written in Rust, compiled to `wasm32-wasip1`.

## Build

```bash
npm run build    # cargo build --release, copies the module to plugin.wasm
npm run check    # clippy, warnings as errors
```

The plugin only emits deltas. Before calling host functions that read
the data model or use the plugin's file storage, set `dataRead` to `true`
or `storage` to `"vfs-only"` under `wasmCapabilities` in package.json:
signalk-server treats an absent `dataRead` as `true` and an absent
`storage` as `"vfs-only"`, so the template declares both off explicitly.

## Publish

`npm publish` ships `package.json`, `README.md` and `plugin.wasm` (see
`files` in package.json). The `signalk-wasm-plugin` keyword together with
`wasmManifest` makes signalk-server load the package as a WASM plugin.
