# Missing artifacts

## Server-side (Track A) — resolved ✅

`ycsb-0.12.0`, `ycsb-0.18.0-SNAPSHOT`, and `HiBench2` were fetched and added under
`~/artifacts/{ycsb-0.12.0,ycsb-0.18.0-SNAPSHOT,HiBench2}/` (as installed directories, each also
containing the original experiment result dirs — see below). Clean tarballs (installation only,
experiment result dirs and `.git`/`.m2` excluded) were built into `~/artifacts/binaries/`:

```
ycsb-0.12.0.tar.gz          345 MB
ycsb-0.18.0-SNAPSHOT.tar.gz   6.6 MB
HiBench2.tar.gz              896 MB   (HiBench's own .git history — 646 MB — and .m2 cache — 120 MB
                                       — were excluded; it isn't needed to run bin/run_all.sh)
```

`python3 generate.py` now reports **0 of 13 server-side bugs missing artifacts** — every
`run_experiment.sh` is unblocked.

Regenerate this yourself if you re-fetch a cleaner copy: the exclude patterns live in the shell
history / at the top of this repo's provisioning — see `final_artifact`'s git history, or just
rebuild with `tar czf binaries/<name>.tar.gz --exclude='<name>/<result-dir-glob>' <name>` from
`~/artifacts/`.

### Bonus find: real historical result data

The three directories the versions came in weren't clean installs — they still had the actual
`<BUGNUM>_baseline/`, `<BUGNUM>_r<N>/` output directories from when these bugs were originally run
on the real (4-slave-node) EC2 cluster: raw YCSB `-s` status logs, per-host instrumentation
`collect` dumps, everything. These are now copied into **10 of the 13** bug folders as
`<bug-id>/experimental_results/{baseline,r1,r2,...}/` (see each bug's README) — meaning those 10
bugs' Det?/Succ?/Max%/read/write/mem/lat numbers can be checked directly against real prior output
without running Docker at all. `cassandra-13004`, `hbase-3403`, `hbase-3627` don't have data in
these three tools' directories (Cassandra's own `ycsb-0.12.0/cassandra_bug`/`cassandra_round1`
dirs turned out to be either empty or bound to `hbase094`/a different bug, not real Cassandra CQL
runs — not copied to avoid mislabeling; hbase-3403/3627 use `ycsb-0.1.4`, already covered by
`bm_instrument`'s own checked-in logs per `hbase-3627/README.md`).

**Note on cluster size:** the historical `.result` filenames encode 4 distinct slave IPs
(`172.31.17.254`, `172.31.18.101`, `172.31.25.246`, `172.31.26.151`) — the original cluster had (at
least) 4 slave nodes, i.e. 5+ nodes total including whatever ran the driver scripts. This Docker
packaging now runs **1 master + 3 slaves (4 nodes total)** — close to, but not an exact match of,
that historical topology (per explicit request; see `final_artifact/README.md` "Design choices").
Raw overhead percentages from a fresh run won't be numerically identical to the archived
`experimental_results/` regardless of exact slave count, only qualitatively comparable — bug
reproduction itself should be unaffected. `NUM_SLAVES` in `generate.py` is the one place to edit if
you want a different count.

## Android (Track B) — see ANDROID_README.md

Tracked separately now that Track B packaging is underway — the Android NDK (needed to recompile
the native agent per-round) is the one outstanding gap there; dex2jar and the instrumentation
tool's Android-branch source (with `CommandLine.java`) turned out to already be present under
`~/artifacts/dex2jar/` and `~/artifacts/bm_instrument8/`, respectively — see `ANDROID_README.md`
for full detail.

## Ambiguous (not missing, still a call for you to make)

**`hadoop-3.0.0-SNAPSHOT.tar.gz` vs `hadoop-3.0.0-SNAPSHOT-new.tar.gz`** — both already vendored,
both extract to the identical top-level directory name `hadoop-3.0.0-SNAPSHOT/`, nothing in the
checked-in scripts distinguishes which was actually used for YARN-1458. `manifest.py` defaults to
the non-`-new` one. If that doesn't reproduce YARN-1458's symptom, point `yarn-1458` at the
`-new` build instead (rename/symlink it to `hadoop-3.0.0-SNAPSHOT.tar.gz`) and re-run
`python3 generate.py`.
