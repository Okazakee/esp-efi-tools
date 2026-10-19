#!/usr/bin/env bash
#
# test/consistency.sh
#
# Fast, VM-free check that the two halves of this tool agree with each other.
#
# install.sh decides where things go on the ESP. The .nsh scripts hardcode the
# path they expect. If those two ever drift, install.sh will happily create a
# folder that the scripts then fail to find, and the only symptom is an empty
# directory listing on a machine that is otherwise fine. That is exactly the kind
# of breakage that is invisible until someone is standing at a firmware prompt,
# so it is worth a test that runs in a fraction of a second.
#
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ok() { printf '  ok   %s\n' "$*"; }
fail() {
	printf '\nFAIL: %s\n' "$*" >&2
	exit 1
}

# Read a constant out of install.sh. Tolerates a trailing comment.
get_const() {
	sed -n "s/^$1=\"\([^\"]*\)\".*/\1/p" install.sh | head -1
}

TOOL_DIRNAME="$(get_const TOOL_DIRNAME)"
[ -n "$TOOL_DIRNAME" ] || fail "could not read TOOL_DIRNAME from install.sh"

# The canonical layout, derived from that one constant.
EFI_DIR="EFI/$TOOL_DIRNAME"
DROP_DIR="$EFI_DIR/firmware"
SHELL_REL="$EFI_DIR/Shellx64.efi"
DROP_WIN="\\${DROP_DIR//\//\\}"

# --- install.sh's own constants must agree with the canonical layout ---------

[ "$(get_const EFI_DIR)" = "EFI/\$TOOL_DIRNAME" ] ||
	fail "install.sh EFI_DIR is '$(get_const EFI_DIR)', expected 'EFI/\$TOOL_DIRNAME'"
ok "install.sh EFI_DIR is EFI/\$TOOL_DIRNAME (i.e. $EFI_DIR)"

[ "$(get_const DROP_DIR)" = "\$EFI_DIR/firmware" ] ||
	fail "install.sh DROP_DIR is '$(get_const DROP_DIR)', expected '\$EFI_DIR/firmware'"
ok "install.sh DROP_DIR is \$EFI_DIR/firmware"

[ "$(get_const SHELL_REL)" = "\$EFI_DIR/Shellx64.efi" ] ||
	fail "install.sh SHELL_REL is '$(get_const SHELL_REL)', expected '\$EFI_DIR/Shellx64.efi'"
ok "install.sh SHELL_REL is \$EFI_DIR/Shellx64.efi"

# --- the scripts must point at that same folder ------------------------------

for f in files/startup.nsh files/flash.nsh; do
	[ -f "$f" ] || fail "missing $f"
	grep -qF -- "$DROP_WIN" "$f" ||
		fail "$f does not reference $DROP_WIN (drifted from install.sh's DROP_DIR?)"
	ok "$f references $DROP_WIN"
done

# --- mutual references ------------------------------------------------------

grep -qF -- 'flash.nsh' files/startup.nsh ||
	fail "startup.nsh never tells the user about flash.nsh"
ok "startup.nsh points at flash.nsh"

grep -qF -- 'flash.nsh' files/flash.nsh ||
	fail "flash.nsh does not name itself, so it cannot re-locate the drop folder"
ok "flash.nsh names itself (needed for self-location)"

# --- firmware constraints ---------------------------------------------------

# Several firmwares refuse a boot entry whose loader is not under \EFI\.
case "$SHELL_REL" in
EFI/*) ok "the shell lives under EFI/ (required by some firmware)" ;;
*) fail "SHELL_REL is not under EFI/: $SHELL_REL" ;;
esac

# The ESP has to be FAT: the firmware itself must be able to read, and possibly
# write, the drop folder. install.sh enforces this; assert it still does.
grep -qE 'vfat \| fat \| msdos\)' install.sh ||
	fail "install.sh no longer restricts the ESP to FAT"
ok "install.sh still requires a FAT ESP"

# --- optional lint ----------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
	# -S warning: fail on real problems, not on style suggestions.
	shellcheck -S warning install.sh uninstall.sh test/smoke-test.sh test/consistency.sh ||
		fail "shellcheck reported problems"
	ok "shellcheck clean"
else
	printf '  ..   shellcheck not installed, skipping lint\n'
fi

printf '==> consistency checks passed\n'
