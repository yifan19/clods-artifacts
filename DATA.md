# Data artifacts — what's in git vs. what's on S3

This repo (`final_artifact/`) is git-tracked for **scripts, configs, docs, and instrumentation
plans only** — everything large or binary is `.gitignore`d and lives in S3 instead, at
`s3://clods-artifacts/final_artifact-data/`. Run `./fetch_data.sh` once after cloning to pull it
all into place; individual bugs' `run_experiment.sh` won't find their binaries/APK without it.

```bash
git clone <this-repo>
cd final_artifact
./fetch_data.sh          # everything (a few GB, mostly binaries/)
# or just one bug:
./fetch_data.sh --bug hdfs-12638
```

## Layout

| Git path (`.gitignore`d) | S3 key under `final_artifact-data/` | What it is | Approx size |
|---|---|---|---|
| `binaries/*.tar.gz` | `binaries/*.tar.gz` | Vendored Hadoop/HBase/ZooKeeper/Cassandra/YCSB/HiBench installs | ~2.4 GB total |
| `<bug-id>/experimental_results/` | `experimental_results/<bug-id>.tar.gz` | Real historical run output (`write*.log`/`read*.log`/`*.result`/logcat captures), tarred per bug | 12 KB – 328 MB per bug |
| `element-<bug>/apk/*.apk` | `android/apks/element-<bug>.apk` | Pre-built, working Element APK for that bug | ~70–90 MB each |
| `common/blameMasterInstrument.jar` | `common/blameMasterInstrument.jar` | Pre-built server-side instrumentation tool jar | 2.7 MB |
| `common/m2-repo/` | `common/m2-repo.tar.gz` | Offline Maven cache for rebuilding the tool | 25 MB |
| `android-common/blameMasterInstrument-android.jar` | `android-common/blameMasterInstrument-android.jar` | Same tool, Android-branch build (has `CommandLine.class`) | 2.7 MB |
| `android-common/dex2jar/` | `android-common/dex2jar.tar.gz` | Ready-to-run dex2jar (prebuilt jars + launcher scripts) | 20 MB |
| `android-common/agent-src/libagent.so.prebuilt-generic` | `android-common/libagent.so.prebuilt-generic` | Generic prebuilt native-agent fallback | ~15 KB |

## Vendored source repos — archived as `git bundle`s, not flat copies

`common/bm_instrument-src/`, `android-common/bm_instrument-android-src/`, and
`android-common/dex2jar-src/` were originally flat file copies (no history) of
`~/artifacts/bm_instrument`, its `android` branch, and `~/artifacts/dex2jar`. Those are gone from
git now — replaced with **full-history `git bundle`s** at
`s3://clods-artifacts/final_artifact-data/source-bundles/`.

`bm_instrument.bundle` is **not optional** — `common/Dockerfile` builds
`common/bm_instrument-src` from source at image-build time (`mvn -o`, fully offline against
`m2-repo/`) rather than only trusting the prebuilt jar, so plain `./fetch_data.sh` (no flags)
already clones it into place for you:

```bash
./fetch_data.sh                          # clones common/bm_instrument-src automatically
cd common/bm_instrument-src && git checkout android   # only if you want the CommandLine.java branch
```

`dex2jar.bundle` and `ARTTI_instrument.bundle` **are** optional — nothing in either Dockerfile
builds from their source, only from prebuilt output — so they're gated behind `--source`:

```bash
./fetch_data.sh --source
git clone source-bundles/dex2jar.bundle android-common/dex2jar-src
```

| Bundle | Source repo | Branches/tags preserved | Fetched by default? |
|---|---|---|---|
| `bm_instrument.bundle` | `~/artifacts/bm_instrument` | `main`, `android` (has `CommandLine.java` — see `ANDROID_README.md`), `bug2_and_protobuf`, `deadline`, `plans`, `production`, `protobuf`, `protobuf_2`, `rules`, and their `origin/*` remotes | **Yes** — required by `common/Dockerfile` |
| `dex2jar.bundle` | `~/artifacts/dex2jar` | full upstream history incl. tags `v2.3`, `v2.4` | No — `--source` only |
| `ARTTI_instrument.bundle` | `~/artifacts/ARTTI_instrument` | `main` | No — `--source` only |

A `git bundle` is a single-file, clone-able snapshot of an entire repo (`git bundle create X --all`
/ `git clone X`) — this is what "archiving a git repo with its `.git` information" means in
practice: unlike a tarball of the working tree, it preserves every commit, branch, and tag, and a
fresh clone from it behaves exactly like cloning the original remote.

This wasn't done for `element-android`/`element-android2` (Element's own huge upstream git
history) — those weren't vendored into `final_artifact` in the first place (each Android bug ships
its already-built APK instead of Element source, see `ANDROID_README.md`), so there was nothing to
bundle here. If you want those archived too, `git bundle create element-android.bundle --all` from
`~/artifacts/element-android` the same way and upload it alongside the three above.

## Regenerating the S3 data (if you change the manifest or re-fetch a binary)

```bash
python3 generate.py && python3 generate_android.py   # regenerate the git-tracked scripts/plans
# then re-upload whatever changed, e.g.:
aws s3 sync binaries/ s3://clods-artifacts/final_artifact-data/binaries/
```

There's no single "reupload everything" script — `fetch_data.sh` is one-directional (S3 → local)
by design, since the data going up is meant to be a considered, occasional step, not something
that happens automatically on every `generate.py` run.
