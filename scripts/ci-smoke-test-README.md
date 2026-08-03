# ci-smoke-test.sh

Smoke test for the *installed* nsjail `.deb` (tests the `nsjail` binary on `$PATH`, not a
locally-built `./nsjail`). A curated subset of nsjail's own `make test` suite
(`nsjail/Makefile`), trimmed to what can run unattended on a GitHub-hosted `ubuntu-latest`
runner.

## Running

```bash
sudo apt-get install -y ./nsjail_*.deb
bash scripts/ci-smoke-test.sh
```

Run from the repo root, with the `nsjail/` submodule checked out: the script reads `.cfg`
files straight from `nsjail/tests/` and `nsjail/configs/` rather than hand-copied duplicates, so
it always tracks whatever the pinned submodule commit actually contains. Both `scripts/build.sh`
and the CI workflow already guarantee the submodule is checked out before this would run.

The install step needs `sudo` (`apt-get install` and its `postinst`, which loads the package's
AppArmor profile: see README's "AppArmor profile" section). The test run itself doesn't:
nsjail runs fully unprivileged.

Requires `wget`, `python3`, `strace`, `busybox-static`, `passt` (provides the `pasta` binary) on
the runner (all installable via `apt`).

## What's included

Basic sanity (`true`/`false`), seccomp, NAT (nstun backend IPv6-only, and pasta-backend
outbound TCP), traffic rules (4 variants), a `HOST_TO_GUEST` inbound proxy test over loopback
(IPv4 + IPv6), `--experimental_mnt=old` mount/bind isolation (tmpfs rw/ro, `-R`, `-B`, `$HOME`,
`/run/user/$UID`), and a static-busybox `exec_fd`/`execveat` test.

## What's excluded, and why

- **`nat-ip4-only.cfg`'s outbound ping**: 100% packet loss on GitHub-hosted runners (ICMP
  dropped/rate-limited), passes fine locally. Not nsjail's fault. IPv6-only variant (no ping)
  still runs.
- **`pasta-port-mappings.cfg`**: works unprivileged now, but it's an interactive demo config,
  not a pass/fail test. Would need a listener + connect-through-the-mapped-port harness.
- **`socks5.cfg` / `connect.cfg`**: need a real SOCKS5/HTTP-CONNECT proxy listening locally.
  Too much extra infrastructure for a smoke test.
- **`--experimental_mnt=new`'s tmpfs remounts**: fail with `EINVAL` since `/tmp` is already a
  tmpfs mount (default on any systemd distro). Real compat gap, unrelated to privilege.
- **`configs/bash-with-fake-geteuid.cfg`/`.json`**: segfaults (exit 139), consistently
  reproducible. Likely the config's `pass_fd: 100`/`pass_fd: 3` referencing fds that may or may
  not exist depending on the invoking shell's fd table.
- GUI configs (`home-documents-with-xorg-no-net.cfg`, `firefox-with-net-X11.cfg`,
  `firefox-with-net-wayland.cfg`, `chromium-with-net-wayland.cfg`): need a display server and
  browser packages not on a bare runner.

### Additionally skipped only in `build-debian`'s CI job (`NSJAIL_SKIP_CONTAINER_QUIRKS=1`)

`build-debian` runs inside a GitHub Actions `container:` job with `--privileged` (see
[README.md](../README.md#ci) for why nsjail's unprivileged sandboxing needs that there at all).
That's a bare root shell with no login session, unlike `build-ubuntu`'s real VM. Three tests
fail there for reasons specific to that environment, not to Debian or nsjail:

- **pasta NAT: outbound TCP works**: times out (exit 137). Likely pasta struggling with the
  extra layer of container network nesting on top of the runner's own virtualization; `passt`
  installs fine, so this isn't a missing-dependency issue.
- **`$HOME` mount is writable with `--rw`**: `permission denied` touching
  `/github/home/nsjail_test_home`. That path is a GitHub-Actions-owned mount for container jobs,
  not a normal user's home directory, and its ownership doesn't match what the test expects.
- **`/run/user/$UID` stays writable regardless of `--rw`**: `/run/user/0` doesn't exist. No
  `pam_systemd`/login session ever created it, since this is a bare `container:` job, not a real
  login.

These are skipped only for `build-debian`; `build-ubuntu` (a real VM) and any manual/local run
still exercise all of them.
