#!/usr/bin/env bash
#
# test/install-guards.sh
#
# Behavioural checks on install.sh. Needs root, because install.sh refuses to run
# as anything else, and needs no VM.
#
# These exist because of two real bugs, both found by installing onto an actual
# machine rather than by reasoning about it:
#
#   1. findmnt answers for ANY path by reporting the filesystem that CONTAINS it.
#      So on a machine whose ESP is mounted at /boot, "findmnt --target /boot/efi"
#      happily answers "/boot". An earlier install.sh trusted the candidate path
#      instead, and installed the shell to <esp>/efi/EFI/esp-efi-tools/ while
#      telling the firmware to boot <esp>/EFI/esp-efi-tools/. The entry was
#      silently dead - it simply would not start, with no error anywhere.
#
#   2. efibootmgr -o wants bare IDs ("0006"), not the "Boot0006" form used in its
#      own listings. Passing the prefixed form is rejected, so BootOrder never got
#      restored and the machine was left booting the EFI shell ahead of the OS.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ok() { printf '  ok   %s\n' "$*"; }
skip() { printf '  ..   skipped: %s\n' "$*"; }
fail() {
	printf '\nFAIL: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" = 0 ] || fail "must run as root (install.sh refuses otherwise)"

WORK="$(mktemp -d)"
CLEANUP_MNT=""
cleanup() {
	[ -n "$CLEANUP_MNT" ] && umount "$CLEANUP_MNT" 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

# --- install.sh must refuse anything that is not a real mount point ----------

expect_failure() {
	local desc="$1" want="$2"
	shift 2
	local out rc
	if out="$(./install.sh "$@" 2>&1)"; then
		rc=0
	else
		rc=$?
	fi
	[ "$rc" -ne 0 ] || fail "$desc: install.sh exited 0, expected a refusal"
	# here-string rather than a pipe: grep -q closes early, and pipefail would
	# turn the resulting SIGPIPE into a false failure.
	grep -qF -- "$want" <<<"$out" ||
		fail "$desc: expected output to mention '$want', got: $out"
	ok "$desc"
}

expect_failure "refuses a path that does not exist" "does not exist" \
	--esp "$WORK/definitely-not-here" --dry-run

# The regression test for bug 1. $WORK sits under some real mount point, so it is
# a subdirectory of a mount rather than a mount itself - exactly the /boot/efi
# situation that broke.
mkdir -p "$WORK/not-a-mountpoint"
expect_failure "refuses a subdirectory of a mount point" "not itself a mount point" \
	--esp "$WORK/not-a-mountpoint" --dry-run

# --- best effort: a full install/uninstall round trip on a real FAT image ----
#
# Skipped where mounting is not permitted (most containers), which is also why
# bug 1 was not caught here: this path passes --esp, bypassing auto-detection.

roundtrip_possible() {
	command -v losetup >/dev/null 2>&1 || return 1
	command -v mkfs.vfat >/dev/null 2>&1 || return 1
	losetup -f >/dev/null 2>&1 || return 1
	[ -e /dev/loop-control ] || [ -e /dev/loop0 ] || return 1
	return 0
}

if roundtrip_possible; then
	IMG="$WORK/esp.img"
	MNT="$WORK/mnt"
	truncate -s 64M "$IMG"
	mkfs.vfat "$IMG" >/dev/null
	mkdir -p "$MNT"
	if mount -o loop,rw "$IMG" "$MNT" 2>/dev/null; then
		CLEANUP_MNT="$MNT"

		./install.sh --esp "$MNT" --no-boot-entry >/dev/null ||
			fail "install.sh failed on a real FAT mount"
		ok "install.sh completed on a real FAT mount"

		for want in \
			"EFI/esp-efi-tools/Shellx64.efi" \
			"EFI/esp-efi-tools/firmware/flash.nsh" \
			"startup.nsh"; do
			[ -f "$MNT/$want" ] || fail "install.sh did not create $want"
		done
		ok "install.sh placed every expected file"

		./uninstall.sh --esp "$MNT" >/dev/null || fail "uninstall.sh failed"
		[ ! -e "$MNT/EFI/esp-efi-tools" ] || fail "uninstall.sh left the tool directory"
		[ ! -e "$MNT/startup.nsh" ] || fail "uninstall.sh left startup.nsh"
		ok "uninstall.sh removed everything it created"

		umount "$MNT"
		CLEANUP_MNT=""
	else
		skip "could not mount a loop device, so no install round trip"
	fi
else
	skip "no loop device support, so no install round trip"
fi

printf '==> install guards passed\n'
