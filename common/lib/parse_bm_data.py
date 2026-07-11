#!/usr/bin/env python3
"""Parse blameMasterInstrument's raw /data ring-buffer dump files.

This is the same script as bm_instrument-src/scripts/parse_bm_data.py (inside
common/bm_instrument-src.tar.gz), kept here too so it's runnable straight against a bug's
<bug-id>/results/<label><round>_<host>_data/ directory without unpacking that tarball first. See
common/bm_instrument-src's USER_GUIDE.md section 7 for the full derivation of the format below from
RingBufferInternal.java / LogEvent.java. Each file is zero or more 16-byte, big-endian log-event
records —

    offset 0   8 bytes  int64  id      probe ID from the .properties plan (can be negative)
    offset 8   8 bytes  int64  value   raw captured value, a timestamp, or (for strategy=stackTrace
                                        probes only) a *stack ID* -- not the stack trace itself

— followed, once, by a trailing block: the process's per-file stack-trace hashtable
(RingBufferInternal.persistStackTrace()). Every strategy=stackTrace probe hit is deduped through an
in-memory HashMap<String, Long> keyed by the full call-stack text, and it's *that table* -- not the
individual hits -- that gets flushed here, one entry per unique stack:

    8 bytes  int64  stack_id   always >= 0 (HashMap value, assigned 0, 1, 2, ... per unique stack)
    N bytes  UTF-8  stack text the frames, '\\n'-joined, '\\n'-terminated -- no length prefix

The on-disk format has no length prefix separating one stack-text entry from the next entry's
8-byte stack_id, and no record count separating the log-event region from this trailing block --
neither is recoverable exactly without extra information. This script recovers both boundaries
heuristically:

  - log-event region end: the first 8 bytes that don't look like a plausible probe ID (see
    --plans, or the default "small integer" heuristic below) ends the region.
  - stack-table entry boundaries: a real stack_id is small and non-negative, so its high 7 bytes
    are always 0x00 -- a run that essentially never occurs inside genuine stack-trace text (which
    is why it's a safe boundary marker in practice, not because the format guarantees it).

Usage:
    python3 parse_bm_data.py /data/                                   # human-readable summary
    python3 parse_bm_data.py /data/some_thread_0_1699999999999         # a single dump file
    python3 parse_bm_data.py --plans path/to/round1 /data/ --format csv > round1.csv
    python3 parse_bm_data.py --selftest                                # round-trip a synthetic file
"""
import argparse
import csv
import json
import os
import sys

RECORD_SIZE = 16
# Default heuristic bound for "does this look like a probe ID" when no --plans is given.
# Every ID seen across this repo's plan files is a small int (single/triple digit, occasionally
# negative for entry probes) -- 1_000_000 is deliberately generous headroom, not a measured limit.
DEFAULT_ID_BOUND = 1_000_000


def _looks_like_id(raw8: bytes, bound: int = DEFAULT_ID_BOUND) -> bool:
    val = int.from_bytes(raw8, "big", signed=True)
    return -bound <= val <= bound


def parse_records(data: bytes, known_ids=None):
    """Split `data` into (records, tail). records is a list of (id, value) ints.

    Even with --plans (known_ids), a *real* probe ID can numerically collide with a stack_id in
    the trailing hashtable -- stack IDs are always small and non-negative, assigned starting from
    0, and 0 (or 1, 2, ...) is also a very plausible real probe ID. Accepting an 8-byte field as a
    record id uses the strict `known_ids` set when given (else the generic small-int heuristic);
    but *disambiguating* it from a stack_id that happens to pass that same test uses a one-record
    lookahead against the looser small-int heuristic, not `known_ids` -- the field right after a
    real last record is legitimately the start of the (also small, non-negative) stack-trace tail,
    so requiring *it* to be a specific known id would wrongly reject every file that ends with a
    stack-trace section. This narrows, but -- per the module docstring -- does not eliminate, the
    ambiguity: a coincidental run of several small numbers right at the true boundary can still
    fool it either way.
    """
    def accepts(raw8: bytes) -> bool:
        if known_ids is not None:
            return int.from_bytes(raw8, "big", signed=True) in known_ids
        return _looks_like_id(raw8)

    records = []
    offset = 0
    n = len(data)
    while offset + RECORD_SIZE <= n:
        id_bytes = data[offset:offset + 8]
        if not accepts(id_bytes):
            break
        # Nothing left to disambiguate with right at EOF -- accept the last record optimistically.
        remaining_after = n - (offset + RECORD_SIZE)
        if remaining_after >= RECORD_SIZE:
            next_id_bytes = data[offset + RECORD_SIZE:offset + RECORD_SIZE + 8]
            if not _looks_like_id(next_id_bytes):
                break
        id_ = int.from_bytes(id_bytes, "big", signed=True)
        value = int.from_bytes(data[offset + 8:offset + 16], "big", signed=True)
        records.append((id_, value))
        offset += RECORD_SIZE
    return records, data[offset:]


def parse_stack_tail(tail: bytes):
    """Recover {stack_id: stack_text} from the trailing hashtable block.

    Boundary = a run of 7 zero bytes (the sign-extended high bytes of a small non-negative
    stack_id). On a match, the reader jumps a full 8 bytes past it -- not 1 -- so a stack_id of
    exactly 0 (all 8 bytes zero) can't produce a spurious second "boundary" one byte later.
    """
    boundaries = []
    i = 0
    n = len(tail)
    while i <= n - 7:
        if tail[i:i + 7] == b"\x00" * 7:
            boundaries.append(i)
            i += 8
        else:
            i += 1

    entries = []
    for idx, start in enumerate(boundaries):
        text_start = start + 8
        text_end = boundaries[idx + 1] if idx + 1 < len(boundaries) else n
        stack_id = int.from_bytes(tail[start:start + 8], "big", signed=False)
        text = tail[text_start:text_end].decode("utf-8", errors="replace")
        entries.append((stack_id, text))
    return entries


def load_plan_ids(plan_dir: str):
    """Parse a round's *.properties (skipping .disabled) into {id: {className, methodName, strategy}}."""
    import javaproperties  # optional dep; fall back to a tiny manual parser if unavailable
    ids = {}
    for name in sorted(os.listdir(plan_dir)):
        if not name.endswith(".properties"):
            continue
        path = os.path.join(plan_dir, name)
        with open(path, "r") as f:
            props = dict(javaproperties.load(f))
        if "ID" not in props:
            continue
        ids[int(props["ID"])] = {
            "className": props.get("className", ""),
            "methodName": props.get("methodName", ""),
            "strategy": props.get("strategy", "before"),
        }
    return ids


def _load_plan_ids_no_deps(plan_dir: str):
    ids = {}
    for name in sorted(os.listdir(plan_dir)):
        if not name.endswith(".properties"):
            continue
        props = {}
        with open(os.path.join(plan_dir, name), "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                props[k.strip()] = v.strip()
        if "ID" not in props:
            continue
        ids[int(props["ID"])] = {
            "className": props.get("className", ""),
            "methodName": props.get("methodName", ""),
            "strategy": props.get("strategy", "before"),
        }
    return ids


def discover_data_files(path: str):
    if os.path.isfile(path):
        return [path]
    files = []
    for name in sorted(os.listdir(path)):
        full = os.path.join(path, name)
        if not os.path.isfile(full):
            continue
        # Transformer's post-instrumentation bytecode debug dumps -- not ring-buffer data.
        if name.startswith("new") and name.endswith(".class"):
            continue
        files.append(full)
    return files


def parse_dump(files, known_ids=None):
    """Returns a list of per-file dicts: {file, records: [(id, value)], stacks: {stack_id: text}}."""
    results = []
    for path in files:
        with open(path, "rb") as f:
            data = f.read()
        records, tail = parse_records(data, known_ids)
        stacks = dict(parse_stack_tail(tail))
        results.append({"file": path, "records": records, "stacks": stacks})
    return results


def resolve(results, plan_ids):
    """Yield flat rows: (file, id, className, methodName, value, resolved_stack_or_None)."""
    for entry in results:
        for id_, value in entry["records"]:
            rule = plan_ids.get(id_) if plan_ids else None
            resolved = None
            if rule and rule["strategy"] == "stackTrace" and value in entry["stacks"]:
                resolved = entry["stacks"][value]
            yield (entry["file"], id_, rule["className"] if rule else "", rule["methodName"] if rule else "", value, resolved)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", nargs="?", help="a /data dump file, or a directory of them")
    ap.add_argument("--plans", help="round directory (*.properties) to cross-check IDs against and resolve stackTrace strategy probes")
    ap.add_argument("--format", choices=["text", "csv", "json"], default="text")
    ap.add_argument("--selftest", action="store_true", help="round-trip a synthetic file matching the on-disk format, then exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(0 if _selftest() else 1)

    if not args.path:
        ap.error("path is required unless --selftest is given")

    plan_ids = {}
    if args.plans:
        try:
            plan_ids = load_plan_ids(args.plans)
        except ImportError:
            plan_ids = _load_plan_ids_no_deps(args.plans)
        known_ids = set(plan_ids.keys())
    else:
        known_ids = None

    files = discover_data_files(args.path)
    results = parse_dump(files, known_ids)
    rows = list(resolve(results, plan_ids))

    if args.format == "json":
        out = [
            {
                "file": f, "id": i, "className": c, "methodName": m, "value": v,
                "resolved_stack": r,
            }
            for f, i, c, m, v, r in rows
        ]
        json.dump(out, sys.stdout, indent=2)
        print()
    elif args.format == "csv":
        w = csv.writer(sys.stdout)
        w.writerow(["file", "id", "className", "methodName", "value", "resolved_stack"])
        for f, i, c, m, v, r in rows:
            w.writerow([f, i, c, m, v, (r or "").replace("\n", " | ")])
    else:
        n_stacks = sum(len(e["stacks"]) for e in results)
        print(f"{len(files)} file(s), {len(rows)} log-event record(s), {n_stacks} unique stack trace(s)")
        for f, i, c, m, v, r in rows:
            label = f"{c}.{m}" if c else ""
            print(f"  [{os.path.basename(f)}] id={i} {label} value={v}")
            if r is not None:
                for line in r.rstrip("\n").split("\n"):
                    print(f"      at {line}")


def _selftest() -> bool:
    import struct

    def rec(id_, value):
        return struct.pack(">qq", id_, value)

    stack0 = "com.foo.Bar.baz(Bar.java:10)\ncom.foo.Caller.run(Caller.java:20)\n"
    stack1 = "com.foo.Bar.baz(Bar.java:10)\ncom.foo.Other.go(Other.java:5)\n"

    data = b"".join([
        rec(5, 42),            # a plain conditional probe
        rec(-1, 0),            # a stackTrace probe, first call site -> stack_id 0
        rec(-1, 1),            # same probe, a different call site -> stack_id 1
        struct.pack(">Q", 0) + stack0.encode("utf-8"),
        struct.pack(">Q", 1) + stack1.encode("utf-8"),
    ])

    known_ids = {5, -1}
    records, tail = parse_records(data, known_ids)
    ok = records == [(5, 42), (-1, 0), (-1, 1)]
    if not ok:
        print(f"FAIL: records mismatch: {records}", file=sys.stderr)
        return False

    stacks = dict(parse_stack_tail(tail))
    ok = stacks == {0: stack0, 1: stack1}
    if not ok:
        print(f"FAIL: stack tail mismatch: {stacks!r}", file=sys.stderr)
        return False

    # also confirm the no-known-ids heuristic path agrees on this synthetic file
    records2, tail2 = parse_records(data, known_ids=None)
    if records2 != records or tail2 != tail:
        print("FAIL: heuristic (no --plans) parse disagrees with known-ids parse", file=sys.stderr)
        return False

    # Now the tricky case the module docstring warns about: a real probe ID (0) that numerically
    # collides with the tail's first stack_id (also 0). The lookahead must still stop the
    # log-event region at the true boundary instead of eating into the stack-trace text.
    collide_stack = "org.apache.cassandra.db.Columns$Serializer.deserialize(Columns.java:443)\ncom.Caller.run(Caller.java:9)\n"
    collide_data = b"".join([
        rec(0, 7),              # a real probe whose ID happens to be 0
        rec(-1, 0),             # a stackTrace probe -> stack_id 0
        struct.pack(">Q", 0) + collide_stack.encode("utf-8"),
    ])
    collide_records, collide_tail = parse_records(collide_data, known_ids={0, -1})
    if collide_records != [(0, 7), (-1, 0)]:
        print(f"FAIL: id/stack_id collision mis-split the record region: {collide_records}", file=sys.stderr)
        return False
    collide_stacks = dict(parse_stack_tail(collide_tail))
    if collide_stacks != {0: collide_stack}:
        print(f"FAIL: id/stack_id collision corrupted the stack tail: {collide_stacks!r}", file=sys.stderr)
        return False

    print("PASS: parsed 3 records + 2-entry stack-trace hashtable correctly (with and without --plans), "
          "and correctly resolved a coincidental id/stack_id collision at the boundary")
    return True


if __name__ == "__main__":
    main()
