# HDFS-14135 — Unit test timeout by backlog size

**Not packaged.** Det=Y, Succ=N; this was reproduced as a plain unit test, not through this benchmark harness — no instrumentation folder exists.

This artifact only packages bugs that have a `server-bugs/instrumentation_*` folder in
`bm_instrument` — see `../../bm_instrument/ARTIFACT_EVALUATION.md` §5 for the full row-by-row
reproducibility map across all 24 bugs in the results table (13 packageable server-side bugs +
5 packageable Android bugs + this one and 3 others that aren't).
