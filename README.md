# esp-efi-tools

[![CI](https://github.com/Okazakee/esp-efi-tools/actions/workflows/ci.yml/badge.svg)](https://github.com/Okazakee/esp-efi-tools/actions/workflows/ci.yml)
[![MIT License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

Update your laptop's firmware without hunting for a USB stick.

Every vendor's flashing tool is a bootable EFI application, and nearly every
vendor tells you to put it on a FAT32 stick and boot from that. So the update you
do once a year needs a stick you no longer own, formatted the way the vendor
expects, with the right file at the right path.

This puts an EFI shell and a drop folder on your EFI System Partition, and gives
you a boot menu entry to reach them. Drop the vendor's `.efi` into the folder,
reboot, type `flash.nsh`.

```
  drop the file here  →  reboot  →  pick the entry  →  type flash.nsh
```

## What this does not do

Worth reading before anything else.

- **It ships no firmware.** Not one vendor byte. It provides the launcher; you
  supply the flasher you downloaded from your own vendor. `install.sh` never
  downloads anything, ever.
- **It does not modify, repack, resign or bypass anything.** No unlocking flash
  protection, no defeating signature checks, no patching a BIOS image. The
  vendor's own tool does the flashing and all of its risk is unchanged.
- **It does not make flashing safer.** Flashing the wrong image for your model is
  exactly as bad here as it is from a USB stick.
- **It is not affiliated with any vendor.**

What it *does* change: you no longer need removable media, and because the entry
is a menu item rather than a boot-order competitor, you cannot end up stuck
booting the flasher forever the way a left-in USB stick can.

## Requirements

- UEFI firmware (not CSM/legacy boot), and an ESP you can mount.
- An **EDK2 UEFI shell**. This is the one piece that cannot be bundled, and
  packaging is inconsistent:

  | Platform | Shell |
  |---|---|
  | Arch, CachyOS, EndeavourOS, Fedora | `edk2-shell` package — `pacman -S edk2-shell` |
  | Debian, Ubuntu | **Not packaged.** `ovmf` ships firmware blobs only. |
  | Any | Your vendor's own update package usually contains one — TUXEDO's is `Shellx64.efi`, sitting next to `startup.nsh`. |

  If it is not in the standard location, point at it with `--shell`.

- For building and running the tests: `qemu-system-x86_64`, OVMF, `mtools`,
  `dosfstools`, `clang`, `lld`.

## Install

```bash
git clone https://github.com/Okazakee/esp-efi-tools
cd esp-efi-tools
sudo ./install.sh
```

It auto-detects the ESP from `/boot/efi`, `/efi` or `/boot`, verifies it is
actually FAT (the firmware cannot read anything else), checks free space, and
refuses to run if any of that looks wrong. Add `--dry-run` to see the plan first.

Useful flags:

```
--esp PATH       ESP mount point, if auto-detection is wrong
--shell PATH     use a specific EDK2 shell
--limine         also add a Limine entry via limine-entry-tool
--no-boot-entry  place the files only; add the boot entry yourself
```

## The workflow

**1.** Put your vendor's flasher into the drop folder, and make sure it is the
only `.efi` in there:

```bash
sudo rm -f /boot/EFI/esp-efi-tools/firmware/*.efi
sudo cp XxSP4xxxN122A24_CAP.efi /boot/EFI/esp-efi-tools/firmware/
```

**2.** Reboot and pick `esp-efi-tools` from your boot menu. The shell lands you in
the drop folder and lists it.

**3.** Type `flash.nsh`.

That is all. Landing in the shell costs nothing — it prints instructions and waits.
`exit` returns to your boot menu. Only `flash.nsh` can ever start the flasher, and
only because you typed it.

For the next release, delete the old file and drop in the new one. No config
changes, no USB, no reinstall.

## Why the shell, and not the flasher directly

It would be tidier to chainload the flasher itself and skip a step. Don't.

Bootloaders commonly have a "remember the last booted entry" setting. If the entry
pointed at the flasher, then the sequence becomes: flash → the tool reboots →
the bootloader remembers the flasher → runs it again → loop, with no way back
into your OS without manual intervention.

An EFI shell cannot loop. Worst case you are looking at a prompt and type `exit`.
The same reasoning is why TUXEDO's own documentation warns that a USB stick can
end up booting ahead of your OS and running the shell a second time.

## Two EDK2 shell quirks worth knowing

Both of these are load-bearing, and both cost real debugging time. They are
regression-tested by `test/smoke-test.sh`.

**`echo` treats a lone `-` as a flag.**

```
Shell> echo esp-efi-tools - firmware staging
echo: Unknown flag - '-'
```

Any echoed message containing a standalone dash fails. Not the dashes *inside* a
word like `esp-efi-tools` — only an isolated `-`. Rephrase, or use `:`.

**The shell starts with no current directory.**

```
Shell> cd \EFI\esp-efi-tools\firmware
cd: Current directory not specified.
```

`cd` with a device-qualified path does not establish a working directory, and
until one exists, plain `dir`/`ls` and relative paths fail too. You have to select
the volume first:

```
Shell> fs0:
Shell> cd \EFI\esp-efi-tools\firmware     ← now it works
```

Since the ESP is not guaranteed to be `fs0` (a USB stick or a second ESP would
shift it), `startup.nsh` scans `fs0:` through `fs5:` for the drop folder instead
of assuming. There is no `%~dp0` equivalent in the EDK2 shell to do this cleanly.

## Bootloader integration

**Default (`efibootmgr`).** Works with any bootloader, because it does not involve
yours at all — the entry shows up in the firmware's own boot menu (usually F7/F12).
Note that `efibootmgr -c` *prepends* the new entry to `BootOrder`; `install.sh`
captures the old order first and appends instead, so your OS stays first.

**Limine.** `--limine` uses `limine-entry-tool --add-efi`, which is the supported
way and survives kernel updates. The equivalent by hand:

```
/esp-efi-tools
    protocol: efi
    path: boot():/EFI/esp-efi-tools/Shellx64.efi
```

Give it a low `order-priority` so it does not become the default entry.

**Anything else.** Point your bootloader at `\EFI\esp-efi-tools\Shellx64.efi` as
an EFI chainload. That is all the Limine entry does.

## Testing

```bash
./test/consistency.sh      # seconds, no VM: do install.sh and the scripts agree?
sudo ./test/install-guards.sh   # install.sh/uninstall.sh refuse the right things
./test/smoke-test.sh       # boots OVMF in QEMU and drives the shell for real
```

`smoke-test.sh` is the interesting one. It builds a FAT image exactly like your
ESP, boots real UEFI firmware under QEMU, waits for `startup.nsh` to run, types
`flash.nsh`, and asserts the flasher was found, launched and returned cleanly. It
also asserts the *absence* of both quirks above, so reintroducing either fails CI.

The guest's "firmware" is `test/fake_flasher.c`: a 6-byte EFI application that
does nothing (`mov eax; ret`). The test never ships, downloads or runs actual
vendor firmware.

`install-guards.sh` covers what a VM cannot reach: that automatic ESP detection
refuses a path which is merely *inside* a mount rather than a mount point, and
that a real install/uninstall round trip leaves the ESP as it found it. It is
how the two bugs in the second commit were caught, both of which were invisible
to the other tests and one of which produced a silently dead boot entry.

CI runs `consistency.sh` and `install-guards.sh` on Ubuntu and the smoke test
inside an Arch container, because Arch is the only common distribution that
packages an EDK2 shell.

## Uninstall

```bash
sudo ./uninstall.sh              # remove everything
sudo ./uninstall.sh --keep-drop  # keep the firmware files
```

It removes the boot entry and the files it created, and refuses to delete a
`startup.nsh` it does not recognise as its own.

## When it won't work

- **Your vendor's flasher refuses to run from internal storage.** Some OEM tools
  deliberately require removable media as an anti-brick measure. This fails
  harmlessly, and you are back to the USB stick for that one vendor.
- **Secure Boot is on.** Some bootloaders only chainload files with a verification
  hash, and some firmware refuses unsigned chainloads outright. `install.sh` warns
  when it detects this.
- **The shell's output is not what you expect.** Your firmware may map the ESP to a
  different `fsN:`; type `map` to list them.

## License

MIT — see [LICENSE](LICENSE).
