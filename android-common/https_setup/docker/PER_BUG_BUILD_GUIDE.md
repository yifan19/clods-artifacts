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

# --- current version: 516, 6782, 5132, 7643 ---
git checkout develop
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION=3.10 \
    -t clods-synapse:516 -t clods-synapse:6782 -t clods-synapse:5132 -t clods-synapse:7643 .

# --- old version: 7516 ---
git checkout bug10
DOCKER_BUILDKIT=1 docker build -f docker/Dockerfile --build-arg PYTHON_VERSION=3.10 \
    -t clods-synapse:7516 .

git checkout develop   # leave the checkout back on the branch other tooling in this repo expects
```

One `docker build` with multiple `-t` flags produces one image with several tags — cheaper than
building the same commit 4 times. `PYTHON_VERSION=3.10` is still worth pinning even though none of
these bugs' `.properties` plans touch Python-Instrumentation the way `element-516`'s round2 does
server-side — keeps every image on the version that instrumentation needs, in case that changes.

Confirm:
```bash
docker images clods-synapse
```

## 3. Run a bug's image, exposing 8008

Pick the tag for whichever bug you're driving right now:
```bash
docker run -d --name clods-synapse \
    -p 8008:8008 \
    -v ~/clods/data:/data \
    clods-synapse:516        # swap the tag for whichever bug
```
(`-v ~/clods/data:/data` — reuse the same `data/` dir this session's `synapse_build/data/` already
has a generated `homeserver.yaml`/signing key in, so you're not regenerating config per bug. If you
want each bug fully isolated instead, use a separate `-v` target per tag, e.g. `~/clods/data-516`.)

To switch bugs: `docker rm -f clods-synapse`, then `docker run ...` again with the other tag. Since
they share `/data`, the same `homeserver.yaml`/accounts/database carry over between bugs — only
the server binary itself changes. If you'd rather each bug got a clean database too, point `-v` at
a fresh directory per tag and re-run the `generate` step from `setup.sh` for that directory first.

## 4. Create user1 and user2

```bash
docker exec clods-synapse register_new_matrix_user \
    -u user1 -p <password1> --no-admin -c /data/homeserver.yaml http://localhost:8008
docker exec clods-synapse register_new_matrix_user \
    -u user2 -p <password2> --no-admin -c /data/homeserver.yaml http://localhost:8008
```
(Non-interactive form — `-u`/`-p`/`--no-admin` skip the prompts. Uses `registration_shared_secret`
from `homeserver.yaml`, same admin-bypass mechanism as before, works regardless of
`enable_registration`.)

## 5. Real domain + nginx + Let's Encrypt (clods-test.uk)

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
