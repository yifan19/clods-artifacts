#!/bin/bash
# Generalized from bm_instrument/android_benchmarking/element_send.sh — taps through Element's
# UI to send N messages. Tap coordinates are screen-resolution-specific (captured against whatever
# device the original experiments used) — override via env if your device's UI lands elsewhere;
# run once with ITERATIONS=1 and `adb shell input tap` by hand / `adb exec-out screencap` to
# recalibrate if messages aren't actually being sent.
set -euo pipefail
ITERATIONS="${ITERATIONS:-10}"
TAP_COMPOSE_FIELD="${TAP_COMPOSE_FIELD:-361 1511}"
TAP_START_TYPING="${TAP_START_TYPING:-361 1300}"
TAP_SEND="${TAP_SEND:-689 955}"
SLEEP_BETWEEN="${SLEEP_BETWEEN:-5}"

for i in $(seq "$ITERATIONS"); do
    adb shell input tap $TAP_COMPOSE_FIELD
    adb shell input tap $TAP_START_TYPING
    adb shell input tap $TAP_SEND
    sleep "$SLEEP_BETWEEN"
done
