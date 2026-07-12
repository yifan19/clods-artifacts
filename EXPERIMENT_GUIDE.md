# Element bug reproduction — phone + server walkthrough

Step-by-step instructions for all 5 packageable Android (Element) bugs from
`ANDROID_README.md`'s corpus, grouped by the flow they exercise. This is the same
server (self-hosted Synapse, HTTPS via a self-signed CA — see "Part A") and the same physical/
emulated Android device (see "Part B") for every bug below; only the per-bug APK and instrumentation
plan change.

## Naming note — read this first

The results table in `bm_instrument/README.md` labels one of these bugs **`5132`**. That is the
upstream PR number that got *reverted* to create the bug, not the bug's own issue number — the
bug/branch/folder in this checkout are all `element-5038`. This guide uses **`5132`** throughout
(matching the table), but wherever you see it, the folder to `cd` into is `element-5038`. This is
carried over from (and stays consistent with) the existing note in `ANDROID_README.md`'s "Naming
trap" section and `element-5038/README.md`'s "Notes" section — nothing new to reconcile, just don't
go looking for a folder literally called `element-5132`.

One more naming trap, specific to this guide: `bm_instrument/element-bugs/element7516/results/
round2_python.txt` looks like it should be a Python-Instrumentation server-side capture (like
`element516/rerun/round2_python`), but it isn't — it's a plain Android logcat capture (`DEADBEEF:
START sendTextMessage` / `END RoomSyncHandler` lines), just one that happened to get the
`_python` suffix in its filename. Of the 5 bugs here, **only `element-516`'s round 2 has a real
server-side (Python-Instrumentation) hook** — see Part C.

## Categorization

| Label | Folder | Title | Flow | Rounds |
|---|---|---|---|---|
| `516` | `element-516` | Sent message not removed from local cache | send | 1, 2 |
| `6782` | `element-6782` | Foreground service not restarted | send | 1, 2 |
| `7516` | `element-7516` | Connection failure to old server version | send | 1, 2 |
| `5132` | `element-5038` | Notifications updated faster than database | notif | 1, 2, 3, 4 |
| `7643` | `element-7643` | Notifications are automatically dismissed | notif | 1, 2, 3, 5, 7, 9 (no 4/6/8) |

All 5 share the same installed package, `im.vector.app.debug` — **only one bug's APK can be on the
device at a time**. `run_experiment.sh` handles the uninstall/reinstall for you each run, but that
also wipes app data, so **you'll sign in again for every bug** (Part B's account still works, you
just re-enter it).

---

## Part A — Server setup (once)

Stand up the shared Synapse homeserver over HTTPS without registering a domain, using a
self-signed CA that Element's *debug* build (`vector-gplay-arm64-v8a-debug.apk`, what's vendored
for all 5 bugs) trusts via its `network_security_config.xml` `<debug-overrides>` block.

Scripts referenced below live in `android-common/https_setup/`.

```bash
# from your workstation, inside this repo
scp android-common/https_setup/*.sh <box>:~/
scp -r ../android/Python-Instrumentation/ <box>:/opt/synapse-clods/Python-Instrumentation
```
```bash
# on the EC2 box
sudo ./setup_https_homeserver.sh <public-ip>   # postgres, homeserver.yaml, self-signed cert, nginx
sudo ./start_synapse.sh                        # systemd service, plain (uninstrumented) mode
sudo ./setup_instrumented_synapse.sh           # rebuilds venv on py3.10 + bytecode lib, for element-516 only
```

Create two accounts (the notif bugs need a second account to actually trigger a push notification
— nothing else in this checkout messages you):
```bash
/opt/synapse-clods/venv/bin/register_new_matrix_user -c /opt/synapse-clods/homeserver.yaml http://localhost:8008
# repeat for a second account
```

## Part B — Phone setup (once)

```bash
scp <box>:/opt/synapse-clods/certs/ca.crt .
adb push ca.crt /sdcard/Download/
adb shell am start -a android.intent.action.VIEW \
    -d file:///sdcard/Download/ca.crt -t application/x-x509-ca-cert
```
Confirm the install prompt on-device ("CLODS test CA"). If that intent doesn't fire the installer
on your Android version: Settings → Security → Encryption & credentials → Install a certificate →
CA certificate → browse to `Download/ca.crt`.

Homeserver URL to enter in Element for every bug below: `https://<public-ip>:8448`.

---

## Part C — "send" experiments (516, 6782, 7516)

### element-516 — Sent message not removed from local cache

The only bug here with a server-side hook: round 2 pairs a client-side probe
(`plans/round2/1.properties`, `UnsignedData.getTransactionId`) with a Python-Instrumentation hook
on `synapse.events.utils.serialize_event` (already armed in
`Python-Instrumentation/constants/hooks.py`'s `USER_CALLABLES_TO_HOOK`). Run Synapse through the
driver instead of the plain service for this one:
```bash
# on the box
sudo systemctl stop synapse-clods
./run_instrumented_synapse.sh -d
```
```bash
# on your workstation
cd final_artifact && ./fetch_data.sh   # once, for all 5 bugs
cd element-516
./run_experiment.sh
# prompt: "launch the app manually now, sign in, and open a room, then press Enter"
```
Check results:
```bash
grep DEADBEEF results/round*.log                                    # client side
ssh <box> 'cd /opt/synapse-clods/Python-Instrumentation && python3 connect.py'  # server side, round 2 only
```
`DEADBEEF ID = 1,2,3,5,7` fires on every `serialize_event` call; `8` fires once per un-cleared
`$local.<uuid>` echo — that's the bug. When done: `./run_instrumented_synapse.sh -d stop`, then
`sudo systemctl start synapse-clods` to go back to the plain service before running any other bug.

### element-6782 — Foreground service not restarted

Client-only, no server hook.
```bash
cd element-6782
./run_experiment.sh
```
2 rounds. Symptom probe: `ActiveSessionHolder.getOrInitializeSession`. `grep DEADBEEF results/round*.log`.

### element-7516 — Connection failure to old server version

Client-only, no server hook (see the naming-trap note above — its `round2_python.txt` is just an
Android logcat capture, not a Synapse-side plan).
```bash
cd element-7516
./run_experiment.sh
```
2 rounds. Symptom probe: `DefaultSyncTask.downloadInitSyncResponse`. `grep DEADBEEF results/round*.log`.

---

## Part D — "notif" experiments (5132, 7643)

Both client-only — make sure you're back on the plain `synapse-clods` systemd service (not the
instrumented driver from element-516) before running either of these:
```bash
sudo systemctl start synapse-clods   # if not already running
```
Have your second account send a message into the shared room during/just before each run so a
real push notification lands on the test device — `drive_ui.sh` only taps compose/send on the one
device under test, nothing else here triggers a notification on its own.

### 5132 — Notifications updated faster than database (folder: `element-5038`)

```bash
cd element-5038
./run_experiment.sh
```
4 rounds. Symptom probe: `NotifiableEventProcessor.process`. `grep DEADBEEF results/round*.log`.

### 7643 — Notifications are automatically dismissed

```bash
cd element-7643
./run_experiment.sh
```
6 rounds, non-consecutive (1, 2, 3, 5, 7, 9 — no 4/6/8, that's not an error, carried over verbatim
from the original round folders). Symptom probe: `NotifiableEventProcessor.process`.
`grep DEADBEEF results/round*.log`.

---

## Recalibrating taps

`android-common/lib/drive_ui.sh`'s tap coordinates are calibrated to whatever screen resolution the
original experiments used. If messages aren't actually being sent on your device, run with
`ITERATIONS=1` and `adb exec-out screencap` to find the right coordinates, then override via
`TAP_COMPOSE_FIELD`/`TAP_START_TYPING`/`TAP_SEND` env vars.
