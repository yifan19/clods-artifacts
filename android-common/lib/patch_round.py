#!/usr/bin/env python3
"""Offline dex2jar <-> CommandLine <-> jar2dex patching, adapted near-verbatim from
bm_instrument8/run.py (the checked-in copy of the actual pipeline used to produce this corpus's
Android results — see android-common's README for provenance). Only the hardcoded /home/ubuntu
paths were parameterized; the unpack -> per-class dex2jar -> CommandLine bytecode splice ->
jar2dex logic is unchanged.

Usage:
  patch_round.py --apk <base.apk> --plan <round_dir> --workdir <dir> [--dex2jar-dir DIR]
                  [--instrument-jar JAR]

Output: <workdir>/out/<i>.dex for each instrumented class (i = index into the plan's class set),
plus <workdir>/patch_manifest.json mapping each output dex back to the class + original dex it
replaces, for build_agent.sh / run_experiment.sh to push onto the device.
"""
import argparse
import glob
import hashlib
import json
import os
import shutil
import subprocess
import sys

import javaproperties


def run(cmd, **kw):
    print("+ " + cmd)
    subprocess.run(cmd, shell=True, check=True, **kw)


def gen_class_set(plan_dir):
    classes = set()
    for f in glob.glob(os.path.join(plan_dir, "*.properties")):
        if f.endswith(".disabled"):
            continue
        with open(f) as fh:
            data = javaproperties.load(fh)
        classes.add(data["className"].replace(".", "/"))
    return classes


def class_to_dex_map(apk_unpack_dir, d2j_dex2jar):
    """Decompiles every dex in the unpacked APK once, returns {class/path: dexNN} (no extension)."""
    cache_path = os.path.join(apk_unpack_dir, ".class2dex.json")
    cache = {"data": {}, "hashes": {}}
    if os.path.exists(cache_path):
        with open(cache_path) as f:
            cache = json.load(f)
    mapping, hashes = cache["data"], cache["hashes"]

    for dex_file in glob.glob(os.path.join(apk_unpack_dir, "*.dex")):
        dex_name = os.path.splitext(os.path.basename(dex_file))[0]
        md5 = hashlib.md5(open(dex_file, "rb").read()).hexdigest()
        if hashes.get(dex_name) == md5:
            continue
        hashes[dex_name] = md5
        run('"%s" "%s.dex"' % (d2j_dex2jar, os.path.join(apk_unpack_dir, dex_name)),
            cwd=apk_unpack_dir)
        run("unzip -o -q %s-dex2jar.jar -d %s" % (dex_name, dex_name), cwd=apk_unpack_dir)
        extracted = os.path.join(apk_unpack_dir, dex_name)
        for root, _, files in os.walk(extracted):
            for fn in files:
                if not fn.endswith(".class"):
                    continue
                rel = os.path.relpath(os.path.join(root, fn), extracted)
                mapping[os.path.splitext(rel)[0]] = dex_name

    with open(cache_path, "w") as f:
        json.dump({"data": mapping, "hashes": hashes}, f)
    return mapping


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", required=True)
    ap.add_argument("--plan", required=True, help="round directory containing .properties files")
    ap.add_argument("--workdir", required=True)
    ap.add_argument("--dex2jar-dir", default="/opt/dex2jar")
    ap.add_argument("--instrument-jar", default="/opt/blameMasterInstrument-android.jar")
    args = ap.parse_args()

    d2j_dex2jar = os.path.join(args.dex2jar_dir, "d2j-dex2jar.sh")
    d2j_jar2dex = os.path.join(args.dex2jar_dir, "d2j-jar2dex.sh")

    unpack_dir = os.path.join(args.workdir, "apk_unpack")
    out_dir = os.path.join(args.workdir, "out")
    patched_out_dir = os.path.abspath(os.path.join(args.workdir, "patched_classes"))
    if os.path.isdir(unpack_dir):
        shutil.rmtree(unpack_dir)
    os.makedirs(unpack_dir)
    os.makedirs(out_dir, exist_ok=True)
    os.makedirs(patched_out_dir, exist_ok=True)

    run('unzip -o -q "%s" -d "%s"' % (args.apk, unpack_dir))

    class_set = sorted(gen_class_set(args.plan))
    if not class_set:
        sys.exit("no classes found in %s (no non-.disabled .properties files?)" % args.plan)

    class2dex = class_to_dex_map(unpack_dir, d2j_dex2jar)

    manifest = []
    for i, cls in enumerate(class_set):
        dex_name = class2dex.get(cls)
        if dex_name is None:
            print("WARNING: class %s not found in any dex of %s — skipping" % (cls, args.apk),
                  file=sys.stderr)
            continue
        class_dex_dir = os.path.join(unpack_dir, dex_name)

        run('java -Dbminstrument.outdir="%s" -cp "%s" ca.uoft.drsg.bminstrument.CommandLine -i "%s" "%s"'
            % (patched_out_dir, args.instrument_jar, args.plan, class_dex_dir))
        # CommandLine writes the patched .class to <patched_out_dir>/new<basename>.class
        # (see bm_instrument-android-src's Transformer.java; the original hardcoded /data/, which
        # only works inside the project's own Docker container running as root)
        patched = glob.glob(os.path.join(patched_out_dir, "*%s.class" % os.path.basename(cls)))
        if not patched:
            print("WARNING: CommandLine did not produce a patched class for %s" % cls, file=sys.stderr)
            continue

        stage = os.path.join(args.workdir, "stage_%d" % i)
        target_dir = os.path.join(stage, os.path.dirname(cls))
        os.makedirs(target_dir, exist_ok=True)
        shutil.copy2(patched[0], os.path.join(target_dir, os.path.basename(cls) + ".class"))
        jar_path = os.path.join(stage, "%d.jar" % i)
        run("jar -cf %s -C %s ." % (jar_path, stage))
        run('"%s" --force "%s" -o "%s/%d.dex"' % (d2j_jar2dex, jar_path, out_dir, i))

        manifest.append({"index": i, "class": cls, "original_dex": dex_name,
                          "patched_dex": "out/%d.dex" % i})

    with open(os.path.join(args.workdir, "patch_manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("patched %d/%d classes; manifest at %s"
          % (len(manifest), len(class_set), os.path.join(args.workdir, "patch_manifest.json")))


if __name__ == "__main__":
    main()
