# Android (Element) bug reproduction — Track B

Companion to `README.md` (the server-side track; see its "Upstream repos" section for the
[`bm_instrument`](https://github.com/yifan19/clods-instrumenter),
[`Python-Instrumentation`](https://github.com/yifan19/Python-Instrumentation), and
[`synapse`](https://github.com/yifan19/synapse) links). Covers the 5 packageable Android bugs from
`bm_instrument`'s corpus: `element-516`, `element-5038`, `element-6782`, `element-7516`,
`element-7643` (a 6th, `element-2143`, has no folder/APK anywhere in this checkout — stubbed).

## ⚠️ Status: generated, not device-tested; one real gap (not just "untested")

Same authoring-environment caveat as the server track (no way to `docker build`/run here), **plus**
one thing that's a genuine content gap, not just "unverified": the original production pipeline's
native agent source (`~/Dex/agent/agent_element.cpp`, referenced by
`bm_instrument8/run.py`/`run.sh`) is **not present anywhere in this checkout** — searched
exhaustively, including git history of every local repo. What *is* available and vendored instead:

| Needed | What's vendored | Where from |
|---|---|---|
| Offline APK bytecode patching (dex2jar + `CommandLine`) | ✅ Full pipeline, matches the actual production script | `~/artifacts/dex2jar/` (source repo) + `~/artifacts/bm_instrument8/` (has `CommandLine.java`, absent from `bm_instrument/main` — this is `bm_instrument`'s **`android`** git branch, `git log origin/android` in that repo) |
| Native agent to hot-load a patched class into a running process | ⚠️ Different implementation, not the original | `~/artifacts/ARTTI_instrument/agent/` — a separate, self-contained JVMTI **breakpoint** agent (reads a `.btm` plan, sets breakpoints directly, no dex2jar/live-redefine involved at all). This is NOT `agent_element.cpp` — it's a different technique that happens to solve the same problem (getting per-round instrumentation onto a running Android/ART process) |
| Compiling that agent | ❌ Missing — **Android NDK** (Makefile expects `aarch64-linux-android28-clang++`) | not present anywhere on this machine |
| A working fallback so `run_experiment.sh` doesn't just fail | ✅ One generic prebuilt `libagent.so` | `bm_instrument/android_benchmarking/libagent.so` |

**Practical effect:** `run_experiment.sh` can always do step 1 (offline dex2jar+CommandLine patch —
fully reproduces the actual bytecode change made for each round, inspectable under `work/round<N>/
out/*.dex` regardless of NDK availability) and step 3 (drive UI + collect logcat). Step 2 (live
attach to hot-swap that patched class into the running app) needs either `$ANDROID_NDK` set to a
real NDK install (then it builds ARTTI's agent from a `.btm` plan auto-converted from this round's
`.properties` files — lossy in places, see `android-common/lib/properties_to_btm.py`'s docstring)
or falls back to the generic prebuilt agent (attach mechanism only, its breakpoints won't match
this round's plan). **If you have the actual `agent_element.cpp`, that's the one artifact worth
fetching to close this gap for real** — everything else here is either vendored or has a working
substitute.

## Prerequisites

- Docker (`docker build android-common`) for the offline-patching step.
- A connected arm64-v8a Android device or emulator with USB debugging enabled, reachable via
  `adb devices`, for the on-device steps (install, drive UI, attach, logcat). This is **not**
  something the Docker image provides — `adb` in the container talks to a device/emulator that
  must already be reachable (physical device passed through, or `adb connect host:port` to a
  network-reachable emulator). Full Android emulation-in-Docker (nested KVM, nested virtualization)
  was judged out of scope here — most artifact-evaluation environments won't have hardware
  acceleration for it anyway.
- Android NDK (optional — only for full per-round agent rebuilds, see gap above).

## Quick start

```bash
cd final_artifact && ./fetch_data.sh   # once, after cloning — pulls APKs/jars/dex2jar from S3
cd element-516                          # or any other element-<bug>
./run_experiment.sh
```

No missing binaries block any of the 5 bugs — every bug's own pre-built APK is vendored (on S3,
see `../DATA.md`; in this checkout, symlinked from `bm_instrument/element-bugs/<bug>/results/`),
and `android-common/` vendors everything else needed for the offline patching step.

## What's vendored where

- `android-common/dex2jar/` — ready-to-run `d2j-dex2jar.sh`/`d2j-jar2dex.sh` + prebuilt `lib/*.jar`
  (20 MB). `android-common/dex2jar-src/` — the true dex2jar source (5 MB; excludes ~1 GB of stale
  decompiled-APK working directories that were sitting alongside it in `~/artifacts/dex2jar/`).
- `android-common/blameMasterInstrument-android.jar` — prebuilt, **includes `CommandLine.class`**
  (confirmed via `unzip -l`) — this is the exact jar needed for offline patching, no rebuild
  required. `android-common/bm_instrument-android-src/` — its source (= `bm_instrument`'s `android`
  git branch, also identical to `bm_instrument8/src/`).
- `android-common/agent-src/` — ARTTI_instrument's `agent.cpp`/`Makefile`/`generate_agent.py` +
  one generic prebuilt `libagent.so` fallback.
- Each `element-<bug>/apk/` — symlinked to that bug's real pre-built, working APK (not rebuilt from
  `element-android` source — rebuilding Element itself from Gradle is not needed for reproduction
  since the base APK is already captured).
- Each `element-<bug>/experimental_results/` — the real historical logcat captures
  (`baseline.txt`, `round1.txt`, ...) from when this bug was originally run. Grep these for
  `DEADBEEF`/`CLODS` to check Det?/Succ? without touching a device at all.
- Each `element-<bug>/plans/round<N>/<id>.properties[.disabled]` + top-level
  `plans/symptom.properties` — same layout the server-side bugs use (see `README.md`'s
  "Instrumentation plan layout"), reorganized from the original
  `round<N>/<round>_<id>_instrumentation.properties` naming (which also repeated
  `symptom.properties` byte-for-byte into every round — verified identical, so de-duplicated here).

## Naming trap carried over from the server-side README

`element-5038`'s results-table row is labeled **"5132"** — that's the upstream PR number that got
reverted to *create* the bug, not this bug's own issue number. Don't look for `element-5132`.

For a phone+server, step-by-step walkthrough of all 5 bugs (including this one, consistently
labeled `5132` there to match the results table) see `EXPERIMENT_GUIDE.md`.
