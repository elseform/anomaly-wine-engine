# Engine Patch Set

This document details the active patch set applied to CrossOver 26.3.0 (Wine 11.16) in `gamma-wine-engine`.

15 patches are applied automatically in sequence by `scripts/build-wine.sh`
(14, without `w1-win32u-vulkan-soname.patch`, when building with Vulkan). It
fails loudly if a listed patch file is missing. The same list is recorded
in `config/engine-release.json` and lands in the release manifest.

---

## Active Patches in `gamma-wine-engine`

| # | Patch File | Subsystem | Purpose |
|---|---|---|---|
| 1 | `a6-final-same-view-backing-sync.patch` | `winemac.drv` | Synchronizes AppKit / Wine backing surfaces on macOS window resize/creation. |
| 2 | `wine-11.1-rtlwalkframechain-null-function.patch` | `ntdll` | Backport from Wine 11.1 to handle NULL functions safely during stack unwinding. |
| 3 | `cyder-ntdll-frame-walk-page-fault-guard.patch` | `ntdll` | Guards stack frame walking against page faults/crashes in 64-bit binaries. |
| 4 | `cyder-wineserver-sock-reselect-pseudo-fd.patch` | `wineserver` | Fixes wineserver socket pseudo-fd reselection during high-frequency poll calls. |
| 5 | `cyder-wineserver-poll-slot-guard.patch` | `wineserver` | Prevents poll table corruption when slots are released concurrently. |
| 6 | `cyder-wineserver-exit-diagnostics.patch` | `wineserver` | Adds clean diagnostic logging on process exit. |
| 7 | `cyder-wineserver-fd-reselect-async-null-ops.patch` | `wineserver` | Adds null check to async operations during fd reselection. |
| 8 | `cyder-wineserver-sock-rebind-async-fd.patch` | `wineserver` | Fixes socket rebinding race conditions in multithreaded networking. |
| 9 | `cyder-wineserver-async-terminate-null-fd.patch` | `wineserver` | Prevents null pointer dereference on async queue termination. |
| 10 | `cyder-wineserver-free-async-queue-null-fd.patch` | `wineserver` | Null pointer safety guard when freeing async queues. |
| 11 | `cyder-wineserver-pipe-end-disconnect-null-fd.patch` | `wineserver` | Fixes named pipe disconnect crash when fd is already closed. |
| 12 | `cyder-wineserver-add-completion-guard.patch` | `wineserver` | Prevents crash in I/O completion port notifications. |
| 13 | `cyder-ntdll-qdo-optnone-NtQueryDirectoryObject.patch` | `ntdll` | Disables aggressive Clang optimization on `NtQueryDirectoryObject` that caused miscompilation. |
| 14 | `gamma-ntdll-flush-write-buffers-sync.patch` | `ntdll` | Replaces expensive Mach thread register iteration in `NtFlushProcessWriteBuffers` with hardware memory barrier (`__sync_synchronize()`), preventing Rosetta 2 thread deadlocks. |

> Patch 14 was regenerated against pristine CX 26.3.0 sources in August 2026: the
> committed file had a corrupt hunk header (`@@ -7061,26 +7061,8 @@` for a 30/10
> hunk) and could not apply at all, and `build-wine.sh` never referenced it. Both
> are fixed — verified to apply to pristine sources and to be detected as already
> applied on a patched tree.

---

## Patches & Fixes That Resolved the Game Hanging

### 1. Reverted `maplestory-cx26-message-wait-handoff.patch` from `win32u.so`
- **The Problem**: A legacy patch modified `wait_message()` in `dlls/win32u/message.c` to skip `NtWaitForMultipleObjects` whenever `process_driver_events()` returned `TRUE`. On macOS, Cocoa mouse move and window events caused `wait_message()` to return immediately without blocking, resulting in an infinite CPU spinloop that deadlocked the main thread whenever any UI/menu element was clicked.
- **The Fix**: Completely reverted to standard upstream Wine implementation. Deleted the patch from `patches/` and `config/engine-release.json`.

### 2. Applied `gamma-ntdll-flush-write-buffers-sync.patch` to `ntdll.so`
- **The Problem**: CrossOver's macOS implementation of `NtFlushProcessWriteBuffers` in `dlls/ntdll/unix/virtual.c` called `task_threads()` and `thread_get_register_pointer_values()` on all Mach threads in the process to force memory synchronization. Under Rosetta 2 on Apple Silicon, querying translated x86 register state while worker threads yielded caused severe kernel thread stalls and hangs.
- **The Fix**: Replaced the Mach thread iteration loop with a hardware memory barrier (`__sync_synchronize()`), taking advantage of Apple Silicon's hardware Total Store Order (TSO) memory consistency.

---

## Present but not in the numbered list

This file was deleted at one point and has been restored from
`cyder-wine-engine`, because `build-wine.sh` still references it:

| File | Role |
|---|---|
| `w1-win32u-vulkan-soname.patch` | **Applied by default** (`VULKAN_MODE=without` is the script default; also selectable via `--vulkan-soname-fallback`). CrossOver compiles `dlls/win32u/vulkan.c` even when configure finds no libvulkan/MoltenVK, leaving `SONAME_LIBVULKAN` undefined; this supplies the fallback define so the build compiles at all. |
| *(none — see below)* | `maplestory-cx26-message-wait-handoff.patch` is **deleted, not merely unapplied.** |

### Removed obsolete patches

`cyder-ntdll-query-directory-object-trace.patch` and
`obsolete/cyder-ntdll-frame-walk-guard.patch` were kept for a while only so
`remove_obsolete_patch()` in `build-wine.sh` could reverse them out of a build
tree that still carried the old code. As of September 2026 the persisted tree
at `build/cx26/sources/wine` already carries the current patches (`cyder QDO
optnone` marker, `if (!func) break;` guard), so there is nothing left to
reverse, and the two files were deleted. The `remove_obsolete_patch()` calls
in `build-wine.sh` no-op cleanly on a missing file and were left in place.

### Why `maplestory-cx26-message-wait-handoff.patch` is gone

Upstream Cyder applies it to every CX26 build (its comment claims it is "not a
MapleStory-only patch"). On this engine it is the cause of the game freeze: it
makes `wait_message()` skip `NtWaitForMultipleObjects` whenever
`process_driver_events()` returned `TRUE`, and on macOS Cocoa mouse-move and
window events make that happen constantly, so the main thread spins instead of
blocking and deadlocks on any UI or menu click. Reverting it is what fixed the
click hangs.

It is game-specific to MapleStory and this engine does not need it, so the file
is not kept in the repo at all. If some future change appears to want it, copy
it from `cyder-wine-engine/patches/` and retest UI/menu clicking specifically
before trusting it.

`build-wine.sh` previously tried to apply this patch and `w1` after both were
deleted from the repo, which aborted any build from a clean source tree.
`apply_gamma_patch()` now fails loudly on a missing file, and
`remove_obsolete_patch()` treats a missing obsolete patch as "nothing to
reverse".

### Filenames

11 patches keep their `cyder-` prefix from the upstream pipeline this repo was
forked from. They are referenced by exact filename in `build-wine.sh` and
`config/engine-release.json`; the names are provenance, not branding, and are
deliberately left alone by the GAMMA rename.
