#!/usr/bin/env bash
#
# test/smoke-test.sh
#
# Proves the scripts actually work by booting a real UEFI implementation (OVMF)
# with a real EDK2 shell, then driving it like a user would:
#
#   shell boots -> startup.nsh runs -> "flash.nsh" typed -> an EFI app executes
#
# The "flasher" is test/fake_flasher.c: a 6-byte application that does nothing
# at all (mov eax; ret). This test never ships, downloads or executes vendor
# firmware. Because the fixture is deliberately inert, the assertions are about
# the chain around it - the app is launched by the firmware and returns cleanly.
#
# Usage:  test/smoke-test.sh [--verbose] [--keep]
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DROP_PATH='EFI/esp-efi-tools/firmware'
BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"

VERBOSE=0
KEEP=0
for arg in "$@"; do
	case "$arg" in
	--verbose | -v) VERBOSE=1 ;;
	--keep | -k) KEEP=1 ;;
	-h | --help)
		sed -n '2,14p' "$0"
		exit 0
		;;
	*) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
	esac
done

WORK="$(mktemp -d)"
QEMU_PID=""
cleanup() {
	if [ -n "$QEMU_PID" ]; then
		kill "$QEMU_PID" 2>/dev/null || true
		wait "$QEMU_PID" 2>/dev/null || true
	fi
	if [ "$KEEP" = 1 ]; then
		printf '\n(work dir kept at %s)\n' "$WORK"
	else
		rm -rf "$WORK"
	fi
}
trap cleanup EXIT

ok() { printf '  ok   %s\n' "$*"; }
info() { printf '  ..   %s\n' "$*"; }
dump_log() {
	printf '\n---- serial output ----\n' >&2
	if [ -n "${CLEAN:-}" ] && declare -F refresh_log >/dev/null 2>&1; then
		refresh_log
		cat "$CLEAN" >&2
	else
		printf '(no serial output captured yet)\n' >&2
	fi
	printf -- '---- end ----\n\n' >&2
}
fail() {
	printf '\nFAIL: %s\n' "$*" >&2
	dump_log
	exit 1
}

# ---------------------------------------------------------------- locate bits

first_existing() {
	local p
	for p in "$@"; do
		if [ -f "$p" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	done
	return 1
}

CODE="${OVMF_CODE:-$(first_existing \
	/usr/share/edk2/x64/OVMF_CODE.4m.fd \
	/usr/share/OVMF/OVMF_CODE_4M.fd \
	/usr/share/OVMF/OVMF_CODE.fd || true)}"
VARS_SRC="${OVMF_VARS:-$(first_existing \
	/usr/share/edk2/x64/OVMF_VARS.4m.fd \
	/usr/share/OVMF/OVMF_VARS_4M.fd \
	/usr/share/OVMF/OVMF_VARS.fd || true)}"
SHELL_EFI="${EDK2_SHELL:-$(first_existing \
	/usr/share/edk2-shell/x64/Shell_Full.efi \
	/usr/share/edk2/x64/Shell_Full.efi \
	/usr/share/OVMF/Shell_Full.efi \
	/usr/share/OVMF/Shell.efi || true)}"

[ -n "$CODE" ] || fail "OVMF code image not found. Set OVMF_CODE=/path/to/OVMF_CODE.fd"
[ -n "$VARS_SRC" ] || fail "OVMF vars template not found. Set OVMF_VARS=/path/to/OVMF_VARS.fd"
if [ -z "$SHELL_EFI" ]; then
	cat >&2 <<-'EOF'

	FAIL: no EDK2 UEFI shell found, so there is nothing to boot.

	This test needs one for the same reason install.sh does. Arch packages one:

	    sudo pacman -S edk2-shell

	Debian/Ubuntu do not package one at all (ovmf ships firmware blobs only).
	Your vendor's firmware update package often contains one, e.g. TUXEDO's
	Shellx64.efi. Point at it directly:

	    EDK2_SHELL=/path/to/Shellx64.efi test/smoke-test.sh
	EOF
	exit 1
fi

for tool in qemu-system-x86_64 mkfs.vfat mmd mcopy; do
	command -v "$tool" >/dev/null 2>&1 || fail "missing required tool: $tool"
done

info "OVMF code  : $CODE"
info "OVMF vars  : $VARS_SRC"
info "EDK2 shell : $SHELL_EFI"

# ------------------------------------------------- build the stand-in flasher

FAKE_EFI="$WORK/FakeFlasher.efi"
if [ -n "${FAKE_FLASHER_EFI:-}" ] && [ -f "${FAKE_FLASHER_EFI:-}" ]; then
	cp "$FAKE_FLASHER_EFI" "$FAKE_EFI"
	info "using prebuilt stand-in flasher: $FAKE_FLASHER_EFI"
else
	for tool in clang lld-link; do
		command -v "$tool" >/dev/null 2>&1 ||
			fail "missing build tool: $tool (needed to build the stand-in flasher)"
	done
	clang -target x86_64-unknown-windows -ffreestanding -fno-stack-protector \
		-fshort-wchar -mno-red-zone -Os \
		-c "$REPO_ROOT/test/fake_flasher.c" -o "$WORK/fake_flasher.o"
	lld-link -subsystem:efi_application -entry:efi_main -nodefaultlib \
		-out:"$FAKE_EFI" "$WORK/fake_flasher.o"
fi
ok "stand-in flasher ready ($(stat -c %s "$FAKE_EFI") bytes)"
file "$FAKE_EFI" | grep -qE 'PE32\+.*EFI.*application' ||
	fail "the stand-in flasher is not a valid EFI application"
ok "stand-in flasher is a valid EFI application"

# ------------------------------------------- build the ESP image as a user has it

IMG="$WORK/esp.img"
truncate -s 64M "$IMG"
mkfs.vfat "$IMG" >/dev/null

mmd -i "$IMG" ::/EFI ::/EFI/BOOT ::/EFI/esp-efi-tools "::/$DROP_PATH" 2>/dev/null || true
mcopy -i "$IMG" "$SHELL_EFI" ::/EFI/BOOT/BOOTX64.EFI
mcopy -i "$IMG" "$REPO_ROOT/files/startup.nsh" ::/startup.nsh
mcopy -i "$IMG" "$REPO_ROOT/files/flash.nsh" "::/$DROP_PATH/flash.nsh"
mcopy -i "$IMG" "$FAKE_EFI" "::/$DROP_PATH/FakeFlasher.efi"
ok "ESP image built (shell + startup.nsh + drop folder)"

# -------------------------------------------------------------------- boot it

cp "$VARS_SRC" "$WORK/vars.fd"
LOG="$WORK/serial.log"
CLEAN="$WORK/serial.clean"
: >"$LOG"
: >"$CLEAN"

FIFO="$WORK/stdin"
mkfifo "$FIFO"
exec 9<>"$FIFO" # hold both ends open so the guest never sees EOF

qemu-system-x86_64 \
	-machine "q35,accel=kvm:tcg" -m 1024 -no-reboot \
	-drive "if=pflash,format=raw,readonly=on,file=$CODE" \
	-drive "if=pflash,format=raw,file=$WORK/vars.fd" \
	-drive "file=$IMG,format=raw,if=virtio" \
	-display none -monitor none -serial stdio \
	<"$FIFO" >"$LOG" 2>&1 &
QEMU_PID=$!
info "qemu pid $QEMU_PID, accel=kvm:tcg"

# Strip the VT100 escapes OVMF emits, so plain text can be asserted on.
refresh_log() {
	sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r//g' "$LOG" >"$CLEAN" 2>/dev/null || true
}

guest_alive() { kill -0 "$QEMU_PID" 2>/dev/null; }

wait_for() {
	local needle="$1" timeout="${2:-$BOOT_TIMEOUT}" deadline
	deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ]; do
		refresh_log
		if grep -qF -- "$needle" "$CLEAN"; then return 0; fi
		if ! guest_alive; then return 1; fi
		sleep 0.25
	done
	return 1
}

# Same, but for a regular expression. Needed because the shell expands the glob
# in "for %i in *.efi" to a full device path, e.g. "Running: FS0:\...\Foo.efi",
# so the leading part is not predictable.
wait_for_re() {
	local pattern="$1" timeout="${2:-$BOOT_TIMEOUT}" deadline
	deadline=$((SECONDS + timeout))
	while [ "$SECONDS" -lt "$deadline" ]; do
		refresh_log
		if grep -qE -- "$pattern" "$CLEAN"; then return 0; fi
		if ! guest_alive; then return 1; fi
		sleep 0.25
	done
	return 1
}

# ---------------------------------------------------------------- assertions

printf '==> booting, waiting for startup.nsh\n'
wait_for "esp-efi-tools: firmware staging" ||
	fail "startup.nsh never ran its banner (timeout ${BOOT_TIMEOUT}s)"
ok "shell booted and startup.nsh executed"

wait_for "FakeFlasher.efi" ||
	fail "startup.nsh did not list the drop folder - 'cd \\EFI\\esp-efi-tools\\firmware' failed?"
ok "startup.nsh changed into the drop folder and listed its contents"

wait_for "flash.nsh" ||
	fail "drop folder listing did not include flash.nsh"
ok "drop folder contains flash.nsh"

printf '==> typing flash.nsh\n'
printf 'flash.nsh\r' >&9

wait_for "esp-efi-tools: running the flasher in this folder" ||
	fail "flash.nsh was never started by the shell"
ok "flash.nsh ran"

wait_for_re 'Running: .*FakeFlasher\.efi' ||
	fail "flash.nsh did not announce the flasher (glob '*.efi' found nothing?)"
ok "flash.nsh globbed up the flasher by name"

# Reaching "Finished." means the loop completed, i.e. the firmware loaded and ran
# the application and control returned. The negative check below ensures that
# happened without a load error being reported.
wait_for "Finished. To reboot" ||
	fail "flash.nsh never reached the end of the loop (the app did not return?)"
ok "the .efi was launched by the firmware and returned cleanly"

# Let the rest of the output land before the negative check.
sleep 1
refresh_log

# Negative assertions. These are regression tests for two EDK2 shell quirks that
# were both hit for real while building this:
#   * "echo: Unknown flag - '-'"          - a lone dash in an echoed message
#   * "Current directory not specified"   - cd'ing before selecting the volume
if grep -qE 'Command Error|is not recognized|not found|Unknown flag|Current directory not specified|is not a directory' "$CLEAN"; then
	fail "the shell reported an error while running the scripts"
fi
ok "no shell errors (no bogus flags, no missing current directory)"

printf '==> all assertions passed\n'
if [ "$VERBOSE" = 1 ]; then
	dump_log
fi
exit 0
