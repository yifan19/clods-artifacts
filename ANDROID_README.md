# Android (Element) bug reproduction — Track B

Companion to `README.md` (the server-side track; see its "Upstream repos" section for the
[`bm_instrument`](https://github.com/yifan19/clods-instrumenter),
[`Python-Instrumentation`](https://github.com/yifan19/Python-Instrumentation), and
[`synapse`](https://github.com/yifan19/synapse) links). Covers the 5 packageable Android bugs from
`bm_instrument`'s corpus: `element-516`, `element-5038`, `element-6782`, `element-7516`,
`element-7643` (a 6th, `element-2143`, has no folder/APK anywhere in this checkout — stubbed).

## ⚠️ Status (updated 2026-07-14): both pipeline steps verified; only physical-device execution is untested

Earlier revisions of this doc described a real content gap: the original production agent
(`agent_element.cpp`) wasn't present in this checkout, and the offline dex2jar+CommandLine step
was marked "✅ full pipeline" without ever actually being run end-to-end. Both are now resolved:

| Needed | Status | Notes |
|---|---|---|
| Offline APK bytecode patching (dex2jar + `CommandLine`) | ✅ Verified end-to-end | All 16 round-plans across the 5 real vendored APKs patch cleanly (1/1 classes, 0 warnings) — see `ROUND_DEX_MAP.md`. Required fixing a real bug: `Transformer.java` hardcoded `FileOutputStream("/data/new<Class>.class")`, which only succeeds when the process can write to `/data` (true inside this project's own Docker container running as root; false on a plain host, where it throws `FileNotFoundException: Permission denied`). Fixed upstream (`Transformer.java` now reads the output dir from `-Dbminstrument.outdir`, default `/data` so in-container/on-device behavior is unchanged) — pushed to `bm_instrument`'s **`android_final`** branch (not `android` — that's what this repo's `bm_instrument-android-src` actually tracks; the old "`android` branch" claim was a stale doc error). `patch_round.py` also got two more fixes needed to run outside Docker: absolute-path resolution (a relative `--workdir`, exactly what `run_experiment.sh` passes, broke dex2jar's cwd-relative invocation) and lazy dex-file conversion (only decompiles as many of the APK's ~24 dex files as needed to locate the round's target class, instead of eagerly converting all of them). |
| Native agent to hot-load a patched class into a running process | ✅ Real production technique, generalized and wired in | `agent_element.cpp` was located — a `ClassFileLoadHook`/`RetransformClasses` live-redefine agent (reads a pre-pushed patched `.class` from the app's own private storage). Its hardcoded target class (`DefaultSyncTask`) matches `element-7516`'s round plans exactly, confirming it was written specifically for that bug, not as a generic template. Generalized into `android-common/agent-src/agent_retransform.cpp`: the target class and replacement-classfile path are now read from `Agent_OnAttach`'s `options` string at attach time (`class=<slash/Name>,file=<path>`) instead of being hardcoded, so **one build is reused across every round of every bug** — driven by `patch_manifest.json`'s new `patched_class` field. `android-common/lib/build_retransform_agent.sh` builds it; `push_and_attach.sh` pushes the agent + patched class into the app's private storage and runs `attach-agent`. Compiles cleanly with NDK r26b (`26.1.10909125` — installable via `apt-get install google-android-ndk-r26b-installer` on Ubuntu; matches the version hardcoded in `agent-src/generate_agent.py`'s original path). ARTTI_instrument's breakpoint-based agent (`agent.cpp`/`generate_agent.py`/`build_agent.sh`) is still vendored as an alternate technique but is no longer what `run_experiment.sh` uses by default. |
| End-to-end script logic | ✅ Verified (adb/device mocked) | The full generated `run_experiment.sh` (offline patch → build agent → push both files → attach) was dry-run with a stubbed `adb` and a real NDK build; completed with exit 0 for both rounds of `element-7516`, producing a valid classfile, a valid Dalvik dex, and a valid aarch64 `.so`. |
| Actual on-device retransform behavior | ❌ Not verified | No physical/emulated arm64-v8a device was available in this environment. The `attach-agent` options-string format (`<path>=<options>`, splitting only on the first `=`) matches documented Android platform behavior but was not exercised against a real running ART process. |

**Practical effect:** `run_experiment.sh` does the offline dex2jar+CommandLine patch (step 1,
`work/round<N>/out/*.dex` + `patched_classes/*.class`), builds+attaches the live retransform agent
(step 2, needs `$ANDROID_NDK`; skipped with a clear message otherwise), and drives UI + collects
logcat (step 3) — all verified except the final "does ART actually swap the bytecode" behavior,
which needs a real device.

## Prerequisites

- Docker (`docker build android-common`) for the offline-patching step.
- A connected arm64-v8a Android device or emulator with USB debugging enabled, reachable via
  `adb devices`, for the on-device steps (install, drive UI, attach, logcat). This is **not**
  something the Docker image provides — `adb` in the container talks to a device/emulator that
  must already be reachable (physical device passed through, or `adb connect host:port` to a
  network-reachable emulator). Full Android emulation-in-Docker (nested KVM, nested virtualization)
  was judged out of scope here — most artifact-evaluation environments won't have hardware
  acceleration for it anyway.
- Android NDK, for the live-attach step (`build_retransform_agent.sh`). Verified working with
  **r26b** (`26.1.10909125`) — on Ubuntu: `apt-get install google-android-ndk-r26b-installer`
  (installs to `/usr/lib/android-sdk/ndk/26.1.10909125`), then `export
  ANDROID_NDK=/usr/lib/android-sdk/ndk/26.1.10909125`. Also needs a JDK 8 install for `jvmti.h`/
  `jni.h` (`apt-get install openjdk-8-jdk`; `build_retransform_agent.sh` looks in
  `/usr/lib/jvm/java-8-openjdk-amd64/include` by default, override via `$JAVA_INCLUDE_DIR`).
  Without this, offline patching (step 1) still works — only the live-attach step is skipped.

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
- `android-common/agent-src/` — `agent_retransform.cpp` (the live-attach agent `run_experiment.sh`
  actually uses now, generalized from the real production `agent_element.cpp`, also vendored here
  for reference) + ARTTI_instrument's alternate breakpoint-based `agent.cpp`/`Makefile`/
  `generate_agent.py` + one generic prebuilt `libagent.so` fallback for that alternate path.
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
