#!/usr/bin/env bash
# Usage: scripts/build.sh [ubuntu|debian]

# "ubuntu" (default) ships the AppArmor profile that grants nsjail unprivileged
# CLONE_NEWUSER (see the AppArmor section of README.md). "debian" skips it, since
# Debian doesn't restrict unprivileged user namespaces this way.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NSJAIL_DIR="$REPO_ROOT/nsjail"
DISTRO="${1:-ubuntu}"

case "$DISTRO" in
    ubuntu) LOCAL_SUFFIX="~ubuntu-24.04-noble"; CODENAME="noble" ;;
    debian) LOCAL_SUFFIX="~debian-13-trixie"; CODENAME="trixie" ;;
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

# Distro-specific local version suffix (e.g. ...-2~ubuntu-24.04-noble vs ...-2~debian-13-trixie)
# so the two artifacts don't collide if released together. Both distro builds here share the same
# debian/changelog: any change that would justify a rebuild already bumps the shared -N revision.
MAINTAINER="$(dpkg-parsechangelog -SMaintainer)"
CURRENT_VERSION="$(dpkg-parsechangelog -SVersion)"
DEBFULLNAME="${MAINTAINER% <*}" DEBEMAIL="${MAINTAINER#*<}" DEBEMAIL="${DEBEMAIL%>}" \
    dch --newversion "${CURRENT_VERSION}${LOCAL_SUFFIX}" --distribution "$CODENAME" \
    --force-distribution --force-bad-version "${DISTRO^} build."

dpkg-buildpackage -us -uc -b

echo ""
echo "Build complete. Packages are in: $(dirname "$NSJAIL_DIR")"
ls "$(dirname "$NSJAIL_DIR")"/*.deb 2>/dev/null || true
