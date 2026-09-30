# Why the x86_64 build deps compile from source instead of downloading prebuilt

## Short answer

Homebrew's prebuilt binaries ("bottles") are compiled with a hardcoded
install path baked into them: `/usr/local` on Intel, `/opt/homebrew` on
Apple Silicon. Our build uses neither — it installs into
`anomaly-wine-engine/.brew-x86/`, a project-local x86_64 prefix, on purpose.
A bottle whose libraries/binaries expect `/usr/local` won't run correctly
from a different path, so Homebrew refuses to pour the bottle and falls
back to compiling from source instead. That's the
`Warning: Building X from source as the bottle needs: HOMEBREW_PREFIX=/usr/local`
message you see for nearly every formula in the build log.

## Why not just use `/usr/local` or `/opt/homebrew` then?

- `/opt/homebrew` is arm64-only on this machine (Apple Silicon default
  prefix) — it cannot hold x86_64 binaries at all.
- `/usr/local` *can* hold an x86_64 Homebrew (the traditional Intel-Mac
  layout, still usable under Rosetta), but that means installing a second,
  system-wide Homebrew that every other tool/shell on the machine could
  pick up by accident, and that persists outside this repo. That's exactly
  the ambiguity `env-x86_64.sh` avoids: it explicitly overrides
  `HOMEBREW_PREFIX` away from `/opt/homebrew` and refuses to default to
  `/usr/local`, keeping the whole x86_64 toolchain scoped to
  `.brew-x86/` inside this repo — reproducible, gitignored, deletable,
  and never fighting a real system Homebrew install.

## Why does it matter for a Wine build specifically

The Wine binary and the runtime libraries copied into its
`lib/wine/x86_64-unix/` tree need to (a) be x86_64 Mach-O (Wine runs
under Rosetta on Apple Silicon) and (b) target an old-enough macOS
deployment version (`MACOSX_DEPLOYMENT_TARGET`, default 10.15) so the
shipped engine works on the range of macOS versions anomaly-setup-tool
supports. Homebrew's official x86_64 bottles are built for whatever
macOS/deployment-target Homebrew's CI currently targets, which is
typically much newer — using them as-is would still require a fixup
pass. Building from source with our own flags sidesteps both problems
at once.

## The actual cost

- One-time: once a dependency (gettext, gmp, gnutls, …) is built and
  sitting in `.brew-x86/Cellar/`, `brew_x86`/`brew_x86_install_runtime`
  skip it on future runs — this pain is paid once per machine, not once
  per build.
- Slower first run: expect real compiles (autoreconf + configure + make
  [+ make check]) for anything without a matching-prefix bottle, which on
  this hardware is effectively everything, since no public bottle target
  matches a `.brew-x86`-style project-local prefix.
