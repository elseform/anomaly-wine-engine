# Engine Patch Set

The engine's Wine is upstream **Wine 11.16** (`wine-11.16.tar.xz` from
dl.winehq.org, pinned by sha256 in `scripts/prepare-build-deps.sh`) with the
patches in [`series`](series) applied in order. `scripts/apply-wine-series.sh`
applies them with `patch -p1 -F0` (no fuzz), records what it applied, and
regenerates `configure`. The same list, in the same order, is in
`config/engine-release.json` and lands in every release manifest.

26 patches; 25 when Wine is built with Vulkan (`w1` is only for the default
`--without-vulkan` build). Licensing: [NOTICE](NOTICE).

## The series

| # | Patch | Subsystem | Origin | Purpose |
|---|---|---|---|---|
| 1 | `crossover-26.3.0-wine-11.16-port.patch` | many (199 files) | CodeWeavers, ported | CrossOver 26.3.0's changes to Wine, carried from Wine 11.0 onto 11.16. See [Lineage](#lineage). |
| 2 | `gamma-advapi32-consistent-username-opt-in.patch` | `advapi32` | engine | CrossOver Hack 12735 (user name "crossover") only when `CX_CONSISTENT_USERNAME` is set; the real name otherwise, so DPAPI blobs from a stock prefix stay readable. |
| 3 | `gamma-ntdll-mono-last-error-gs.patch` | `ntdll` | engine | Mirrors the last error into `%gs:0x68`, where Mono's JIT reads it, and hooks `gmtime()` off that TLS slot. |
| 4 | `gamma-winemac-host-app-icon.patch` | `winemac.drv` | engine | `WINE_APP_ICON_PATH` (optionally limited by `WINE_APP_IDENTITY_EXE`) names the Dock icon, ahead of the executable's own. |
| 5 | `gamma-winemac-cross-process-child-swapchain.patch` | `winemac.drv` | engine | Metal swapchains on child windows whose top level belongs to another process (Chromium GPU processes); `surface.c` no longer hides a window's `client_view` when it paints through GDI. |
| 6 | `gamma-nsiproxy-null-ifaddr-and-leaks.patch` | `nsiproxy.sys` | engine | Skips interfaces with no address, clamps a sockaddr copy, frees `addr_scopes` in the TCP and UDP tables. |
| 7 | `gamma-ntdll-unwind-null-guards.patch` | `ntdll` | engine | NULL handler-data guard in the x86_64 unwinder; initialised module pointer in `virtual_unwind()`. |
| 8 | `gamma-winegstreamer-bundled-plugins-and-pool.patch` | `winegstreamer` | engine | Bundled GStreamer plugin path and a zero-sized buffer pool fix. Inert today: the engine is built without GStreamer, so `winegstreamer.so` is not built. |
| 9 | `gamma-faudio-26.08.patch` | `libs/faudio` | upstream FAudio | Bundled FAudio 26.06 → 26.08. |
| 10 | `a6-final-same-view-backing-sync.patch` | `winemac.drv` | cyder-wine-engine, 11.16 rebase | Synchronises AppKit / Wine backing surfaces on window resize and creation. |
| 11 | `w1-win32u-vulkan-soname.patch` | `win32u` | cyder-wine-engine | `--without-vulkan` builds only: supplies the `SONAME_LIBVULKAN` fallback define so `dlls/win32u/vulkan.c` compiles without libvulkan or MoltenVK. |
| 12 | `wine-11.1-rtlwalkframechain-null-function.patch` | `ntdll` | upstream Wine 11.1 | NULL function guard during stack walking. |
| 13 | `cyder-ntdll-frame-walk-page-fault-guard.patch` | `ntdll` | cyder-wine-engine | Guards stack frame walking against page faults in 64-bit binaries. |
| 14 | `cyder-wineserver-sock-reselect-pseudo-fd.patch` | `wineserver` | cyder-wine-engine | Socket pseudo-fd reselection during high-frequency polls. |
| 15 | `cyder-wineserver-poll-slot-guard.patch` | `wineserver` | cyder-wine-engine | Reports and skips stale poll slots instead of aborting wineserver. |
| 16 | `cyder-wineserver-exit-diagnostics.patch` | `wineserver` | cyder-wine-engine, 11.16 rebase | Diagnostic logging on wineserver exit. |
| 17 | `cyder-wineserver-fd-reselect-async-null-ops.patch` | `wineserver` | cyder-wine-engine, 11.16 rebase | NULL `fd_ops` guard in `fd_reselect_async()`. |
| 18 | `cyder-wineserver-sock-rebind-async-fd.patch` | `wineserver` | cyder-wine-engine | Socket rebinding race in multithreaded networking. |
| 19 | `cyder-wineserver-async-terminate-null-fd.patch` | `wineserver` | cyder-wine-engine | NULL fd on async termination. |
| 20 | `cyder-wineserver-free-async-queue-null-fd.patch` | `wineserver` | cyder-wine-engine | NULL fd when freeing async queues. |
| 21 | `cyder-wineserver-pipe-end-disconnect-null-fd.patch` | `wineserver` | cyder-wine-engine | Named pipe disconnect after the fd is closed. |
| 22 | `cyder-wineserver-add-completion-guard.patch` | `wineserver` | cyder-wine-engine | Invalid I/O completion port notifications. |
| 23 | `cyder-ntdll-qdo-optnone-NtQueryDirectoryObject.patch` | `ntdll` | cyder-wine-engine | Disables the Clang optimisation that miscompiled `NtQueryDirectoryObject`. |
| 24 | `gamma-ntdll-flush-write-buffers-sync.patch` | `ntdll` | engine | Hardware barrier instead of the Mach register walk in `NtFlushProcessWriteBuffers`, avoiding Rosetta 2 thread stalls. |
| 25 | `wine-mr11880-winemac-transparent-hidden-cursor.patch` | `winemac.drv` | upstream MR !11880 (open) | Transparent `NSCursor` instead of `[NSCursor hide]`, which on macOS 26 ties presentation to the display refresh while the mouse moves. |
| 26 | `wine-mr11799-winemac-gcmouse-raw-input.patch` | `winemac.drv` | upstream MR !11799 (open) | On macOS 14+, Raw Input (and so DirectInput) mouse movement comes unaccelerated from `GCMouse`. Off switch: `HKCU\Software\Wine\Mac Driver`, `UseGCMouse=N`. |

### Filenames

- `crossover-` — CodeWeavers' code (LGPL), ported here.
- `gamma-` — written for this engine.
- `cyder-`, `a6-`, `w1-` — from
  [cyder-wine-engine](https://github.com/dspp779/cyder-wine-engine), the
  pipeline this repository was forked from; the names are provenance.
- `wine-` — upstream Wine commits and merge requests.

Patches marked "11.16 rebase" differ from their cyder-wine-engine originals,
which were written for Wine 11.0; each says how in its header.

## Lineage

Engine builds 14–18 (August–September 2026) were built from a Wine 11.16
source tree that no script produced: on 2026-08-29 an agent session pulled
upstream Wine 11.16, ported CrossOver 26.3.0's changes onto it, added the
engine changes above, and copied the result into the build directory with
the cyder patches already applied. Nothing recorded that work.

On 2026-09-27 the tree was reconstructed: upstream `wine-11.16.tar.xz` plus
this series, with autoconf regenerating `configure`, reproduced it byte for
byte, file modes included. The series then changed on purpose in three ways:

- **Dropped:** Proton's `lsteamclient` (Steam client bridge, under Valve's
  Steamworks SDK license, not needed by GAMMA) and a D3D12 layer
  (`d3d12core` implementation, D3DKMT adapter queries, an Apple GPU driver
  version string) that DXMT does not use.
- **Fixed:** the port had lost CrossOver's `IOKit/usb/IOUSBLib.h` configure
  check, which compiled `winebus.sys/bus_xbox360.c` out; it is restored.

The CrossOver 26.3.0 source archive is no longer a build input.

## Patches & fixes that resolved the game hanging

### Reverted `maplestory-cx26-message-wait-handoff.patch` from `win32u.so`

- **The problem:** it modified `wait_message()` in `dlls/win32u/message.c` to
  skip `NtWaitForMultipleObjects` whenever `process_driver_events()` returned
  `TRUE`. On macOS, Cocoa mouse-move and window events made that happen
  constantly, so `wait_message()` never blocked and the main thread spun and
  deadlocked on any UI or menu click.
- **The fix:** the standard upstream behaviour. The patch is not in this
  repository.

### `gamma-ntdll-flush-write-buffers-sync.patch` in `ntdll.so`

- **The problem:** CrossOver's macOS `NtFlushProcessWriteBuffers` in
  `dlls/ntdll/unix/virtual.c` called `task_threads()` and
  `thread_get_register_pointer_values()` on every Mach thread to force memory
  synchronisation. Under Rosetta 2, querying translated x86 register state
  while worker threads yielded stalled threads badly.
- **The fix:** a hardware memory barrier (`__sync_synchronize()`), relying on
  Apple Silicon's Total Store Order memory model.

### Why `maplestory-cx26-message-wait-handoff.patch` is gone

Upstream Cyder applies it to every CX26 build (its comment claims it is "not a
MapleStory-only patch"). On this engine it caused the freeze described above.
It is game-specific to MapleStory and this engine does not need it, so the
file is not kept at all. If some future change appears to want it, copy it
from `cyder-wine-engine/patches/` and retest UI and menu clicking before
trusting it.
