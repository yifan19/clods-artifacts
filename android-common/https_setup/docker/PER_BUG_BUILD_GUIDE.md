# Per-bug Synapse images, real accounts, real HTTPS (clods-test.uk)

Companion to `README.md` / `setup.sh` in this folder. Those cover *one* Synapse instance for
local testing; this covers building one **tagged image per bug** (since `element-7516` needs an
old server version, the others don't) and standing the result up behind a real domain for
artifact evaluators, instead of the self-signed-CA approach used for on-device testing earlier.

## 1. Which bugs use which synapse version

Verified against the `android/synapse` checkout's own branches (`git log`, dates below):

| Bug | Branch | Synapse commit | Why |
|---|---|---|---|
| `516` | `develop` | `0621e8eb0` (2024-02-14, = upstream `develop` exactly) | current server |
| `6782` | `develop` | same | current server |
| `5132` (folder `element-5038`) | `develop` | same | current server |
| `7643` | `develop` | same | current server |
| `7516` | `bug10` | `6b097a3e1` (2022-10-17) | **"Connection failure to old server version"** — this is the one bug that actually needs an old server, hence its own branch |

So: build once from `develop`, tag it for the four bugs that share it, then check out `bug10` and
build a fifth, differently-tagged image for `7516`. If you intended a different bug to be "the odd
one out," swap which branch you checkout below — nothing else in this guide depends on which bug
maps to which branch.

## 2. Build + tag each image

```bash
cd android/synapse   # the repo itself, not a symlink -- see the note in ../../docker-compose.yml
                      # about why a symlinked build context silently drops files

git status --short   # confirm no uncommitted tracked changes before switching branches
git -C ../Python-Instrumentation status --short   # same, for the instrumentation checkout

# --- current version: 516, 6782, 5132, 7643 ---
git checkout develop
git -C ../Python-Instrumentation checkout element-516   # serialize_event armed -- 516's round2 plan
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION=3.10 \
    --build-context instrumentation=../Python-Instrumentation \
    -t clods-synapse:516 -t clods-synapse:6782 -t clods-synapse:5132 -t clods-synapse:7643 .

# --- old version: 7516 ---
git checkout bug10
git -C ../Python-Instrumentation checkout element-7516   # check_valid_filter armed
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION=3.10 \
    --build-context instrumentation=../Python-Instrumentation \
    -t clods-synapse:7516 .

git checkout develop   # leave the checkout back on the branch other tooling in this repo expects
```

One `docker build` with multiple `-t` flags produces one image with several tags — cheaper than
building the same commit 4 times. `PYTHON_VERSION=3.10` and `--build-context instrumentation=...`
matter for **all** these tags even though only `516` and `7516` actually use it at runtime (see
§3) — Python-Instrumentation gets baked into every image (harmless, unused, same layer either
way), so switching which bug is "the instrumented one" later never needs a rebuild, just a
different `SYNAPSE_INSTRUMENT` value at `docker run` time. `--build-context` is a real Docker
directory reference, not a git ref — whichever branch `../Python-Instrumentation` happens to have
checked out on disk at build time is what gets baked in, hence the explicit checkout before each
build above.

Confirm:
```bash
docker images clods-synapse
```

## 3. Run a bug's image, exposing 8008

`./run_bug.sh <bug>` automates this (stops whatever's running, starts the requested tag against
the shared `./data/`, sets `SYNAPSE_INSTRUMENT` automatically for `516`/`7516`, health-checks it)
— `./run_bug.sh 516`, `./run_bug.sh stop`, `./run_bug.sh status`. Manually, that's:
```bash
docker run -d --name clods-synapse-active \
    -p 127.0.0.1:8008:8008 \
    -v ~/clods/data:/data \
    -e SYNAPSE_INSTRUMENT=/opt/python-instrumentation/driver.py \
    clods-synapse:516        # swap the tag for whichever bug -- drop the -e for any bug other
                              # than 516/7516, they don't have a server-side hook to run
```
(`-v ~/clods/data:/data` — reuse the same `data/` dir `setup.sh` already generated a
`homeserver.yaml`/signing key in, so you're not regenerating config per bug. If you want each bug
fully isolated instead, use a separate `-v` target per tag, e.g. `~/clods/data-516`.)

To switch bugs: `docker rm -f clods-synapse-active`, then `docker run ...` again with the other
tag (or just `./run_bug.sh <other-bug>`, which does exactly that). Since they share `/data`, the
same `homeserver.yaml`/accounts/database carry over between bugs — only the server binary itself
changes. If you'd rather each bug got a clean database too, point `-v` at a fresh directory per tag
and re-run the `generate` step from `setup.sh` for that directory first.

## 4. Create user1 and user2

```bash
docker exec clods-synapse-active register_new_matrix_user \
    -u user1 -p <password1> --no-admin -c /data/homeserver.yaml http://localhost:8008
docker exec clods-synapse-active register_new_matrix_user \
    -u user2 -p <password2> --no-admin -c /data/homeserver.yaml http://localhost:8008
```
(Non-interactive form — `-u`/`-p`/`--no-admin` skip the prompts. Uses `registration_shared_secret`
from `homeserver.yaml`, same admin-bypass mechanism as before, works regardless of
`enable_registration`.)

## 5. Enabling an instrumented build, and reading the log buffer (516/7516)

### Enabling it

It's baked into the image at **build** time, not switchable per-run: whichever
`Python-Instrumentation` branch is checked out on disk when you run `docker build` (§2) is what
gets copied in, and that checkout's `constants/hooks.py` is the plan that ends up armed. There's no
way to pick a different hook against an already-built image — rebuild with the other branch
checked out instead.

Whether it actually *runs* is a separate, per-container toggle: the `SYNAPSE_INSTRUMENT` env var.
`./run_bug.sh 516` / `./run_bug.sh 7516` set it automatically; every other bug leaves it unset and
runs plain synapse. Manually:
```bash
docker run -d --name clods-synapse-active \
    -p 127.0.0.1:8008:8008 -p 127.0.0.1:8090:8090 \
    -v ~/clods/data:/data \
    -e SYNAPSE_INSTRUMENT=/opt/python-instrumentation/driver.py \
    clods-synapse:516
```
(`-p 127.0.0.1:8090:8090` — see "Reading the log buffer" below for why. Restricted to the host's
own loopback, not exposed beyond the machine it's running on.)

To confirm it's actually active: `docker logs clods-synapse-active` should show `Python
Instrumentor located at ...`, then (for `516`, since `serialize_event` gets hit during ordinary
sync traffic) a bytecode disassembly dump the moment `synapse.events.utils` is imported. **`7516`
specifically doesn't reliably show these prints in `docker logs`** — its older synapse's own
logging/daemonization setup appears to orphan Python's stdout buffer before it flushes. That's a
logging quirk, not a broken hook (`check_valid_filter` also just doesn't fire until a client
actually makes a filter-related request, unlike `serialize_event`) — use the log buffer below to
check instead, it isn't affected.

### Reading the instrumentation log buffer

Every hook fire gets appended to an in-memory list (`instrument_logs`) inside the running
container, served over a small TCP socket on port 8090 (`Python-Instrumentation/utils/
instrumentation.py`'s `start_server`) — send it anything, it replies with the current buffer as
a Python-repr'd list, then the list's length, then closes.

From your workstation (needs `-p 127.0.0.1:8090:8090` published, which `run_bug.sh` does
automatically for `516`/`7516`):
```bash
python3 android/Python-Instrumentation/connect.py
```
Or from inside the container, which always works regardless of what's published:
```bash
docker exec clods-synapse-active python3 /opt/python-instrumentation/driver.py -c "print(1)"  # sanity-only, doesn't read the buffer
docker exec clods-synapse-active python3 -c "
import socket
s = socket.socket()
s.connect(('localhost', 8090))
s.sendall(b'x')
print(s.recv(65536))
"
```

**Reading the output.** Each entry is `(thread_id, 'DEADBEEF ID =', <id>)` for a plain
before/after/stacktrace probe, matching the `id` values in the armed plan's
`instrumentation_rules` (`constants/hooks.py`). For `element-516`'s `serialize_event` plan
specifically, `ids 1,2,3,5,7` fire on *every* call (the branch-tracking probes), and `id 8` fires
once per real un-cleared `$local.<uuid>` echo — matching the historical capture at
`bm_instrument/element-bugs/element516/rerun/round2_python` (`EXPERIMENT_GUIDE.md` Part C has the
same fingerprint). Example buffer after some real traffic:
```
[(131628164079744, 'DEADBEEF ID =', 1), (131628164079744, 'DEADBEEF ID =', 2),
 (131628164079744, 'DEADBEEF ID =', 3), (131628164079744, 'DEADBEEF ID =', 5),
 (131628164079744, 'DEADBEEF ID =', 7), (131628164079744, '$local.41927b13-...', 8)]
```

The buffer is **plain in-memory state** — it resets to empty on every container restart (`./run_bug.sh
<bug>` restarting the same bug, or switching bugs entirely), and there's no persistence across
runs. If you need to keep a capture, save the connect.py output to a file yourself before
restarting/switching.

## 6. Real domain + nginx + Let's Encrypt (clods-test.uk)

This replaces the self-signed-CA approach from `EXPERIMENT_GUIDE.md` — worth it now that there's a
real registered domain, since evaluators' devices/browsers won't need a manually-installed CA to
trust it.

**DNS:** point `clods-test.uk` (and, if you want federation-style split ports later,
`clods-test.uk` again for `:8448`) at the AWS instance's public IP via an A record with whatever
registrar/DNS provider you registered it through.

**`server_name`:** Synapse bakes `server_name` into user IDs (`@user1:clods-test.uk`) and event
signing at generation time — it can't be changed later without effectively starting over. Since
the existing `synapse_build/data/homeserver.yaml` was generated with `server_name: "13.59.226.159"`
(the bare IP, from before the domain existed), **regenerate it** rather than editing that field:
```bash
rm -rf ~/clods/data && mkdir ~/clods/data
docker run --rm -v ~/clods/data:/data \
    -e SYNAPSE_SERVER_NAME=clods-test.uk -e SYNAPSE_REPORT_STATS=no \
    clods-synapse:516 generate
```
Then redo the listener/database/rate-limit patch from `setup.sh` against this fresh file, and
step 4 above (accounts are also tied to the old `server_name`, so `user1`/`user2` need
re-registering against the new config).

**nginx (on the host, not containerized):**
```nginx
server {
    listen 80;
    server_name clods-test.uk;
    location ~ ^(/_matrix|/_synapse/client) {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Host $host;
        client_max_body_size 50M;
        proxy_http_version 1.1;
    }
}
```
```bash
sudo tee /etc/nginx/sites-available/clods-test >/dev/null < above.conf
sudo ln -sf /etc/nginx/sites-available/clods-test /etc/nginx/sites-enabled/clods-test
sudo nginx -t && sudo systemctl reload nginx
```

**Certbot (Let's Encrypt — real, publicly-trusted cert, no evaluator-side CA install needed):**
```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot --nginx -d clods-test.uk
```
`certbot --nginx` edits the site config in place to add the `listen 443 ssl` block and cert paths,
and sets up auto-renewal. Evaluators then just point Element at `https://clods-test.uk` — no
certificate warnings, no manual trust step, works the same as any other public homeserver.

## What to hand evaluators

- Homeserver URL: `https://clods-test.uk`
- Two pre-registered accounts (`user1`/`user2`) with whatever passwords you set in step 4
- Which image tag (bug number) is currently running, since switching requires a `docker rm -f` +
  `docker run` with a different tag (step 3) — evaluators testing multiple bugs in one sitting will
  see the server briefly go down between switches unless you run multiple tagged containers on
  different ports and front them with separate nginx `server_name`/`listen` blocks instead.
