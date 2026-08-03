#!/usr/bin/env bash
# Usage: scripts/build.sh [ubuntu|debian]
#
# "ubuntu" (default) ships the AppArmor profile that grants nsjail unprivileged
# CLONE_NEWUSER (see README.md - Ubuntu-only restriction). "debian" skips it -
# Debian needs none of that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NSJAIL_DIR="$REPO_ROOT/nsjail"
DISTRO="${1:-ubuntu}"

case "$DISTRO" in
    ubuntu) LOCAL_SUFFIX="~ubuntu24.04"; CODENAME="noble" ;;
    debian) LOCAL_SUFFIX="~trixie"; CODENAME="trixie" ;;
    *) echo "Usage: $0 [ubuntu|debian]" >&2; exit 1 ;;
esac

bash "$REPO_ROOT/scripts/bump-changelog.sh"

cleanup() {
    git -C "$NSJAIL_DIR" checkout -- debian/rules debian/control debian/changelog 2>/dev/null || true
    rm -f "$NSJAIL_DIR"/debian/debhelper-build-stamp "$NSJAIL_DIR"/debian/files "$NSJAIL_DIR"/debian/nsjail.substvars
    rm -f "$NSJAIL_DIR"/debian/nsjail.install
    rm -f "$NSJAIL_DIR"/debian/nsjail.debhelper.log "$NSJAIL_DIR"/debian/nsjail.postinst.debhelper "$NSJAIL_DIR"/debian/nsjail.postrm.debhelper
    rm -rf "$NSJAIL_DIR"/debian/.debhelper "$NSJAIL_DIR"/debian/nsjail "$NSJAIL_DIR"/debian/apparmor
}
trap cleanup EXIT

cp -r "$REPO_ROOT/debian" "$NSJAIL_DIR/"
if [ "$DISTRO" = debian ]; then
    rm -rf "$NSJAIL_DIR/debian/apparmor" "$NSJAIL_DIR/debian/nsjail.install"
fi

cd "$NSJAIL_DIR"

# Distro-specific local version suffix (e.g. ...-2~ubuntu24.04 vs ...-2~trixie) so the two
# artifacts don't collide if released together. No per-distro rebuild counter is needed on top of
# that - unlike real Debian backports (independent, asynchronous uploads of a fixed upstream
# version, hence their own ~bpoN counter), both distro builds here share the same
# debian/changelog: any change that would justify a rebuild already bumps the shared -N revision,
# which then flows into both suffixed versions identically. Only touches this build copy of
# debian/changelog, never the one committed in the repo. Uses --newversion (not --local) to set
# the exact version, since --local also auto-increments the revision and merges suffixes in
# non-obvious ways (e.g. "-2" + "--local ~trixie1" once produced "-2~trixie11", not "-2~trixie1").
MAINTAINER="$(dpkg-parsechangelog -SMaintainer)"
CURRENT_VERSION="$(dpkg-parsechangelog -SVersion)"
DEBFULLNAME="${MAINTAINER% <*}" DEBEMAIL="${MAINTAINER#*<}" DEBEMAIL="${DEBEMAIL%>}" \
    dch --newversion "${CURRENT_VERSION}${LOCAL_SUFFIX}" --distribution "$CODENAME" \
    --force-distribution --force-bad-version "${DISTRO^} build."

dpkg-buildpackage -us -uc -b

echo ""
echo "Build complete. Packages are in: $(dirname "$NSJAIL_DIR")"
ls "$(dirname "$NSJAIL_DIR")"/*.deb 2>/dev/null || true
