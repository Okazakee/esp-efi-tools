#!/usr/bin/env bash
#
# esp-efi-tools - uninstall
#
# Removes everything install.sh put in place: the boot entry, the shell, the
# startup.nsh helper and the drop folder. Nothing else on the ESP is touched.
#
set -euo pipefail

TOOL_DIRNAME="esp-efi-tools"
EFI_DIR="EFI/$TOOL_DIRNAME"
DROP_DIR="$EFI_DIR/firmware"
SHELL_REL="$EFI_DIR/Shellx64.efi"
STARTUP_REL="startup.nsh"
DEFAULT_LABEL="esp-efi-tools"

ESP=""
LABEL="$DEFAULT_LABEL"
DRY_RUN=0
KEEP_DROP=0
DO_LIMINE=0

usage() {
	cat <<-'EOF'
	Usage: uninstall.sh [options]

	  --esp PATH        ESP mount point (default: auto-detect)
	  --label NAME      boot entry label to remove (default: esp-efi-tools)
	  --keep-drop       keep the drop folder, i.e. keep your firmware files
	  --limine          also remove the Limine entry
	  --dry-run         show what would happen, change nothing
	  -h, --help        this help
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--esp) ESP="${2:-}"; shift 2 ;;
	--label) LABEL="${2:-}"; shift 2 ;;
	--keep-drop) KEEP_DROP=1; shift ;;
	--limine) DO_LIMINE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
	esac
done

step() { printf '==> %s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
run() {
	if [ "$DRY_RUN" = 1 ]; then
		printf '  [dry-run] %s\n' "$*"
	else
		"$@"
	fi
}

[ "$(id -u)" = 0 ] || die "must run as root (the ESP is normally root-only)"

if [ -z "$ESP" ]; then
	for cand in /boot/efi /efi /boot; do
		if findmnt -no FSTYPE --target "$cand" >/dev/null 2>&1; then
			ESP="$cand"
			break
		fi
	done
fi
[ -n "$ESP" ] || die "could not find the ESP; pass --esp PATH"
[ -d "$ESP" ] || die "no such directory: $ESP"

# ------------------------------------------------------------- boot entries

step "removing firmware boot entries labelled \"$LABEL\""
if command -v efibootmgr >/dev/null 2>&1 && [ -d /sys/firmware/efi/efivars ]; then
	ids="$(efibootmgr 2>/dev/null | sed -n "s/^\(Boot[0-9A-Fa-f]\{4\}\)\*[[:space:]]*${LABEL}[[:space:]]*$/\1/p" || true)"
	if [ -z "$ids" ]; then
		echo "    none found"
	else
		for id in $ids; do
			run efibootmgr -b "$id" -B >/dev/null
			echo "    removed $id"
		done
	fi
else
	warn "efibootmgr unavailable; remove the entry in your firmware setup"
fi

# ------------------------------------------------------------------- limine

if [ "$DO_LIMINE" = 1 ]; then
	step "removing the Limine entry"
	if command -v limine-entry-tool >/dev/null 2>&1; then
		run limine-entry-tool --remove-efi-path "$ESP/$SHELL_REL" --keep-files
	else
		warn "limine-entry-tool not found; delete the /$LABEL block from limine.conf"
	fi
fi

# -------------------------------------------------------------------- files

step "removing files"
run rm -f "$ESP/$SHELL_REL"

# Only ever delete startup.nsh if it is ours. Never stomp somebody else's.
if [ -f "$ESP/$STARTUP_REL" ]; then
	if grep -q 'esp-efi-tools' "$ESP/$STARTUP_REL" 2>/dev/null; then
		run rm -f "$ESP/$STARTUP_REL"
		echo "    removed $ESP/$STARTUP_REL"
	else
		warn "$ESP/$STARTUP_REL is not ours; leaving it alone"
	fi
fi

if [ "$KEEP_DROP" = 1 ]; then
	run rm -f "$ESP/$DROP_DIR/flash.nsh" "$ESP/$DROP_DIR/README.txt"
	echo "    kept $ESP/$DROP_DIR (your firmware files are still there)"
else
	run rm -rf "$ESP/$DROP_DIR"
fi

# Tidy up the tool directory, but only if it is now empty.
if [ -d "$ESP/$EFI_DIR" ]; then
	run rmdir "$ESP/$EFI_DIR" 2>/dev/null || true
fi

printf '\n%s\n' "$( [ "$DRY_RUN" = 1 ] && echo "Dry run complete. Nothing was changed." || echo "Uninstalled." )"
