# gamma-wine-engine

A Wine 11.16 / CrossOver 26.3.0 engine for running S.T.A.L.K.E.R. Anomaly and G.A.M.M.A. on Apple Silicon Macs with macOS 15 or newer, with [DXMT](https://github.com/3Shain/dxmt) as its Direct3D 11 backend.

The engine is packed as `dist/artifacts/CX26W11-GAMMA-DXMT-<N>.tar.zst`. [GAMMA Setup Tool](https://github.com/elseform/gamma-setup-tool) turns an archive into a game app with its own Wine prefix and a settings editor.

## Documentation

| Doc | For |
|---|---|
| [Getting Started](docs/getting-started.md) | Creating the app, changing settings, troubleshooting |
| [Building](docs/building.md) | Prerequisites, the build and packing pipeline, versioning |
| [Architecture](docs/architecture.md) | Archive layout, backend selection, Configurator, Microsoft runtime files |
| [Setup Tool Contract](docs/setup-tool-contract.md) | What `gamma-setup-tool` relies on in an archive, and what it builds |
| [Graphics Backends](docs/renderers.md) | DXMT and the optional, user-supplied D3DMetal |
| [Patch Set](patches/README.md) | What each Wine patch does, and the one deliberately left out |
| [Why deps build from source](docs/why-no-prebuilt-deps.md) | The project-local `.brew-x86` |
| [Manual Setup](docs/manual-setup.md) | Creating a prefix by hand, for debugging |

## Features

- **Backend switcher (`cxcompatdb.so`)** — selects DXMT (or a user-supplied D3DMetal) per process from `GAMMA_GRAPHICS_BACKEND`, without modifying DLLs in the prefix, and terminates the process rather than falling back to WineD3D when the backend is incomplete.
- **Msync (`WINEMSYNC=1`)** — Mach-semaphore synchronization in shared memory instead of wineserver round trips.
- **Stability patches** — wineserver socket and async fixes, `ntdll` frame-walk guards, and a hardware memory barrier in `NtFlushProcessWriteBuffers` that avoids stalls under Rosetta 2. The CrossOver message-wait handoff patch that freezes the game on UI clicks is deliberately not applied.
- **No redistributed Microsoft files** — the engine declares the Visual C++ and DirectX files it needs; they are fetched from Microsoft's own installers, pinned by checksum, when the app is created.
- **Relocatable** — bundled libraries are linked `@loader_path`-relative and every Mach-O is signed.

## Quick build

```bash
bash scripts/build-wine.sh --bootstrap-brew --install-deps   # first time
bash scripts/pack-engine-artifact.sh
```

See [docs/building.md](docs/building.md) for prerequisites and the full pipeline.

## License

MIT, see [LICENSE](LICENSE). DXMT's license is in [renderers/dxmt/NOTICE](renderers/dxmt/NOTICE).
