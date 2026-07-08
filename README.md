# final_artifact — bug reproduction package

Two independent tracks, packaged for artifact evaluators who don't have the original toolchains
already set up:

- **This document** — server-side (HDFS, ZooKeeper, HBase, Cassandra, YARN), Docker-based.
- **`ANDROID_README.md`** — the 5 Android (Element) bugs, offline dex2jar-based patching + Docker
  for the build step, `adb` + a connected device for the on-device step.

## Server-side track

Dockerized, multi-container reproduction of the 13 server-side bugs from `bm_instrument`'s bug
corpus (original work used scripts internally)

## ⚠️ Status: generated, not yet Docker-smoke-tested

This was authored in an environment with **no Docker daemon available** — every file here
(Dockerfile, compose files, orchestration scripts) is a careful, source-grounded translation of
the original `benchmark_scripts/*.sh` cluster scripts, but `docker build`/`docker compose up` has
not actually been run end-to-end against any of these 13 bugs yet. Treat this as a strong first
draft: build the shared image once (`docker build ./common`) and smoke-test one bug (`hbase-3627`
or `hdfs-12638` are good first picks — both have real historical data to compare against, see
"Status" below) before trusting the rest. Please report back anything that breaks so the template
can be fixed once for all 13 folders.

## Layout

```
final_artifact/
├── manifest.py          the single source of truth: per-bug versions, driver, rounds, etc.
├── generate.py           materializes every <bug-id>/ folder from manifest.py — re-run any time
│                          you edit manifest.py or fetch a missing binary (see MISSING_ARTIFACTS.md)
├── binaries/              vendored tarballs (symlinked from ../binaries/). some tarballs was built from source...
├── common/                shared Docker image (JDK8, sshd, python2/3) + orchestration scripts,
│                          used by every bug's docker-compose.yml
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── blameMasterInstrument.jar     pre-built instrumentation tool (no Maven Central needed)
│   ├── bm_instrument-src/            ...and its full source, for evaluators who want to modify it
│   ├── m2-repo/                      ...and an offline Maven cache, so that rebuild doesn't need
│   │                                   internet either (`mvn -o -Dmaven.repo.local=/opt/m2-repo`)
│   └── lib/                          cluster_ctl.sh, run_n.sh, run_workload.sh, render_config.py, ...
└── <bug-id>/              one folder per bug, e.g. hdfs-12638/, zk-1900/, hbase-3627/
    ├── run_experiment.sh  THE single script to run the experiment
    ├── docker-compose.yml 4-container cluster (master + slave1 + slave2 + slave3) for this bug's versions
    ├── plans/              this bug's instrumentation plans, reorganized from
    │                        bm_instrument/server-bugs/instrumentation_*/ into round<N>/<id>.properties
    │                        (see "Instrumentation plan layout" below — same layout Android uses)
    ├── results/             populated by run_experiment.sh (empty until you run it)
    ├── experimental_results/  (10/13 bugs) real historical write*.log/read*.log/*.result output
    │                        from the original run — no Docker needed to inspect these
    └── README.md            bug-specific versions, JIRA link, missing-artifact flags, column mapping
```

13 bugs → 13 folders. 4 more (`hdfs-4261`, `hdfs-14135`, `hdfs-4558`, `hbase-4078` — all
`Det=N`/`Succ=N` or unit-test-only per the results table, with no `server-bugs/` folder to draw
from) get a stub `README.md` explaining why they aren't packaged, instead of being silently
omitted.

## This repo is git-controlled; the data isn't

`final_artifact/` is a git repo tracking scripts, Dockerfiles, docs, and instrumentation plans
only. Vendored binaries, historical `experimental_results/`, Android APKs, prebuilt jars, and the
offline Maven cache are `.gitignore`d and live in S3 instead — see `DATA.md` for the full layout
and why. **Fetch them once after cloning:**

```bash
git clone <this-repo> && cd final_artifact
./fetch_data.sh          # pulls everything from s3://clods-artifacts/final_artifact-data/
```

## Quick start

```bash
cd final_artifact/hbase-3627      # or any other bug folder
./run_experiment.sh               # THE single command — builds, deploys, runs baseline+rounds, collects
```

Requirements on the evaluator's machine: Docker + Docker Compose v2 (`docker compose`, not the
standalone `docker-compose` v1 binary — the generated compose files use the modern
`services:`/anchor syntax). Nothing else — no local JDK, no local Hadoop/HBase install, no Maven.

`docker build` **does** reach the internet, but only for OS packages (`apt-get install
openjdk-8-jdk openssh-server python2.7 ...` — see `common/Dockerfile`'s top comment for the
reasoning). It never downloads Hadoop/HBase/ZooKeeper/Cassandra/YCSB — those are 100% vendored,
pre-built binaries bind-mounted from `binaries/` at container-run time.

## Status: all 13 bugs fully local ✅

`ycsb-0.12.0`, `ycsb-0.18.0-SNAPSHOT`, and `HiBench2` were fetched and vendored — every bug's
`run_experiment.sh` now finds everything it needs in `binaries/` (`python3 generate.py` reports
0 missing across all 13). See `MISSING_ARTIFACTS.md` for exactly what was added and how the
tarballs were built (installation only — the huge `.git` history that came bundled with HiBench2
and every bug's leftover experiment-result directories were excluded from the deployable tarball).

**10 of the 13 bugs additionally ship `experimental_results/`** — the real historical
`write*.log`/`read*.log`/`*.result` output from when these bugs were originally run (found
alongside the vendored tool installs, copied in per-bug). You can compute Det?/Succ?/Max%/
read/write/mem/lat straight from that folder without touching Docker at all, if verifying the
published numbers is all you need. `hbase-3403`/`hbase-3627` (which don't have data in those three
installs) already have their own raw logs checked into `bm_instrument/server-bugs/
instrumentation_hbase3627/log.txt` + a bug-specific `parse.py`; `cassandra-13004` has no
historical raw data available anywhere in this checkout.

Every `run_experiment.sh` still checks for its own bug's required files before touching Docker and
refuses to start with a clear `[MISSING]` message if anything's absent, in case a `binaries/`
symlink gets broken later.

## Instrumentation plan layout (consistent across both tracks)

Every bug's `plans/` directory — server-side here, Android in `element-*/plans/` — uses the same
layout regardless of which original source format it came from:

```
plans/
├── symptom.properties     the final, confirmed probe for this bug as a whole (when one exists)
├── round1/
│   ├── <id>.properties            a candidate probe tried in round 1
│   ├── <id>.properties.disabled   ...tried and then disabled/abandoned
│   └── ...
├── round2/
│   └── ...
```

The two original source layouts differed (server-side: flat `r<N>_<id>.properties` files, no round
subdirectories; Android: `round<N>/<round>_<id>_instrumentation.properties`, already subdirectoried
but with a redundant round-prefix baked into the filename and `symptom.properties` duplicated
byte-for-byte into every round instead of stated once) — `generate.py`'s `copy_plans()` and
`generate_android.py`'s `generate_bug()` both reorganize their respective source into the layout
above on the way in. Files that aren't recognized plan files (raw logs, one-off parser scripts —
a handful of bugs had these mixed into their source plan directories) are preserved under
`experimental_results/legacy_local_logs/` rather than silently dropped or left cluttering `plans/`.

`common/lib/run_n.sh`'s `add <round>` reads `/plans/round<round>/*.properties` (skipping
`.disabled`) — if you hand-edit a bug's `plans/`, keep this layout or that script won't find your
plans.

## Design choices (and why)

- **Multi-container, not single-node — 1 master + 3 slaves.** Each bug's `docker-compose.yml`
  brings up `master` + `slave1` + `slave2` + `slave3` on a private compose network with real SSH
  between them (fixed keypair baked into the shared image — insecure by design, fine because the
  network is private and ephemeral; see the comment in `common/Dockerfile`). This mirrors the
  original EC2 cluster topology (coordinator + N slaves, `benchmark_scripts/*.sh` `ssh $slave ...`
  throughout) much more closely than a single pseudo-distributed container would — and 3 slaves
  specifically matches the 4 distinct slave IPs (`172.31.17.254`, `172.31.18.101`, `172.31.25.246`,
  `172.31.26.151`) encoded in the real historical `.result` filenames under `experimental_results/`
  (1 master + 3 slaves = 4 nodes total, consistent with the original cluster size). Slave count is
  controlled by `generate.py`'s `NUM_SLAVES` — every script reads `$SLAVE_HOSTS` rather than
  hardcoding names, so changing it is a one-line edit + `python3 generate.py`.
- **Daemon placement is a clean re-derivation, not a literal copy.** `master` runs
  NameNode/ResourceManager/HMaster/the sole Cassandra seed; the slaves run
  DataNode/RegionServer/ZooKeeper-ensemble-members. The original ad-hoc research scripts are not
  fully self-consistent about which host runs what (see comments in `manifest.py` for the specific
  bugs where this matters, e.g. `hdfs-4205`) — this artifact picks one clean, documented topology
  rather than trying to bit-for-bit replicate inconsistent historical SSH targets.
- **YCSB's Python-2 requirement:** every container has `python2.7` installed (symlinked to
  `python`/`python2`) via `apt-get`, so YCSB's `bin/ycsb` launcher runs unmodified regardless of
  which YCSB generation a given bug uses — no source patch needed.
- **One real bug fix carried into `common/lib/run_n.sh`:** the original
  `bm_instrument/script_archive/run_n.sh`'s `inject` branch hardcoded a search for a JVM named
  `namenode` in `jps` output, ignoring the app-name argument every caller actually passes. Flagged
  and fixed in the vendored copy — see the comment at the top of that file.
- **SSH env propagation:** `docker compose exec master ...` inherits the container's
  `environment:` automatically, but a plain `ssh slave1 ...` session does not by default. Fixed via
  `PermitUserEnvironment yes` + `~/.ssh/environment` populated at container start — see
  `common/Dockerfile` and `common/entrypoint.sh`.

## Regenerating after a manifest edit or a fetched binary

```bash
python3 generate.py
```

Idempotent — safe to re-run any time. It never touches `common/` (hand-authored) or
`bm_instrument/` (read-only source), only the 13 generated `<bug-id>/{docker-compose.yml,
run_experiment.sh, README.md, plans/}` and the `binaries/` symlinks.

## Full provenance / caveats

See `../bm_instrument/ARTIFACT_EVALUATION.md` for: the complete version matrix with citations into
`benchmark_scripts/master_*.sh`, the row-by-row reproducibility map against the full 24-bug results
table (this package covers the 13 server-side rows only — Android is a separate, non-Docker track,
see that document §4), and a fuller discussion of what "Det?/Succ?/#Iter/#SI/Max%/mem/lat" mean and
how much of each is/isn't automatically reproducible from raw logs versus needing a fresh run.
