# Versioning Policy

How this repo's engine builds are labeled, named, and bumped.

## Source of truth

`config/engine-version.txt` holds the one canonical version label, e.g.:

```
CX26.3.0-W11-Gamma086
```

`config/engine-release.json`'s `versionLabel` field mirrors it and must be
updated together, by hand, in the same commit. (`engineId` in the same file
is a third, separately hand-typed lowercase slug of the same version —
`cx26.3-w11-gamma086` — and is a known follow-up candidate for the same
mechanical-derivation treatment given to `artifactBasename` below; it is not
addressed by this policy yet.)

## Label format

```
CX<crossover-version>-W<wine-major>-Gamma<NNN>
```

- `<crossover-version>` — the CrossOver source version this build is
  patched from (`base.crossover` in `engine-release.json`), currently always
  `26.3.0` — CX24 and CX25 are retired (`prepare-build-deps.sh` rejects
  both; only CX26 sources are extracted).
- `<wine-major>` — the upstream Wine major version CrossOver 26.3.0 is built
  on (`base.wine`), currently `11`.
- `Gamma<NNN>` — a sequential GAMMA build counter, no reset tied to the CX or
  Wine numbers. Zero-padding is not required (`Gamma086`, not `Gamma86`, is
  just convention from recent history, not an enforced format).

## Artifact basename — derived, not hand-typed

The compact name used for the actual output filename
(`dist/artifacts/<artifactBasename>.tar.xz` / `.tar.zst`) used to be a
separate field in `engine-release.json` (`artifactBasename`) that had to be
kept in sync with `versionLabel` by hand across two files — a real drift
risk, and exactly how this repo and `gamma-setup-tool` ended up disagreeing
about what the "current" engine build is even called (see Cross-repo note
below).

That field is gone. The basename is now always computed from the version
label by `gamma_engine_artifact_basename_from_label()` in
`scripts/engine-common.sh`:

```
CX26.3.0-W11-Gamma086  ->  CX26W11-Gamma086-<N>
```

Rule: `CX<crossover-major>` + `W<wine-major>` + `-Gamma<NNN>` + `-<N>`, i.e.
the crossover minor/patch (`.3.0`) is dropped and everything else is
concatenated with a single dash before `Gamma`. `<N>` increments from the
highest existing pack number for that version label; both `.tar.xz` and
`.tar.zst` packs count. Legacy names without the dash before `Gamma` also
count, so the next `Gamma086` pack after `CX26W11Gamma086-4` is
`CX26W11-Gamma086-5`.

Nothing else needs to change when bumping a version — editing
`engine-version.txt` (and mirroring
`engine-release.json`'s `versionLabel`) is now the only edit required for the
name to propagate everywhere.

## When to bump the Gamma counter

There's no script that bumps it automatically — it's a manual edit, done
alongside whatever prompted the new build. Based on actual practice in this
repo's history, bump it when:

- A build in `dist/artifacts/` is meant to be kept, tested, or handed off
  (not a throwaway `--dry-run` or local `--configure-only` check).
- The patch set changes (`engine-release.json`'s `patches` array must be
  updated in the same commit — a shipped artifact's manifest should always
  say exactly what patches produced it).
- A validated milestone is reached worth recording (e.g. "confirmed D3DMetal
  b1 game launch" — see `4305d5f`), even without a patch change, so the
  build that was actually tested is distinguishable from ones that weren't.

Do **not** bump on doc-only or non-build-affecting script changes (nothing in
`dist/artifacts/` would differ).

## Bumping the CX or Wine base version

Only when the actual upstream source changes: a new
`sources/crossover-sources-<ver>.tar.gz` is added, `prepare-build-deps.sh`'s
`cx_archive_for()` is updated to recognize it, and `base.crossover` /
`base.wine` in `engine-release.json` are updated to match. This is a bigger
change than a Gamma bump and should get its own review pass over the patch
set (patches are pinned to specific CX source trees and may not apply
cleanly to a different one).

## Cross-repo note: `gamma-setup-tool` is not wired to this

`gamma-setup-tool` keeps its own, independent copy of an engine identifier —
`SetupDefaults.gammaWine26Engine` in `SetupModels.swift`, currently
`"CX26-3W11-Gamma0-1"` — used both as a UI/selection value and as the literal
filename it looks up under
`Resources/wine-engine/<value>.tar.xz`. It does not read this repo's
`engine-version.txt` or `engine-release.json`, follows neither the label
format nor the derived-basename format above, and is already stale relative
to the latest build in `dist/artifacts/` (`Gamma0-1` vs. the current
`Gamma086`). Bundling a newer engine into the setup tool is a manual step:
copy the new tarball into that `Resources/wine-engine/` path and update the
Swift constant (and the picker logic keyed off it) to match. That work
happens in `gamma-setup-tool` and, requires
loading the `swiftui-pro` and `swiftui-expert-skill` skills first — it is
out of scope here.
