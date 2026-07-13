# Docker-based Synapse setup (supersedes the venv/systemd path for plain runs)

Uses `synapse/docker/Dockerfile` (the official image build) instead of a hand-built
Python venv, and `docker compose` instead of a hand-rolled systemd unit — see
`../setup_https_homeserver.sh` / `../start_synapse.sh` for that older path, still here
in case you need the bare venv for some reason.

## Layout on the box

```
~/clods/
  synapse/                 <- rsync of android/synapse (has docker/Dockerfile)
  Python-Instrumentation/  <- rsync of android/Python-Instrumentation (for element-516 later)
  docker-compose.yml       <- this folder's file
  setup.sh                 <- this folder's file
```

From your workstation:
```bash
rsync -a ../../../../android/synapse/ <box>:~/clods/synapse/
rsync -a ../../../../android/Python-Instrumentation/ <box>:~/clods/Python-Instrumentation/
scp docker-compose.yml setup.sh <box>:~/clods/
```

On the box (needs Docker + the `docker compose` plugin, and `sudo` for the nginx step):
```bash
cd ~/clods
./setup.sh <public-ip>
```

## Why Python 3.10

`docker-compose.yml` builds with `--build-arg PYTHON_VERSION=3.10` instead of the
Dockerfile's own default (3.11). Python-Instrumentation's bytecode rewriting hardcodes
the `CALL_FUNCTION` opcode, which Python 3.11 removed — pinning to 3.10 here means this
same image can later run element-516's instrumented plan, not just plain Synapse.

## Registering a user

```bash
docker compose exec synapse register_new_matrix_user http://localhost:8008 -c /data/homeserver.yaml
```
(matches the official docs' `docker exec` form, since `register_new_matrix_user` lives
inside the container, not on the host.)

## Operating it

```bash
docker compose logs -f synapse     # tail logs (stdout, unlike the venv path's log file)
docker compose restart synapse     # after editing data/homeserver.yaml
docker compose down                # stop everything
```
