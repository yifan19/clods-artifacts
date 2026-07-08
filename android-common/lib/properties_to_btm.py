#!/usr/bin/env python3
"""Converts a round's blameMasterInstrument .properties plans into one ARTTI_instrument .btm plan.

This bridges two independently-developed instrumentation-plan formats found in this project:
bm_instrument's Java `.properties` (className/methodName/parameterTypes/lineNumber/byteCodeIndex/
strategy — used by the offline dex2jar+CommandLine path) and ARTTI_instrument's `.btm`
(CLASS/METHOD/AT/VARS/SIGNATURE/STACK — used by the JVMTI live-breakpoint agent path). See
../../ANDROID_README.md for why both paths are packaged.

Known lossy conversions, called out rather than silently guessed:
  - `.properties` has no return type, so SIGNATURE is only emitted when it can be inferred from
    context (never, currently) — omitted, meaning ARTTI's breakpoint matches by name only. If a
    class has overloaded methods sharing a name, this can over-match; check agent logcat output.
  - `.properties`' `variableName` has no declared type (TYPE_INT/OBJ/STR) — defaulted to the
    generic `obj` (TYPE_OBJ, calls hashCode()) since that's safe for reference types, which most
    of this corpus's captured variables are. Edit the generated .btm by hand if a probe's variable
    is a primitive int/double and you want its actual value logged, not a hashcode.
  - `byteCodeIndex` (Javassist's addressing) is copied directly into `AT` (JVMTI's addressing).
    Both address the same underlying bytecode for a standard (non-obfuscated) method body, so
    these should agree, but this has not been cross-validated bit-for-bit against a real ART
    runtime — treat a breakpoint that never fires as a signal to check this first.
"""
import glob
import os
import sys

import javaproperties  # vendored via android-common's pip install, see Dockerfile


def to_jvm_class_sig(dotted_name):
    return "L" + dotted_name.replace(".", "/") + ";"


def convert_one(props_path):
    with open(props_path) as f:
        p = javaproperties.load(f)
    lines = [
        "POINT: %s" % p.get("ID", "0").lstrip("-") or "0",
        "CLASS: %s" % to_jvm_class_sig(p["className"]),
        "METHOD: %s" % p["methodName"],
    ]
    if p.get("strategy") == "stackTrace":
        lines.append("STACK")
    lines.append("AT: %s" % p.get("byteCodeIndex", "0"))
    var_name = p.get("variableName")
    if var_name and var_name.lower() not in ("foo",):  # "foo" is bm_instrument's placeholder default
        lines.append("VARS: obj %s" % var_name)
    return "\n".join(lines) + "\n"


def convert_round(round_dir, out_path):
    plans = sorted(
        f for f in glob.glob(os.path.join(round_dir, "*.properties"))
        if not f.endswith(".disabled")
    )
    if not plans:
        sys.exit("no .properties files found in %s" % round_dir)
    blocks = []
    for i, plan in enumerate(plans):
        try:
            block = convert_one(plan)
        except Exception as e:
            print("skipping %s (conversion failed: %s)" % (plan, e), file=sys.stderr)
            continue
        blocks.append(block)
    with open(out_path, "w") as f:
        f.write("\n".join(blocks))
    print("wrote %s (%d/%d plans converted)" % (out_path, len(blocks), len(plans)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: properties_to_btm.py <round_dir> <out.btm>")
    convert_round(sys.argv[1], sys.argv[2])
