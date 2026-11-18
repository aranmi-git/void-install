# Changelog

All notable changes to `void-install.sh`. Versions 1.0 to 1.5 were developed
before this repository existed; their history is summarised at the end.

## 1.7 (2026-11-16)

### Added
- **Presets.** Save every setting except the disk, the passwords and the
  users to a small text file, and install the same system again by answering
  only those. Use the new **Preset** item at the top of the main menu (load,
  save, show ID), or start with `--preset`:

      bash void-install.sh --preset xfce-desktop
      bash void-install.sh --preset /mnt/usb/my.preset@1a2b3c4d5e6f7a8b
      bash void-install.sh --preset https://example.org/my.preset

  A bare name is taken from the `presets/` folder of this repository
  (`VOID_INSTALL_PRESETS` points it at a fork). After loading, the installer
  asks for the disk, the root password, a user and, if encrypted, the
  passphrase, then opens the main menu with Install selected.
- **Preset IDs.** Every preset has an ID such as
  `xfce-desktop@b3a18756ad65416c`: its name plus the first 16 hex digits of
  the SHA-256 of its settings. Comments and blank lines do not change it; any
  setting does. Loading with `@<digits>` (16 to 64) refuses a preset that
  does not match, and changes nothing.
- **Peripherals menu.** 21 choices; the ones matching connected hardware
  are ticked the first time. From Void's repository: Solaar, logiops,
  g810-led, Piper, ckb-next, OpenRazer + Polychromatic, OpenRGB,
  CoolerControl, xone, xpadneo, controller access rules, SC Controller,
  AntiMicroX, Oversteer, Wacom, input-remapper, keyd, kanata and Bluetooth.
  Kernel headers are added for the drivers that DKMS builds.
- **Two tools from outside Void**, each pinned and checked:
  - OpenLogi 0.9.0 (Logitech): the project's Linux build, SHA-256 pinned
    (the release's minisign signature was verified when pinning). Unpacked
    into `/usr/local`; its agent starts with the desktop session.
  - OpenLinkHub 0.9.4 (Corsair): built from a pinned commit with Void's Go;
    runs as its own `openlinkhub` user under a new runit service.
  Build tools are removed again afterwards. A failed download or build is a
  warning, not a failed install.
- **Corsair: OpenLinkHub or ckb-next.** They drive the same devices, so the
  menu explains the difference and lets you pick one.
- runit services enabled as needed: bluetoothd, logid, ratbagd,
  ckb-next-daemon, coolercontrold, input-remapper, keyd, openlinkhub. Users join the `bluetooth` and `keyd` groups when those are
  picked; logiops gets a starter `/etc/logid.cfg`.
- Six example presets: `minimal`, `xfce-desktop`, `kde-desktop`,
  `sway-wayland`, `i3-cachyos`, `gaming-kde`.
- Each install saves its own settings to `/root/void-install.preset` on the
  new system.

### Security
- A preset is never run or sourced. Only 28 known settings are read, each
  value is checked against the same rules as the menus (or stricter), and
  one bad line rejects the whole file. Disk, passwords and user names are
  refused if present. Files over 64 KiB or with control characters are
  refused.
- Only `https://` downloads, with redirects limited to https, and no links
  with a user name or token. A programs list or dotfiles repository in a
  preset must also be an https link (or `git@`); the load screen lists
  these outside sources so you can decide whether to trust them.
- **No passwords are ever stored in a preset**: not the root password, user
  passwords, the encryption passphrase, nor user names or sudo levels. The
  installer never writes them, and a file that looks like it holds one (a
  line such as `password=...` or `# luks passphrase: ...`, also in comments)
  is refused when loaded. Tested: a full simulated install leaves no
  password in any file of the new system, its log or its saved preset.
- Package names in Extra packages and xbps-src (menu and presets) must start
  with a letter or digit, so a value cannot pass options such as `-R` to
  xbps-install.

## 1.6 (2026-11-15)

### Added
- **Any kernels, in your boot order.** The Kernel menu lists every kernel in
  Void's repository (read live, so new ones appear without a script update):
  `linux`, `linux-lts`, `linux-mainline` and each `linuxX.Y` series. Tick any
  combination, then set the order: select a kernel to make it boot first,
  move it up or down, or remove it. The first boots by default; the others
  are the next boot menu entries.
- The order is kept in `/etc/default/kernel-order` (`KERNEL_ORDER="..."`)
  and used by every boot loader. Edit it after installing and refresh the
  boot menu to change it.

### Changed
- `linux` (Void's default kernel, currently 6.18) is no longer forced. Void's
  base system depends on it, so when it is left out the installer adds
  `ignorepkg=linux` to `/etc/xbps.d/10-void-install-kernels.conf`, keeping it
  out on updates too, and installs `linux-base` for the firmware and
  initramfs tools it normally brings. Checked against Void's repository:
  choosing only 6.12 installs 6.12 and the firmware, and nothing else.
- GRUB's automatic fallback is the second kernel in your order (was always
  LTS).
- When several versions of one kernel are installed, the newest version of
  each chosen kernel comes first, in your order; older versions follow.
- Boot menu labels: the LTS kernel is marked "LTS" (was "LTS fallback").
- DKMS (NVIDIA) installs headers for exactly the chosen kernels.

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
