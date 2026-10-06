#!/usr/bin/env bash

# Computes the package version from the nsjail submodule and prepends a debian/changelog
# entry if it doesn't already match.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NSJAIL_DIR="$REPO_ROOT/nsjail"

git -C "$REPO_ROOT" submodule update --init --recursive

# A shallow checkout (e.g. actions/checkout's default fetch-depth: 1, which also applies to submodules) has no tags.
if [ "$(git -C "$NSJAIL_DIR" rev-parse --is-shallow-repository)" = "true" ]; then
    git -C "$NSJAIL_DIR" fetch --unshallow --tags
else
    git -C "$NSJAIL_DIR" fetch --tags
fi

CHANGELOG="$REPO_ROOT/debian/changelog"
NSJAIL_TAG="$(git -C "$NSJAIL_DIR" describe --tags --abbrev=0)"
NSJAIL_COMMIT="$(git -C "$NSJAIL_DIR" rev-parse --short=8 HEAD)"
NSJAIL_DATE="$(git -C "$NSJAIL_DIR" log -1 --format=%cd --date=format:%Y%m%d HEAD)"
# The entry is stamped with the upstream commit's date, not today's, so rerunning on the same commit
# regenerates an identical changelog. Otherwise the daily update workflow re-pushes an open bump PR
# whose upstream hasn't moved, which reruns its CI and notifies every day.
NSJAIL_RFC2822_DATE="$(git -C "$NSJAIL_DIR" log -1 --format=%cD HEAD)"
PKG_VERSION_BASE="${NSJAIL_TAG}+git${NSJAIL_DATE}"
PKG_VERSION="${PKG_VERSION_BASE}-1"
CURRENT_VERSION="$(dpkg-parsechangelog -l"$CHANGELOG" -SVersion)"

# Compare only the upstream part (strip the trailing -N revision), so a
# manually-bumped repackage-only revision (e.g. ...-2 for a packaging-only
# change) doesn't look like a submodule move.
CURRENT_VERSION_BASE="${CURRENT_VERSION%-*}"

if [ "$CURRENT_VERSION_BASE" != "$PKG_VERSION_BASE" ]; then
    echo "Submodule moved ($CURRENT_VERSION -> $PKG_VERSION); adding changelog entry."
    PKG_NAME="$(dpkg-parsechangelog -l"$CHANGELOG" -SSource)"
    MAINTAINER="$(dpkg-parsechangelog -l"$CHANGELOG" -SMaintainer)"
    {
        printf '%s (%s) unstable; urgency=medium\n\n' "$PKG_NAME" "$PKG_VERSION"
        printf '  * Bump nsjail submodule to upstream commit %s (%s).\n\n' \
            "$NSJAIL_COMMIT" "$NSJAIL_DATE"
        printf ' -- %s  %s\n\n' "$MAINTAINER" "$NSJAIL_RFC2822_DATE"
        cat "$CHANGELOG"
    } >"$CHANGELOG.new"
    mv "$CHANGELOG.new" "$CHANGELOG"
    echo "Review and commit the updated debian/changelog."
fi
