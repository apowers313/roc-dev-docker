# dev-env operations and rollback

Ubuntu 24.04 ("noble") is the default as of 2026-10-03.

| | |
|---|---|
| Default build | `./Dockerfile` (24.04) -> `apowers313/roc-dev:3.0.0` / `:latest` |
| Rollback build | `./Dockerfile.jammy` (22.04) -> `apowers313/roc-dev:2.0.0` |
| Default runtime | `compose.yml` |
| Rollback runtime | `compose.yml` + `compose.jammy.yml` |
| No-GPU fallback | `compose.yml` + `compose.nogpu.yml` |

## Everyday commands

    make start          # build + start on the default (24.04) image
    make stop
    make restart
    make check          # smoke test the image against the real ~/dev
    make verify         # supervisord states + in-container checks + port sweep
    make logs

## Rolling back to 22.04

    make rollback       # swap the running container to the 2.0.0 image

Two caveats:

1. `git-lfs` and `tilix` were installed by hand in the original container and
   lived only in its writable layer, which is gone. They are in `./Dockerfile`
   (24.04) but NOT in `Dockerfile.jammy`, so a rolled-back container lacks
   them until you add them there or reinstall by hand.
2. Anything recompiled inside 24.04 links glibc 2.39 and will not run on
   22.04's 2.35. Rebuild those in the rolled-back container.

Do not `docker image prune` while you still want the 2.0.0 rollback image
(15.7 GB).

## If the container restarts unexpectedly

`dev-env-watchdog.sh` exists because of the 2026-10-03 restart, where the only
evidence left was "supervisord started" with no shutdown message - the
pre-death resource trend, the service logs and the process list were either
inside the container (lost on recreate) or never recorded.

    ./dev-env-watchdog.sh install      # prints the sudo commands to install it
    ./dev-env-watchdog.sh status       # sampler + incident summary
    ./dev-env-watchdog.sh incidents    # the most recent incident in full
    ./dev-env-watchdog.sh test         # exercise the capture path now

It samples cgroup/host state every 10s to `/home/apowers/dev-env-diag/samples.log`
and, on a `die`/`oom`/`kill` event, writes a full incident dir containing: the
exit code and OOMKilled flag, 2000 lines of container stdout, every supervisord
service log copied out of the stopped container, the last 200 resource samples
(the run-up), host memory/load/df, dmesg, the filtered journal, the container's
own systemd scope journal, and nvidia-smi.

Service logs are ALSO persisted to `/home/apowers/dev/logs/supervisord` (visible
as `~/logs/supervisord` inside the container), so they now survive a recreate
on their own.

To find out WHO sent a kill signal - the one question the current evidence
cannot answer - add an audit rule (needs auditd):

    sudo auditctl -a always,exit -F arch=b64 -S kill -F a1=9 -k sigkill
    sudo ausearch -k sigkill -ts recent     # after an incident

That logs the sending pid/uid/comm for every SIGKILL. It is noisy on a busy dev
box, so treat it as something to switch on while hunting a recurrence.

## If the GPU stops working

Symptom: a container fails to start with
`nvidia-container-cli: initialization error: nvml error: driver/library
version mismatch`.

Cause: the loaded nvidia kernel module and userspace NVML disagree, which
happens when the driver packages are upgraded without a reboot.

    ./fix-nvidia-driver.sh verify        # read-only check
    ./fix-nvidia-driver.sh reboot --yes  # the reliable fix

A reboot is usually the answer: a module reload needs every GPU user stopped,
and a stuck `nvidia_uvm` refcount (in use, no identifiable holder) does not
clear by retrying. Note that a mismatch blocks BOTH a new container and a
rollback, because compose.yml reserves a GPU - so if you are stuck without a
dev environment:

    make nogpu          # start on 22.04 with the GPU reservation removed

**When testing GPU access by hand, always pass `--privileged` alongside
`--gpus all`.** `/etc/nvidia-container-runtime/config.toml` sets
`no-cgroups = true`, so without it you get `Failed to initialize NVML: Unknown
Error` even on a perfectly healthy driver. compose.yml sets
`privileged: true`, which is why dev-env works.

## The 136 ~/.local/bin launchers

Scripts in the bind-mounted `~/.local/bin` carry a `#!/usr/bin/python3`
shebang, and their packages live in `~/.local/lib/python3.10`. On 24.04
`/usr/bin/python3` is 3.12, so those launchers fail with ModuleNotFoundError.
They are deliberately left unfixed (unused). No service depends on them -
supervisord calls `/usr/local/bin/jupyter` directly.

To use one anyway:            `python3.10 ~/.local/bin/<tool>`
To fix them all (reversible): `./fix-home-shebangs --apply`

`make check` reports these as `known-and-accepted`, not failures.
