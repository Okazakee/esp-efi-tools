echo -off
#
# startup.nsh - auto-runs when the EFI shell starts from this volume.
#
# Deliberately does NOT run any flasher. It locates the drop folder, changes
# into it and lists it, so the only thing left to type is "flash.nsh".
# Press ESC during the shell's startup countdown to skip this file entirely.
#
# Two EDK2 shell quirks are worked around below. Both were found by
# test/smoke-test.sh, and both would silently break things otherwise:
#
#   1. "echo" treats a LONE "-" token as a flag and fails with
#      "echo: Unknown flag - '-'". So no echoed message here may contain one.
#   2. The shell starts with NO current directory. "cd fs0:\path" therefore
#      fails with "Current directory not specified" until the volume has been
#      selected with a bare "fs0:". Hence the loop below.
#
# The loop scans fs0..fs5 rather than assuming fs0, so the entry keeps working
# when another FAT volume (a USB stick, a second ESP) is present.
#
cls
echo ==========================================================
echo   esp-efi-tools: firmware staging on the internal disk
echo ==========================================================
echo   Nothing is flashed automatically.
echo .
for %f in fs0: fs1: fs2: fs3: fs4: fs5:
    if exist %f\EFI\esp-efi-tools\firmware\flash.nsh then
        %f
        cd \EFI\esp-efi-tools\firmware
    endif
endfor
echo Drop folder contents:
ls
echo .
echo To run the flasher, type:
echo       flash.nsh
echo .
echo If the listing above is empty, this is not the volume holding
echo the drop folder. Type "map" to list filesystems, select one
echo with e.g. "fs0:", then:
echo       cd \EFI\esp-efi-tools\firmware
echo       flash.nsh
echo .
echo To reboot:               reset
echo To return to the menu:   exit
echo .
