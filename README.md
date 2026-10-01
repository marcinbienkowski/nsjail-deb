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

If the `.deb` sits in a directory that apt's sandboxed `_apt` user can't read (e.g. a `~/Downloads` without `o+rx`), the install may print `N: Download is performed unsandboxed as root as file '...' couldn't be accessed by user '_apt'.` This is harmless: apt falls back to an unsandboxed local read for that step, and the message is unrelated to the nsjail package itself.

### Testing the installed package

```bash
sudo apt-get install -y ./nsjail_*.deb
bash scripts/ci-smoke-test.sh
```

The script runs the installed `nsjail` binary (not a locally built one) through a curated subset of nsjail's own `make test` suite: basic sandboxing, seccomp, NAT (IPv4/IPv6), traffic rules, a `HOST_TO_GUEST` proxy test, mount/bind isolation, and `exec_fd`/`execveat`. It reads `.cfg` files straight from the `nsjail/tests` and `nsjail/configs` directories of the submodule, so the submodule must be checked out (see [Getting started](#getting-started)).

Some of upstream's tests are intentionally left out, e.g. pasta port mappings, the SOCKS5/HTTP-CONNECT proxy configs, and the X11/Wayland GUI configs. [scripts/ci-smoke-test-README.md](scripts/ci-smoke-test-README.md) explains why.

### Using nsjail

This repo only packages nsjail. For its usage (command-line flags, config file format, examples), see [nsjail's own README](https://github.com/google/nsjail#readme) and [config.proto](https://github.com/google/nsjail/blob/master/config.proto) upstream.

## Package description

nsjail upstream already ships its own `debian/` packaging. Our `debian/` overrides only what we need to customize: `control` (maintainer), `changelog` (version and author), `rules` (build fixes below), and a new `apparmor/nsjail` profile with its `nsjail.install` (see below). The files `copyright`, `compat` and `source/format` stay as nsjail's own tracked copies.

`debian/rules` build fixes:

- `optimize=-lto` disables LTO: debhelper's default `-flto=auto` breaks linkage of the `pasta_start`/`pasta_end` inline assembly symbols in `nsjail/net.cc`.
- `dh_auto_test` is skipped: upstream's test suite requires network access and root, which a package build doesn't have.
- `noddebs` skips generating a separate `nsjail-dbgsym_*.ddeb` debug-symbols package.

`scripts/build.sh` copies these overlay files onto the submodule, runs `dpkg-buildpackage`, and cleans up the submodule's dirty state afterward (even if the build fails).

`debian/control` also adds `Suggests: passt`. The only external binary that nsjail executes at runtime is `pasta`, which `passt` provides and which only the optional `user_net.pasta` NAT mode uses. nsjail's other networking modes don't need it.

### AppArmor profile (unprivileged nsjail on Ubuntu)

nsjail needs `CLONE_NEWUSER` (an unprivileged user namespace) for its sandboxing, and building its own mount tree requires an `MS_PRIVATE` remount of `/`. Since Ubuntu 23.10, AppArmor denies unprivileged `CLONE_NEWUSER` by default, unless the calling binary runs under a profile that explicitly grants it. The sysctl `kernel.apparmor_restrict_unprivileged_userns=1` controls this, on top of the older `kernel.unprivileged_userns_clone`. Without that grant, even non-root nsjail invocations fail with `mount('/', MS_REC|MS_PRIVATE): Permission denied`. The restriction is specific to Ubuntu: Debian has no such sysctl.

`debian/apparmor/nsjail` grants just `userns,` to `/usr/bin/nsjail` and leaves it otherwise unconfined, so the installed package works unprivileged out of the box on Ubuntu. `debian/nsjail.install` installs the profile to `/etc/apparmor.d/nsjail`, and `dh_apparmor` in `debian/rules` makes `postinst` reload it automatically. `debian/rules` calls `dh_apparmor` only if `debian/apparmor/nsjail` is present. `scripts/build.sh debian` doesn't copy that file or `debian/nsjail.install` onto the submodule, so the Debian build skips the profile entirely. Debian's kernel doesn't restrict unprivileged `CLONE_NEWUSER` this way, so it needs no profile.

## Building from source

### Getting started

Clone with submodules:

```bash
git clone --recurse-submodules https://github.com/marcinbienkowski/nsjail-deb.git
```

If you already cloned without `--recurse-submodules`, fetch the submodule separately:

```bash
git submodule update --init --recursive
```

`scripts/build.sh` runs this step itself, so you need it only if you want the `nsjail/` sources before building.

The submodule is pinned to a specific commit, with no floating branch or tag. [Updating and releasing](#updating-and-releasing) below explains how we track and bump that pin.

### Build dependencies

From the repo root:

```bash
sudo apt-get build-dep ./
sudo apt-get install devscripts
```

`apt-get build-dep ./` installs the `Build-Depends` of `debian/control` together with `build-essential`. `devscripts` provides `dch`, which `scripts/build.sh` uses to set the per-distro version.

### Building

```bash
bash scripts/build.sh [ubuntu|debian]
```

The argument defaults to `ubuntu`. The two builds produce separate `.deb`s with distinct version suffixes (`~ubuntu-24.04-noble` and `~debian-13-trixie`). The packages themselves differ, because `dh_shlibdeps` derives the `Depends:` constraints from the library versions on the build machine, and these differ between the two distros. The `debian` build skips the [AppArmor profile](#apparmor-profile-unprivileged-nsjail-on-ubuntu), which only Ubuntu needs.

The resulting `.deb` is placed in the parent directory of `nsjail/` (i.e. the repo root).

### CI

`.github/workflows/build.yml` has two build jobs, `build-ubuntu` (Ubuntu 24.04) and `build-debian` (`container: debian:13`). Both install the built `.deb` and run [`scripts/ci-smoke-test.sh`](#testing-the-installed-package) against it. Outside pull requests, they also upload the `.deb` as a workflow artifact. Three small jobs around them read the package version, post it on pull requests, and publish the release (see [Updating and releasing](#updating-and-releasing)).

The container of `build-debian` runs with `--privileged`, because nsjail's unprivileged sandboxing needs more than Docker's default container profile allows. nsjail's own Docker instructions upstream use the same flag. In that container, 4 of the 20 smoke tests are skipped: they fail only because the job runs in a bare container without a login session (see [scripts/ci-smoke-test-README.md](scripts/ci-smoke-test-README.md)).

To start the workflow manually, use the repo's **Actions** tab ("Build .deb" → "Run workflow") or run:

```bash
gh workflow run build.yml
```

## Updating and releasing

`.github/workflows/update-nsjail.yml` checks upstream nsjail daily. If upstream has moved, it opens a PR (branch `bump-nsjail`) with the submodule bump and a regenerated `debian/changelog` entry, and enables auto-merge on it. `build.yml` builds and smoke-tests that PR like any other, and GitHub merges it once both checks pass. Thus every upstream change that passes the smoke test is released without review. To hold one back, disable auto-merge on its PR with `gh pr merge --disable-auto <number>`.

The workflow opens the PR and enables auto-merge as a GitHub App. CI on a PR opened with the default `GITHUB_TOKEN` waits for manual approval, and a merge made with that token would start no workflow on `main`, hence no release. The App's Client ID is in the repo variable `BUMP_APP_CLIENT_ID`, and its private key is in the secret `BUMP_APP_PRIVATE_KEY`.

To bump manually without waiting for the next scheduled run, run the following on a branch and open a PR from it:

```bash
git submodule update --remote nsjail
git add nsjail
bash scripts/bump-changelog.sh
git add debian/changelog
git commit -m "Bump nsjail submodule to <short-sha>"
```

Stage the submodule before running `scripts/bump-changelog.sh`. The script starts with `git submodule update --init`, which checks out the commit staged in the index, so it would revert an unstaged bump. The script derives the package version from the submodule (nearest upstream tag and commit date) and prepends a `debian/changelog` entry when that version differs from the current one. Commit this entry together with the submodule. The release is tagged from the committed changelog, so a bump without the entry releases nothing.

Merging a bump PR, automatically or by hand, publishes the release. On every push to `main`, once both builds pass, the `release` job tags the commit as `v<version>`, with the version taken from the top `debian/changelog` entry. It then creates a GitHub Release with the two `.deb` packages, one for Ubuntu and one for Debian. If the tag already exists (e.g. after a README-only commit), nothing is released. The `pr-comment` job posts the version as a sticky PR comment, so you can see what a merge will release without a local checkout.
