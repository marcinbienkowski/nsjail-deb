# nsjail-deb

[![Build .deb](https://github.com/marcinbienkowski/nsjail-deb/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/marcinbienkowski/nsjail-deb/actions/workflows/build.yml)

Debian packaging for [nsjail](https://github.com/google/nsjail), a light-weight process isolation tool.

The `nsjail/` directory is a git submodule pointing to upstream. The `debian/` directory contains the packaging files that are injected into the source tree at build time.

## Usage

### Installation

Download the `.deb` from the repo's [Releases](https://github.com/marcinbienkowski/nsjail-deb/releases) page and install it:

```bash
sudo apt-get install -y ./nsjail_*.deb
```

If the `.deb` sits in a directory apt's sandboxed `_apt` user can't read (e.g. a `~/Downloads`
without `o+rx`), the install may print `N: Download is performed unsandboxed as root as file
'...' couldn't be accessed by user '_apt'.`: harmless, apt falls back to an unsandboxed local
read for that step; unrelated to the nsjail package itself.

### Testing the installed package

```bash
sudo apt-get install -y ./nsjail_*.deb
bash scripts/ci-smoke-test.sh
```

Runs the installed `nsjail` binary (not a locally-built one) through a curated subset of
nsjail's own `make test` suite: basic sandboxing sanity, seccomp, NAT (IPv4/IPv6), traffic
rules, a `HOST_TO_GUEST` proxy test, mount/bind isolation, and `exec_fd`/`execveat`. It reads
`.cfg` files straight out of the `nsjail/tests` and `nsjail/configs` submodule checkout, so the
submodule needs to be present (see [Getting started](#getting-started)).

Some of upstream's own tests are intentionally left out (pasta-backed networking, X11/Wayland
GUI configs, and a couple of others): see
[scripts/ci-smoke-test-README.md](scripts/ci-smoke-test-README.md) for why.

### Using nsjail

This repo only packages nsjail: for actual usage (command-line flags, config file format,
examples), see [nsjail's own README](https://github.com/google/nsjail#readme) and
[config.proto](https://github.com/google/nsjail/blob/master/config.proto) upstream.

## Package description

nsjail upstream already ships its own `debian/` packaging. This repo's `debian/` only overrides
what we need to customize: `control` (maintainer), `changelog` (version/author), `rules`
(build fixes below), and a new `apparmor/nsjail` profile + `nsjail.install` (below); `copyright`,
`compat`, and `source/format` are left as nsjail's own tracked copies.

`debian/rules` build fixes:

- `optimize=-lto` disabled: debhelper's default `-flto=auto` breaks linkage of the
  `pasta_start`/`pasta_end` inline assembly symbols in `nsjail/net.cc`
- `dh_auto_test` skipped: upstream's test suite requires network access and root, not suitable
  for package builds
- `noddebs` set: skips generating a separate `nsjail-dbgsym_*.ddeb` debug-symbols package

`scripts/build.sh` copies these overlay files onto the submodule, runs `dpkg-buildpackage`, and
cleans up the submodule's dirty state afterward (even if the build fails).

`debian/control` also adds `Suggests: passt`: the only external binary nsjail execs at runtime
is `pasta` (for the optional `user_net.pasta` NAT mode), which `passt` provides; not required for
nsjail's other networking modes.

### AppArmor profile (unprivileged nsjail on Ubuntu)

nsjail needs `CLONE_NEWUSER` (an unprivileged user namespace) for its sandboxing, and building
its own mount tree requires an `MS_PRIVATE` remount of `/`. Since Ubuntu 23.10, AppArmor denies
unprivileged `CLONE_NEWUSER` by default unless the calling binary runs under a profile that
explicitly grants it (`kernel.apparmor_restrict_unprivileged_userns=1`, on top of the older
`kernel.unprivileged_userns_clone` sysctl): without that grant, even non-root nsjail invocations
fail with `mount('/', MS_REC|MS_PRIVATE): Permission denied`. This restriction is Ubuntu-specific
(not present on Debian, which has no such sysctl).

`debian/apparmor/nsjail`, installed to `/etc/apparmor.d/nsjail` via `debian/nsjail.install` and
wired up with `dh_apparmor` in `debian/rules` (reloaded automatically in `postinst`), grants just
`userns,` to `/usr/bin/nsjail`, otherwise unconfined, so the installed package works
unprivileged out of the box on Ubuntu. `debian/rules` only calls `dh_apparmor` if
`debian/apparmor/nsjail` is present, so `scripts/build.sh debian` (which doesn't copy that file
or `debian/nsjail.install` onto the submodule) skips this entirely: Debian's kernel doesn't
restrict unprivileged `CLONE_NEWUSER` this way, so it needs no profile.

## Building from source

### Getting started

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/marcinbienkowski/nsjail-deb.git
```

If you already cloned without `--recurse-submodules`, fetch it separately:

```bash
git submodule update --init --recursive
```

(`scripts/build.sh` runs this automatically, so it's optional if you're only building, but needed if you want the `nsjail/` sources present beforehand.)

The submodule is pinned to a specific commit (not a floating branch/tag): see [Updating and releasing](#updating-and-releasing) below for how that pin is tracked and bumped.

### Build dependencies

```
sudo apt-get install build-essential debhelper dh-apparmor devscripts dpkg-dev \
    protobuf-compiler libprotobuf-dev libnl-route-3-dev pkg-config \
    bison flex
```

### Building

```bash
bash scripts/build.sh [ubuntu|debian]
```

Defaults to `ubuntu`. The two produce separate, non-collidable `.deb`s (distinct
`~ubuntu-24.04-noble`/`~debian-13-trixie` version suffixes) since `dh_shlibdeps` bakes in
`Depends:` constraints from whatever library versions are on the build machine, which differ
between the two distros.
`debian` skips the [AppArmor profile](#apparmor-profile-unprivileged-nsjail-on-ubuntu), which is
Ubuntu-only.

The resulting `.deb` is placed in the parent directory of `nsjail/` (i.e. the repo root).

### CI

`.github/workflows/build.yml` has two jobs: `build-ubuntu` (Ubuntu 24.04) and `build-debian`
(`container: debian:13`). Both install the built `.deb` and run
[`scripts/ci-smoke-test.sh`](#testing-the-installed-package) against it, then upload it as a
downloadable workflow artifact. `build-debian`'s container runs with `--privileged`: nsjail's
own unprivileged sandboxing needs more than Docker's default container profile allows (matches
nsjail's own upstream Docker instructions, which use the same flag), and 3 of the 20 smoke tests
are skipped there as artifacts of running in a bare container job rather than a real login
session (see [scripts/ci-smoke-test-README.md](scripts/ci-smoke-test-README.md)). Manually
triggered: from the repo's **Actions** tab ("Build .deb" → "Run workflow"), or:

```bash
gh workflow run build.yml
```

## Updating and releasing

`.github/workflows/update-nsjail.yml` checks upstream nsjail daily and, if it's moved, opens a PR
(`bump-nsjail` branch) with the submodule bump and a regenerated `debian/changelog` entry:
`build.yml` builds and smoke-tests that PR like any other, so merging it just needs the checks to
be green. To bump manually instead of waiting for the next cron run:

```bash
git submodule update --remote nsjail
git add nsjail
git commit -m "bump nsjail to <new-version>"
```

Either way, `scripts/build.sh` derives the package version from the submodule (nearest upstream
tag + commit date) and prepends the `debian/changelog` entry automatically whenever it differs
from the current one: no manual `dch` step needed.

Merging a bump PR doesn't publish anything by itself. `build-ubuntu` posts the resulting package
version and the exact `v<version>` tag to push as a sticky PR comment (updated in place on later
pushes), so you don't need a local checkout to know what to tag. Pushing that tag, or drafting a
GitHub Release using it, is what actually triggers a release: the resulting GitHub Release will
contain two `.deb` packages, one for Ubuntu and one for Debian.
