#!/usr/bin/env bash

# Builds the .deb for the distro of the build host, read from /etc/os-release. dh_shlibdeps
# derives the Depends: versions from the host's libraries, so the package fits only that distro
# anyway. Ubuntu builds ship the AppArmor profile that grants nsjail unprivileged CLONE_NEWUSER
# (see the AppArmor section of README.md). Debian builds skip it, since Debian doesn't restrict
# unprivileged user namespaces this way.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NSJAIL_DIR="$REPO_ROOT/nsjail"

. /etc/os-release
case "$ID" in
    ubuntu | debian) ;;
    *) echo "Unsupported distro: $ID" >&2; exit 1 ;;
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
if [ "$ID" = debian ]; then
    rm -rf "$NSJAIL_DIR/debian/apparmor" "$NSJAIL_DIR/debian/nsjail.install"
fi

cd "$NSJAIL_DIR"

# Distro-specific local version suffix (e.g. ...-2~ubuntu-24.04-noble vs ...-2~debian-13-trixie)
# so the artifacts don't collide when released together. All distro builds here share the same
# debian/changelog: any change that would justify a rebuild already bumps the shared -N revision.
MAINTAINER="$(dpkg-parsechangelog -SMaintainer)"
CURRENT_VERSION="$(dpkg-parsechangelog -SVersion)"
DEBFULLNAME="${MAINTAINER% <*}" DEBEMAIL="${MAINTAINER#*<}" DEBEMAIL="${DEBEMAIL%>}" \
    dch --newversion "${CURRENT_VERSION}~${ID}-${VERSION_ID}-${VERSION_CODENAME}" \
    --distribution "$VERSION_CODENAME" --force-distribution --force-bad-version \
    "${ID^} ${VERSION_ID} build."

dpkg-buildpackage -us -uc -b

echo ""
echo "Build complete. Packages are in: $(dirname "$NSJAIL_DIR")"
ls "$(dirname "$NSJAIL_DIR")"/*.deb 2>/dev/null || true
