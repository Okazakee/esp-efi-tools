echo -off
#
# flash.nsh - run the vendor flasher that was dropped into this folder.
#
# It re-locates the drop folder first, so it also works if startup.nsh was
# skipped (ESC) or if it is invoked by full path from somewhere else.
#
# The flasher is found with a glob, so the vendor's filename never has to be
# known in advance and never goes stale across releases.
#
# KEEP EXACTLY ONE .efi IN THIS FOLDER. The glob runs every match, in name
# order, so two flashers means two flashes.
#
# Note: "echo" in the EDK2 shell treats a lone "-" token as a flag and fails
# with "echo: Unknown flag - '-'", so no echoed message below may contain one.
#
for %f in fs0: fs1: fs2: fs3: fs4: fs5:
    if exist %f\EFI\esp-efi-tools\firmware\flash.nsh then
        %f
        cd \EFI\esp-efi-tools\firmware
    endif
endfor
echo ==========================================================
echo   esp-efi-tools: running the flasher in this folder
echo ==========================================================
for %i in *.efi
    echo   Running: %i
    echo ==========================================================
    %i
endfor
echo ==========================================================
echo   Finished. To reboot:   reset
echo ==========================================================
