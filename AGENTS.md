# GAMMA Wine Engine Adapter

## Project identity

- Project root: `../gamma-project`
- Repository: `gamma-wine-engine`
- Role: `supporting-application`

Read `../gamma-project/AGENTS.md` before work. Shared safety and cross-repository
policy remain canonical there. This repository owns the Wine 11.16 /
CrossOver 26.3.0 engine build pipeline, patches, the `cxcompatdb` backend
switcher, DXMT/D3DMetal packaging (no WineD3D fallback), and
release artifacts (`dist/artifacts/*.tar.xz`). Build and lifecycle:
`docs/building.md`; consumer interface: `docs/setup-tool-contract.md`.

The engine archive is consumed by `gamma-setup-tool`, whose
`interactive_setup.py` (lives there, not in this repo) builds a wrapper `.app`
around it. `renderers/dxmt/` is a built DXMT payload from the `elseform/dxmt`
fork, built per `gamma-project`'s `docs/engine/dxmt-build.md`; it is distinct
from the `dxmt` source checkout resolved via `project-paths-get.py --field
dxmt_root`. `fetch-dxmt.sh` would replace it with an upstream CI build.
