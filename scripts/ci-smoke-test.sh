#!/usr/bin/env bash
# Smoke test for the installed nsjail .deb (tests the `nsjail` binary on
# $PATH, not a locally-built ./nsjail). A curated subset of nsjail's own
# `make test` suite (nsjail/Makefile), reading .cfg files straight from the
# nsjail/ submodule checkout (nsjail/tests/, nsjail/configs/) rather than
# hand-copied duplicates.
#
# See scripts/ci-smoke-test-README.md for what's covered, what's
# deliberately excluded (and why), and known gotchas hit while validating.
#
# Requires: wget, python3, strace, busybox-static (all installable via apt on
# ubuntu-latest).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TESTS_DIR="$REPO_ROOT/nsjail/tests"
CONFIGS_DIR="$REPO_ROOT/nsjail/configs"
NSJAIL=$(command -v nsjail)
FAIL=0

# Set by build-debian's CI step only - skips tests that are artifacts of running as root in a
# bare `container:` job (no login session, GH-Actions-owned $HOME) rather than real Debian/nsjail
# bugs. See ci-smoke-test-README.md. Never set for the Ubuntu job or a real-machine run.
SKIP_CONTAINER_QUIRKS="${NSJAIL_SKIP_CONTAINER_QUIRKS:-0}"

GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

run_test() {
	local desc="$1" expected="$2"
	shift 2
	echo "Testing: $desc (expecting exit code $expected)"
	set +e
	bash -c "$*"
	actual=$?
	set -e
	if [ "$actual" -ne "$expected" ]; then
		echo -e "${RED}✗ FAIL${RESET}: $desc (expected $expected, got $actual)"
		FAIL=1
	else
		echo -e "${GREEN}✓ PASS${RESET}: $desc"
	fi
}

skip_test() {
	echo -e "${YELLOW}⊘ SKIP${RESET}: $1 (see ci-smoke-test-README.md)"
}

# --- Basic sanity ---
run_test "true exits 0" 0 \
	"$NSJAIL -Q -Mo --chroot / --user 99999 --group 99999 -- /bin/true"
run_test "false exits 1" 1 \
	"$NSJAIL -Q -Mo --chroot / --user 99999 --group 99999 -- /bin/false"

# --- Seccomp ---
run_test "seccomp policy blocks ptrace (strace fails)" 77 \
	"$NSJAIL --config $TESTS_DIR/seccomp.cfg -Q -t 2 -- /bin/bash -c 'strace -o /dev/null /bin/true || exit 77'"
run_test "no seccomp policy: strace works" 77 \
	"$NSJAIL --config $TESTS_DIR/basic.cfg -Q -t 2 -- /bin/bash -c 'strace -o /dev/null /bin/true && exit 77'"

# --- NAT (built-in nstun backend) ---
run_test "IPv6-only NAT: jail starts cleanly" 0 \
	"$NSJAIL --config $TESTS_DIR/nat-ip6-only.cfg -Q -t 3 -- /bin/true < /dev/null"

# --- NAT (pasta backend, requires the passt package) ---
# TCP, not ping: outbound ICMP is unreliable on GitHub-hosted runners (see
# ci-smoke-test-README.md's exclusions), same as the dropped nat-ip4-only.cfg test.
# `sleep 1` gives pasta's interface a moment to come up inside the jail before use.
if [ "$SKIP_CONTAINER_QUIRKS" = 1 ]; then
	skip_test "pasta NAT: outbound TCP works"
else
	run_test "pasta NAT: outbound TCP works" 0 \
		"$NSJAIL --config $TESTS_DIR/pasta-nat.cfg -Q -t 5 -- /bin/bash -c 'sleep 1; wget -4 -q -O /dev/null --timeout=5 http://example.com/' < /dev/null"
fi

# --- Traffic rules (needs libnl-route-3, already a runtime dep of the package) ---
run_test "traffic rule: DROP/REJECT ports don't block the jail itself" 137 \
	"$NSJAIL --config $TESTS_DIR/traffic-rules.cfg -Q -t 1 -- /bin/bash -c 'sleep 10'"
run_test "traffic rule: IPv4 DROP on TCP/80" 137 \
	"$NSJAIL --config $TESTS_DIR/traffic-drop-tcp4.cfg -Q -t 1 -- /bin/bash -c 'sleep 10'"
run_test "traffic rule: IPv6 DROP on UDP/53" 137 \
	"$NSJAIL --config $TESTS_DIR/traffic-drop-udp6.cfg -Q -t 1 -- /bin/bash -c 'sleep 10'"
run_test "traffic rule: mixed IPv4/IPv6 rules" 137 \
	"$NSJAIL --config $TESTS_DIR/traffic-mixed.cfg -Q -t 1 -- /bin/bash -c 'sleep 10'"

# --- HOST_TO_GUEST inbound proxy (loopback only, no real IPv6 route needed) ---
run_test "HOST_TO_GUEST proxy forwards IPv4 and IPv6 loopback traffic" 77 \
	"{ $NSJAIL --config $TESTS_DIR/dns_http_host_to_guest.cfg -Q -t 3 & }; sleep 1; wget -4 -q -O /dev/null --timeout=5 http://127.0.0.1:8080/ && wget -6 -q -O /dev/null --timeout=5 http://[::1]:8080/ && exit 77"

# --- Mount/filesystem isolation (--experimental_mnt=old; =new is currently
# broken here whenever /tmp is already a tmpfs, see exclusions above) ---
OLD_EF="--experimental_mnt=old"
run_test "tmpfs mount is writable" 0 \
	"$NSJAIL $OLD_EF -Q -Mo --chroot / -m none:/tmp:tmpfs --user 99999 --group 99999 -- /bin/bash -c 'touch /tmp/nsjail_test && rm -f /tmp/nsjail_test'"
run_test "tmpfs:ro mount blocks writes" 77 \
	"$NSJAIL $OLD_EF -Q -Mo --chroot / -m none:/tmp:tmpfs:ro --user 99999 --group 99999 -- /bin/bash -c 'touch /tmp/nsjail_test || exit 77'"
run_test "-R (read-only bind) blocks writes" 77 \
	"$NSJAIL $OLD_EF -Q -Mo --chroot / -R /tmp --user 99999 --group 99999 -- /bin/bash -c 'touch /tmp/nsjail_test || exit 77'"
run_test "-B (read-write bind) allows writes" 0 \
	"$NSJAIL $OLD_EF -Q -Mo --chroot / -B /tmp --user 99999 --group 99999 -- /bin/bash -c 'touch /tmp/nsjail_test && rm -f /tmp/nsjail_test'"

# --- $HOME / /run/user/$UID mounts ---
if [ "$SKIP_CONTAINER_QUIRKS" = 1 ]; then
	skip_test "\$HOME mount is writable with --rw"
else
	run_test "\$HOME mount is writable with --rw" 0 \
		"$NSJAIL $OLD_EF -Q -Mo --rw --chroot / --user 99999 --group 99999 -- /bin/bash -c 'touch $HOME/nsjail_test_home && rm -f $HOME/nsjail_test_home'"
fi
run_test "\$HOME mount is read-only without --rw" 77 \
	"$NSJAIL $OLD_EF -Q -Mo --chroot / --user 99999 --group 99999 -- /bin/bash -c 'touch $HOME/nsjail_test_home || exit 77'"
if [ "$SKIP_CONTAINER_QUIRKS" = 1 ]; then
	skip_test "/run/user/\$UID is read-only without --rw (recursive submount remount)"
	skip_test "/run/user/\$UID is writable with --rw (recursive submount remount)"
else
	run_test "/run/user/\$UID is read-only without --rw (recursive submount remount)" 77 \
		"$NSJAIL $OLD_EF -Q -Mo --chroot / --user 99999 --group 99999 -- /bin/bash -c 'touch /run/user/$(id -u)/nsjail_test_run || exit 77'"
	run_test "/run/user/\$UID is writable with --rw (recursive submount remount)" 0 \
		"$NSJAIL $OLD_EF -Q -Mo --rw --chroot / --user 99999 --group 99999 -- /bin/bash -c 'touch /run/user/$(id -u)/nsjail_test_run && rm -f /run/user/$(id -u)/nsjail_test_run'"
fi

# --- exec_fd / execveat into an otherwise-empty mount namespace ---
# busybox sh reads commands from stdin; give it a source that never hits EOF
# so it actually blocks until time_limit kills it, instead of exiting 0 the
# instant stdin is /dev/null (as it is in a non-interactive CI step).
run_test "static busybox via exec_fd in an empty mount ns" 137 \
	"$NSJAIL --config $CONFIGS_DIR/static-busybox-with-execveat.cfg -Q -t 1 < /dev/zero"

if [ "$FAIL" -ne 0 ]; then
	echo -e "${RED}✗ Some smoke tests failed.${RESET}"
	exit 1
fi
echo -e "${GREEN}✓ All smoke tests passed.${RESET}"
