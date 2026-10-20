# __DISPLAY_NAME__

Signal K WASM plugin written in Rust, compiled to `wasm32-wasip1`.

## Build

```bash
npm run build    # cargo build --release, copies the module to plugin.wasm
npm run check    # clippy, warnings as errors
```

Inside the signalk-universal-installer devcontainer, `dev/dev.sh restart`
links this plugin into the dev server. After a code change, rebuild on
restart with `SK_DEV_PLUGIN_BUILD=1 dev/dev.sh restart`.

## Publish

`npm publish` ships `package.json`, `README.md` and `plugin.wasm` (see
`files` in package.json). The `signalk-wasm-plugin` keyword together with
`wasmManifest` makes signalk-server load the package as a WASM plugin.
