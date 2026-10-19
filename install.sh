#!/usr/bin/env bash
#
# esp-efi-tools - install
#
# Puts an EFI shell and a drop folder on your EFI System Partition, and gives
# you a boot menu entry to reach them. Firmware you download from your vendor's
# own update utility can then be launched from internal storage instead of a
# USB stick.
#
#   THIS SCRIPT NEVER DOWNLOADS, INSTALLS OR WRITES FIRMWARE.
#   It does not modify, repack, resign or bypass anything. The flashing, and all
#   of its risk, remains entirely with the vendor's own tool.
#
set -euo pipefail

# ------------------------------------------------------------------ constants

TOOL_DIRNAME="esp-efi-tools"
EFI_DIR="EFI/$TOOL_DIRNAME"           # on the ESP, under \EFI\ (some firmware requires this)
DROP_DIR="$EFI_DIR/firmware"          # where the vendor flasher is dropped
DROP_DIR_WIN="\\${DROP_DIR//\//\\}"   # the same path as the EFI shell sees it
SHELL_REL="$EFI_DIR/Shellx64.efi"     # the EDK2 shell
SHELL_REL_WIN="\\${SHELL_REL//\//\\}" # same path as a firmware boot entry wants it
STARTUP_REL="startup.nsh"             # at the ESP root, so the shell auto-runs it
DEFAULT_LABEL="esp-efi-tools"
MIN_FREE_MB=32

# ----------------------------------------------------------------------- args

ESP=""
LABEL="$DEFAULT_LABEL"
DRY_RUN=0
DO_BOOT_ENTRY=1
DO_LIMINE=0
QUIET=0
SHELL_OVERRIDE=""

usage() {
	sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
	cat <<-'EOF'

	Usage: install.sh [options]

	  --esp PATH        ESP mount point (default: auto-detect)
	  --label NAME      boot entry label (default: esp-efi-tools)
	  --shell PATH      EDK2 shell to install (default: from a distribution package)
	  --no-boot-entry   place the files but do not add a firmware boot entry
	  --limine          also add a Limine entry (needs limine-entry-tool)
	  --dry-run         show what would happen, change nothing
	  --quiet           less chatter
	  -h, --help        this help

	Everything happens under <ESP>/EFI/esp-efi-tools/ plus <ESP>/startup.nsh.
	EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--esp) ESP="${2:-}"; shift 2 ;;
	--label) LABEL="${2:-}"; shift 2 ;;
	--shell) SHELL_OVERRIDE="${2:-}"; shift 2 ;;
	--no-boot-entry) DO_BOOT_ENTRY=0; shift ;;
	--limine) DO_LIMINE=1; shift ;;
	--dry-run) DRY_RUN=1; shift ;;
	--quiet) QUIET=1; shift ;;
	-h | --help) usage; exit 0 ;;
	*) printf 'unknown option: %s (try --help)\n' "$1" >&2; exit 2 ;;
	esac
done

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
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

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$REPO_ROOT/files/startup.nsh" ] || die "cannot find files/startup.nsh next to this script"

# ------------------------------------------------------------------- preamble

[ "$(id -u)" = 0 ] || die "must run as root (the ESP is normally root-only)"
[ -d /sys/firmware/efi ] || die "not booted in UEFI mode - this tool is UEFI only"

step "looking for the EFI System Partition"

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

# findmnt answers for ANY path by reporting the filesystem that contains it. So
# on a machine where the ESP is mounted at /boot, "findmnt --target /boot/efi"
# cheerfully answers "/boot" - which is how an earlier version of this script
# ended up writing to <esp>/efi/EFI/esp-efi-tools/ while telling the firmware to
# look in <esp>/EFI/esp-efi-tools/. Hence: a path is only usable if findmnt's
# TARGET is that path itself.
mount_target_of() {
	findmnt -no TARGET --target "$1" 2>/dev/null || true
}

is_esp_mountpoint() {
	local cand="$1" src
	[ -d "$cand" ] || return 1
	[ "$(mount_target_of "$cand")" = "$cand" ] || return 1
	src="$(findmnt -no SOURCE --target "$cand" 2>/dev/null || true)"
	[ -n "$src" ] || return 1
	[ "$(lsblk -no PARTTYPE "$src" 2>/dev/null || true)" = "$ESP_GUID" ]
}

detect_esp() {
	local cand src tgt fstype
	# 1. a conventional mount point that really is a mount point, and really is
	#    the ESP according to the GPT partition type GUID
	for cand in /boot/efi /efi /boot; do
		if is_esp_mountpoint "$cand"; then
			printf '%s' "$cand"
			return 0
		fi
	done
	# 2. any mounted FAT filesystem that is the ESP by GUID, wherever it is
	while read -r src tgt; do
		[ -n "$src" ] || continue
		if [ "$(lsblk -no PARTTYPE "$src" 2>/dev/null || true)" = "$ESP_GUID" ]; then
			printf '%s' "$tgt"
			return 0
		fi
	done < <(findmnt -rno SOURCE,TARGET -t vfat,fat,msdos 2>/dev/null)
	# 3. last resort: /boot itself, if it is a FAT mount point. Some images are
	#    created without the ESP type GUID, and refusing those helps nobody.
	if [ "$(mount_target_of /boot)" = "/boot" ]; then
		fstype="$(findmnt -no FSTYPE --target /boot 2>/dev/null || true)"
		case "$fstype" in
		vfat | fat | msdos)
			printf '%s' "/boot"
			return 0
			;;
		esac
	fi
	return 1
}

if [ -z "$ESP" ]; then
	ESP="$(detect_esp || true)"
fi

if [ -z "$ESP" ]; then
	die "could not find the ESP. Mount it and pass --esp, e.g.:
       sudo mkdir -p /mnt/esp && sudo mount /dev/nvme0n1p1 /mnt/esp
       sudo $0 --esp /mnt/esp"
fi

[ -d "$ESP" ] || die "--esp path does not exist: $ESP"

# Must be the mount point itself, not merely somewhere under one. See the note
# on mount_target_of above.
[ "$(mount_target_of "$ESP")" = "$ESP" ] ||
	die "$ESP is not itself a mount point (the filesystem there is mounted at $(mount_target_of "$ESP")). Mount it and re-run with --esp <mountpoint>."

ESP_DEV="$(findmnt -no SOURCE --target "$ESP")"
ESP_FS="$(findmnt -no FSTYPE --target "$ESP")"
ESP_OPTS="$(findmnt -no OPTIONS --target "$ESP")"

# The firmware needs to be able to read this volume itself, and may need to
# write to it (capsule staging). UEFI only speaks FAT.
case "$ESP_FS" in
vfat | fat | msdos) ;;
*) die "the ESP must be FAT (found '$ESP_FS' on $ESP_DEV): the firmware cannot read anything else" ;;
esac

# Mount options are comma separated, so match a whole field. A substring test
# would trip over "errors=remount-ro", which is not read-only.
case ",$ESP_OPTS," in
*,ro,*) die "$ESP is mounted read-only. Remount rw and retry." ;;
esac

# df -P and --output are mutually exclusive on coreutils; use the POSIX layout
# and take the "Available" column (in MB because of -m).
free_mb="$(df -Pm "$ESP" 2>/dev/null | tail -1 | awk '{print $4}')"
case "${free_mb:-}" in '' | *[!0-9]*) free_mb=0 ;; esac
[ "$free_mb" -ge "$MIN_FREE_MB" ] || die "only ${free_mb}MB free on $ESP (want at least ${MIN_FREE_MB}MB)"

say "    ESP      : $ESP"
say "    device   : $ESP_DEV ($ESP_FS, ${free_mb}MB free)"

# --------------------------------------------------------- secure boot warning

sb=0
for f in /sys/firmware/efi/efivars/SecureBoot-*; do
	[ -f "$f" ] || continue
	# efivar layout: 4 bytes of attributes, then the value
	sb="$(od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ' || echo 0)"
done
if [ "${sb:-0}" = 1 ]; then
	warn "Secure Boot is ENABLED."
	warn "Some bootloaders will only chainload files with a verification hash"
	warn "(Limine v12 panics without one), and some firmware refuses unsigned"
	warn "chainloads outright. If the entry does not work, either disable Secure"
	warn "Boot for the update or add the hash your bootloader wants."
fi

# ------------------------------------------------------------------ the shell

step "locating an EDK2 UEFI shell"

SHELL_SRC=""
if [ -n "$SHELL_OVERRIDE" ]; then
	[ -f "$SHELL_OVERRIDE" ] || die "--shell: no such file: $SHELL_OVERRIDE"
	SHELL_SRC="$SHELL_OVERRIDE"
else
	for cand in \
		/usr/share/edk2-shell/x64/Shell_Full.efi \
		/usr/share/edk2/x64/Shell_Full.efi \
		/usr/share/OVMF/Shell_Full.efi \
		/usr/share/OVMF/Shell.efi \
		/usr/share/edk2-shell/x64/Shell.efi; do
		[ -f "$cand" ] && SHELL_SRC="$cand" && break
	done
fi

if [ -z "$SHELL_SRC" ]; then
	cat >&2 <<-'EOF'
	error: no EDK2 UEFI shell found.

	An EFI shell is the one piece this tool cannot supply, and packaging is
	inconsistent. Pick whichever applies:

	  Arch / CachyOS / EndeavourOS
	      sudo pacman -S edk2-shell

	  Fedora
	      sudo dnf install edk2-shell

	  Debian / Ubuntu
	      Not packaged. Neither ovmf nor anything else ships a shell.

	  Your vendor's own firmware update package
	      These very often include one (TUXEDO calls it Shellx64.efi, sitting
	      next to startup.nsh). That is usually the easiest source.

	Then either put it somewhere the search above finds, or point at it:

	    sudo ./install.sh --shell /path/to/Shellx64.efi

	This tool deliberately does not download the shell, or anything else.
	EOF
	exit 1
fi
say "    shell    : $SHELL_SRC"

# -------------------------------------------------------------- place the files

step "installing files"

say "    $ESP/$SHELL_REL"
run mkdir -p "$ESP/$EFI_DIR"
run cp "$SHELL_SRC" "$ESP/$SHELL_REL"

say "    $ESP/$DROP_DIR/flash.nsh"
run mkdir -p "$ESP/$DROP_DIR"
run cp "$REPO_ROOT/files/flash.nsh" "$ESP/$DROP_DIR/flash.nsh"

# The drop folder must look like a drop folder. This is the only thing standing
# between a user and an unexplained "glob found nothing", so be explicit.
if [ "$DRY_RUN" = 0 ]; then
	mkdir -p "$ESP/$DROP_DIR"
	cat >"$ESP/$DROP_DIR/README.txt" <<-'EOF'
	Drop your vendor's firmware update application (a .efi file) into this
	folder, then boot the "esp-efi-tools" entry from your boot menu and type:

	    flash.nsh

	KEEP EXACTLY ONE .efi FILE HERE. flash.nsh runs every .efi it finds, so two
	files means two flashes. Delete the old one when you add a new one.

	This folder is just a staging area on your ESP. Nothing here runs by
	itself: the flasher only starts when you type flash.nsh.
	EOF
fi
say "    $ESP/$DROP_DIR/README.txt"

# startup.nsh lives at the ESP root so the shell picks it up automatically.
# Never silently replace somebody else's.
if [ -e "$ESP/$STARTUP_REL" ] && ! grep -q 'esp-efi-tools' "$ESP/$STARTUP_REL" 2>/dev/null; then
	warn "$ESP/$STARTUP_REL already exists and is not ours."
	warn "Leaving it alone. Your shell will not auto-print the instructions, so"
	warn "run 'flash.nsh' manually after selecting the volume with a bare fs0:."
else
	say "    $ESP/$STARTUP_REL"
	run cp "$REPO_ROOT/files/startup.nsh" "$ESP/$STARTUP_REL"
fi

# ------------------------------------------------------------- firmware entry

if [ "$DO_BOOT_ENTRY" = 1 ]; then
	step "adding a firmware boot entry"

	if [ ! -d /sys/firmware/efi/efivars ]; then
		warn "efivarfs not available; skipping. Add the entry yourself:"
		warn "  $SHELL_REL_WIN"
	elif ! command -v efibootmgr >/dev/null 2>&1; then
		warn "efibootmgr not installed; skipping. Install it and add the entry:"
		warn "  $SHELL_REL_WIN"
	else
		disk="$(lsblk -no PKNAME "$ESP_DEV" 2>/dev/null | head -1 || true)"
		partnum="$(cat "/sys/class/block/$(basename "$ESP_DEV")/partition" 2>/dev/null || true)"

		if [ -z "$disk" ] || [ -z "$partnum" ]; then
			warn "could not work out which disk/partition $ESP_DEV is; skipping entry."
		else
			before="$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | sort || true)"
			old_order="$(efibootmgr 2>/dev/null | sed -n 's/^BootOrder:[[:space:]]*//p' | tr -d ' ' || true)"

			if [ "$DRY_RUN" = 1 ]; then
				printf '  [dry-run] efibootmgr -c -d /dev/%s -p %s -l "%s" -L "%s"\n' \
					"$disk" "$partnum" "$SHELL_REL_WIN" "$LABEL"
			else
				efibootmgr -c -d "/dev/$disk" -p "$partnum" \
					-l "$SHELL_REL_WIN" -L "$LABEL" >/dev/null ||
					warn "efibootmgr failed to create the entry"
			fi

			if [ "$DRY_RUN" = 0 ]; then
				# IDs are bare 4-digit hex: "0006", not "Boot0006". Passing the
				# prefixed form to -o is rejected and the order never gets
				# restored, which leaves the machine booting this shell first.
				after="$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\).*/\1/p' | sort || true)"
				new_id="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -1 || true)"

				if [ -n "$new_id" ]; then
					# efibootmgr -c PREPENDS the new entry to BootOrder, which would
					# make the machine boot this shell instead of the OS. Put the
					# original order back and append the new entry at the end.
					if [ -n "$old_order" ]; then
						efibootmgr -o "${old_order},${new_id}" >/dev/null ||
							warn "could not restore BootOrder; check 'efibootmgr' by hand" 
					fi
					say "    entry $new_id \"$LABEL\" -> $SHELL_REL_WIN"
					say "    boot order restored: $(efibootmgr | sed -n 's/^BootOrder:[[:space:]]*/&/p')"
				else
					warn "created the entry but could not identify it to fix BootOrder."
					warn "Run 'efibootmgr' and make sure your OS entry is still first."
				fi
			fi
		fi
	fi
fi

# ------------------------------------------------------------------ limine hint

if [ "$DO_LIMINE" = 1 ]; then
	step "adding a Limine entry"
	if command -v limine-entry-tool >/dev/null 2>&1; then
		run limine-entry-tool --add-efi "$LABEL" "$ESP/$SHELL_REL" \
			--comment "Firmware staging: copy a flasher into $DROP_DIR, then run flash.nsh" \
			--priority 5
		say "    done (managed by limine-entry-tool, so it survives kernel updates)"
	else
		warn "limine-entry-tool not found. Add this to your limine.conf by hand:"
		warn ""
		warn "  /$LABEL"
		warn "      protocol: efi"
		warn "      path: boot():/$SHELL_REL"
		warn ""
		warn "Use a low order-priority so it does not become the default entry."
	fi
fi

# ---------------------------------------------------------------------- done

cat <<EOF

$( [ "$DRY_RUN" = 1 ] && echo "Dry run complete. Nothing was changed." || echo "Installed." )

  1. Put your vendor's firmware flasher (.efi) into:

         $ESP/$DROP_DIR/

     Delete any older flasher in there first: flash.nsh runs every .efi it finds.

  2. Reboot and pick "$LABEL" from your boot menu.

     LANDING IN THE SHELL COSTS NOTHING. Nothing flashes automatically. Type
     "exit" to go back. Only these two commands ever start the flasher:

         cd $DROP_DIR_WIN
         flash.nsh

     (the shell usually already puts you in that folder)

  3. Verify it before you trust it. The entry is proven to work in a VM by
     test/smoke-test.sh, but firmware is firmware: confirm your own machine
     boots into the shell before relying on it.

  Remove everything with: sudo ./uninstall.sh --esp $ESP
EOF
