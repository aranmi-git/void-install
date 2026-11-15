# Changelog

All notable changes to `void-install.sh`. Versions 1.0 to 1.5 were developed
before this repository existed; their history is summarised at the end.

## 1.5.4 (2026-11-14)

### Removed
- **Hyprland.** Void does not package it, and the only source was an
  unofficial repository with old builds. Gone with it: the consent prompt,
  the code that added that repository, and the two Hyprland dotfile presets
  (CachyOS Hyprland and JaKooLit Hyprland-Dots). No third-party package
  repository is added any more. 16 window managers, 9 desktops and 20
  presets remain.

## 1.5.3 (2026-11-14)

### Fixed
- **Passwords were never stored (critical).** On Void, plain `chpasswd`
  reports success but changes nothing. Every earlier version left the user
  account locked and root without a usable password, so no login worked. The
  script now calls `chpasswd -c SHA512`, as Void's own installer does, and
  stops the install with an error if a password is not in `/etc/shadow`
  afterwards. This also applies to `--bootstrap` mode.

  Systems installed with an earlier version need their passwords set from the
  live USB (`chroot /mnt passwd root`, `chroot /mnt passwd <user>`), or a
  reinstall.

## 1.5.2 (2026-11-14)

### Fixed
- **Limine was not refreshed after a Limine package update.** The copies of
  the boot loader on the boot partition stayed at the old version.
  `update-limine` now compares them with the installed package and replaces
  them when they differ: both EFI copies on UEFI; the boot code on the disk
  plus `limine-bios.sys` on BIOS. A fallback loader that is no longer
  Limine's is left alone.
- **LARBS status bar empty under a login screen.** `~/.profile` is now linked
  to LARBS's `~/.config/shell/profile`, so its status-bar scripts are found.
- **bspwm starter config could come from the wrong example folder.** The
  top-level example pair is now used. Same fix for river.
- **PipeWire helpers could outlive the session.** The session wrapper now
  also stops WirePlumber and pipewire-pulse at logout.

### Changed
- `update-limine` also runs once at every boot (from `/etc/rc.local`),
  because xbps cannot run a hook for a single package. A Limine update is in
  place from the following boot; `sudo update-limine` does it at once.
- `/etc/default/limine` records the firmware type, EFI file name, boot
  partition and BIOS boot partition number that the refresh needs.
- With `startx` or greetd, the session wrapper loads `/etc/profile` and
  `~/.profile` as well as the X profile files, like a login screen does.
- CachyOS Qtile preset installs `python3-pulsectl-asyncio` and
  `python3-dbus-fast`; Qtile itself gets `python3-dbus-fast`.

### Removed
- **EndeavourOS Qtile and Garuda Qtile presets.** Both fail to load on Qtile
  0.37.1, the version Void ships, and Qtile silently falls back to its
  default config. 22 presets remain.

## 1.5.1 (2026-11-14)

### Fixed
- **Window managers had no sound and no D-Bus session.** Nothing started
  PipeWire or the session bus for a bare window manager, so there was no
  audio, and on Wayland no notifications or portals. Every window manager
  now gets a login entry named "<name> (Void session)" that starts it through
  the new `/usr/local/bin/void-session` wrapper. Pick that entry; the plain
  one belongs to the package and starts the bare window manager.
- **dwm's status bar never started.** Void's dwm ships its own login entry,
  so the installer skipped the one that launches the bar.
- **Login set to "none" left `startx` with nothing to start.** An
  `~/.xinitrc` for the first X11 choice is now written. For Wayland, run
  `void-session sway` (or another window manager) from the console.
- **Stale dotfile presets.** A preset is dropped, with a notice, when its
  window manager is unticked.
- **`--bootstrap` mode:** the confirmation screen lists the chosen presets,
  and a preset's window manager gets its login entry.

### Added
- LightDM preselects the "(Void session)" entry of the first window manager.
- greetd: Enter starts the first choice when it is a Wayland window manager.
- Credentials inside URLs (`https://user:token@host/...`) are replaced by
  `***` in the log and on screen.
- UKI: the normal initramfs hook is pinned, so Void's own UKI hook cannot
  take over.

## What was tested, and what was not

### On a real Void Linux system (built with the installer's own steps)
- Base system install, configure step and user creation: passed.
- Passwords: the correct one is accepted by the system's password checker,
  wrong ones are rejected, nothing is written to the log.
- Package step with all window managers: the 16 that Void packages installed
  without errors, together with their tools and LightDM.
- **Not done:** the window managers were not launched on Void. Testing was
  stopped before that step.

### On an Ubuntu test machine (real window managers, not Void's builds)
- Started through the installer's login entries, each with sound, D-Bus, a
  managed test window and a clean logout: i3, bspwm, dwm, awesome, Qtile,
  herbstluftwm, Openbox, Fluxbox, IceWM, spectrwm, Sway, labwc.
- LeftWM: its window manager process passed; its launcher command was not
  tested.
- Not tested: Wayfire (needs a graphics device), niri, river.
- Dotfile presets: 16 applied and started. 14 load; the two Qtile presets
  above failed and were removed. Not tested: the niri, Wayfire, KDE and Xfce
  presets.

### In an emulator, with the real Limine boot loader (BIOS and UEFI)
- A fresh install boots; after a kernel update the new kernel boots by
  default; after a kernel removal the previous one boots again; after a
  Limine update the loader refreshes itself and still boots.
- Used Limine 8.7 and 9.6. Void's 12.9 was not tested.

### Not tested at all
- A complete install on real hardware, start to finish.
- systemd-boot, rEFInd, UKI, EFISTUB and SYSLINUX booting (simulated only).

## 1.5 and earlier

- **1.5** Any number of desktops and window managers, a choice of login
  screen, and dotfile presets (CachyOS, EndeavourOS, Garuda, LARBS and others).
- **1.4** systemd-boot, rEFInd, UKI, EFISTUB and SYSLINUX/EXTLINUX boot loaders.
- **1.3** Kernel choice: the normal kernel always boots by default, LTS is the
  fallback. X11 keyboard layout follows the console keymap.
- **1.2** Several users with sudo levels; LARBS-style bootstrap (programs
  list, dotfiles, shell); mirror check with fallback.
- **1.1** GPU drivers, applications, 32-bit gaming libraries, xbps-src builds.
- **1.0** Menu-driven install: ext4 or btrfs, LUKS1 or LUKS2, GRUB or Limine.
