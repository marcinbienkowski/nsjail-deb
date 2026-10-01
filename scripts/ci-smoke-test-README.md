# ci-smoke-test.sh

Smoke test for the *installed* nsjail `.deb`, i.e. for the `nsjail` binary on `$PATH`. It runs a curated subset of nsjail's own `make test` suite (`nsjail/Makefile`), trimmed to what can run unattended on a GitHub-hosted Ubuntu 24.04 runner.

## Running

```bash
sudo apt-get install -y ./nsjail_*.deb
bash scripts/ci-smoke-test.sh
```

Run it from the repo root, with the `nsjail/` submodule checked out. The script reads `.cfg` files straight from `nsjail/tests/` and `nsjail/configs/`, so it always tests what the pinned submodule commit contains. Both `scripts/build.sh` and the CI workflow check out the submodule before the script runs.

The install step needs `sudo`, for `apt-get install` and for its `postinst`, which loads the package's AppArmor profile (see the [AppArmor profile](../README.md#apparmor-profile-unprivileged-nsjail-on-ubuntu) section of the README). The test run itself doesn't: nsjail runs fully unprivileged.

The script requires `wget`, `python3`, `strace`, `busybox-static` and `passt` (which provides the `pasta` binary), all installable with `apt`.

## What's included

Basic sanity (`true`/`false`), seccomp, NAT (the nstun backend with IPv6 only, and outbound TCP through the pasta backend), traffic rules (4 variants), a `HOST_TO_GUEST` inbound proxy test over loopback (IPv4 and IPv6), mount/bind isolation with `--experimental_mnt=old` (tmpfs rw/ro, `-R`, `-B`, `$HOME`, `/run/user/$UID`), and an `exec_fd`/`execveat` test with a static busybox.

## What's excluded, and why

- **Outbound ping in `nat-ip4-only.cfg`**: ICMP sees 100% packet loss on GitHub-hosted runners (dropped or rate-limited), while the test passes locally. This is not nsjail's fault. The IPv6-only variant (without ping) still runs.
- **`pasta-port-mappings.cfg`**: it works unprivileged, but it is an interactive demo config without a pass/fail outcome. Testing it would need a listener and a harness that connects through the mapped port.
- **`socks5.cfg` / `connect.cfg`**: these need a real SOCKS5 or HTTP-CONNECT proxy listening locally, which is too much infrastructure for a smoke test.
- **tmpfs remounts with `--experimental_mnt=new`**: these fail with `EINVAL` because `/tmp` is already a tmpfs mount, the default on any systemd distro. This is a real compatibility gap in nsjail, unrelated to privileges.
- **`configs/bash-with-fake-geteuid.cfg`/`.json`**: these segfault (exit 139), reproducibly. The likely cause is that the config passes fds 100 and 3 (`pass_fd`), which may or may not exist, depending on the fd table of the invoking shell.
- **GUI configs** (`home-documents-with-xorg-no-net.cfg`, `firefox-with-net-X11.cfg`, `firefox-with-net-wayland.cfg`, `chromium-with-net-wayland.cfg`): these need a display server and browser packages, which a bare runner doesn't have.

### Additionally skipped only in `build-debian`'s CI job (`NSJAIL_SKIP_CONTAINER_QUIRKS=1`)

`build-debian` runs inside a GitHub Actions `container:` job with `--privileged` (see [README.md](../README.md#ci) for why). The job is a bare root shell without a login session, unlike the VM of `build-ubuntu`. Four tests fail there for reasons specific to that environment, unrelated to Debian or nsjail:

- **pasta NAT: outbound TCP works**: times out (exit 137). Pasta likely struggles with the extra layer of container networking on top of the runner's own virtualization. `passt` installs fine, so the cause is not a missing dependency.
- **`$HOME` mount is writable with `--rw`**: `permission denied` when touching `/github/home/nsjail_test_home`. GitHub Actions mounts that path for container jobs. It is not a regular home directory, and its ownership differs from what the test expects.
- **`/run/user/$UID` is read-only without `--rw`** and **`/run/user/$UID` is writable with `--rw`**: `/run/user/0` doesn't exist, since no `pam_systemd` login session created it in a bare `container:` job. The `--rw` test fails on `ENOENT`. The read-only test would pass on `ENOENT` too, without exercising any remount.

We skip these only in `build-debian`. `build-ubuntu` (a real VM) and any local run exercise all of them.
