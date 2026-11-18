#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# =============================================================================
#  void-install.sh - menu-driven (dialog) installer for Void Linux
#  https://github.com/aranmi-git/void-install
#
#  Copyright (C) 2026 aranmi-git
#
#  This program is free software; you can redistribute it and/or modify it
#  under the terms of the GNU General Public License, version 2, as published
#  by the Free Software Foundation.
#
#  This program is distributed in the hope that it will be useful, but WITHOUT
#  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
#  FITNESS FOR A PARTICULAR PURPOSE. See the LICENSE file for the full text.
# =============================================================================
#
#  Features
#    * UEFI (64-bit or 32-bit firmware) or legacy BIOS; GPT; whole-disk install
#    * Root filesystem: ext4 or btrfs
#        btrfs subvolumes: @ @home @snapshots @var_log @var_cache_xbps (+ @swap)
#    * Encryption of the root partition: none, LUKS1 or LUKS2
#    * Boot loader: GRUB, Limine, systemd-boot, rEFInd, UKI (unified kernel
#      images), EFISTUB or SYSLINUX/EXTLINUX - always the normal kernel first
#      and the LTS kernel as fallback
#    * glibc or musl, kernel series, mirror, keymap, locale, timezone,
#      user with sudo, NetworkManager or dhcpcd, zram or swap file,
#      any number of desktops (Xfce, KDE Plasma, GNOME, MATE, Cinnamon, LXQt,
#      Budgie, LXDE, Enlightenment) and window managers (i3, bspwm, dwm,
#      awesome, Qtile, herbstluftwm, Openbox, Fluxbox, IceWM, spectrwm, LeftWM,
#      Sway, niri, river, labwc, Wayfire), each with a full tool set;
#      login screen LightDM, SDDM, GDM, greetd/tuigreet or none
#    * Dotfile presets: CachyOS, EndeavourOS, Garuda, LARBS, JaKooLit, gh0stzk,
#      Chris Titus
#    * GPU drivers (Intel, AMD, NVIDIA nouveau/proprietary, VM guest tools)
#    * Applications (Firefox, VLC, ...), gaming (32-bit multilib, Steam, Wine)
#    * Packages built from source with xbps-src (void-packages)
#    * Several users, each with a sudo level (sudo, sudo without password, none)
#    * LARBS-style bootstrap: a programs CSV, a dotfiles repository, a login shell
#      (also usable alone on an installed system: bash void-install.sh --bootstrap)
#
#  Usage
#    Boot an official Void Linux live ISO (x86_64), connect to the internet,
#    then run as root:   bash void-install.sh
#
#  Partition layouts (GPT)
#    UEFI + GRUB, /boot inside root ..... ESP 512M (/boot/efi) | root
#    UEFI + GRUB, unencrypted /boot ..... ESP 1G   (/boot)     | root
#    UEFI + Limine ...................... ESP 1G   (/boot)     | root
#    UEFI + systemd-boot/rEFInd/EFISTUB . ESP 1G   (/boot)     | root
#    UEFI + UKI ......................... ESP 1G   (/boot/efi) | root
#    BIOS + GRUB, /boot inside root ..... BIOS boot 2M | root
#    BIOS + GRUB, unencrypted /boot ..... BIOS boot 2M | /boot 1G ext4  | root
#    BIOS + Limine ...................... BIOS boot 2M | /boot 1G FAT32 | root
#    BIOS + SYSLINUX .................... /boot 1G ext2 (legacy BIOS bootable) | root
#  "root" is the filesystem itself, or a LUKS container that holds it.
#
#  Encryption notes
#    * GRUB with /boot inside the encrypted root: GRUB asks for the passphrase
#      (US keyboard layout), then a key file inside the initramfs unlocks root,
#      so you type it only once. GRUB 2.12 cannot use Argon2, so LUKS2 volumes
#      that GRUB must open are created with PBKDF2.
#    * Every other boot loader (and GRUB with an unencrypted /boot): kernel +
#      initramfs (or the UKI) live on an unencrypted partition and the initramfs
#      asks for the passphrase; LUKS2 then uses Argon2id.
#  systemd-boot, rEFInd, UKI, EFISTUB and SYSLINUX entries are written by
#  /usr/local/bin/update-boot-menu (settings: /etc/default/void-boot) on every
#  kernel install/removal. ZFSBootMenu is not offered: it needs a ZFS root.
#
#  !!! THE SELECTED DISK IS ERASED COMPLETELY !!!   Log: /tmp/void-install.log
#  Keep backups.
# =============================================================================

SCRIPT_VERSION="1.7"
BACKTITLE="Void Linux installer ${SCRIPT_VERSION}"
LOG=/tmp/void-install.log
WARN_FILE=/tmp/void-install.warnings
TARGET=/mnt/target
CRYPT_NAME=cryptroot

# Sizes in MiB
ESP_SIZE_MIB=512        # ESP when it only holds the GRUB EFI binary
BOOT_SIZE_MIB=1024      # ESP / boot partition that also holds kernels + initramfs
BIOSBOOT_SIZE_MIB=2     # GPT "BIOS boot" partition (GRUB core.img / Limine stage 2)
MIN_ROOT_GIB=8

BTRFS_OPTS="noatime,compress=zstd:1"
BTRFS_SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log" "@var_cache_xbps:/var/cache/xbps")

GUID_ESP=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
GUID_BIOS=21686148-6449-6E6F-744E-656564454649
GUID_LINUX=0FC63DAF-8483-4772-8E79-3D69D8477DE4
GUID_LUKS=CA7D7CCB-63ED-4C53-861C-1742536059CC

# ---- user choices (defaults) ------------------------------------------------
DISK=""
FS=ext4                 # ext4 | btrfs
ENC=luks2               # none | luks1 | luks2
BOOTLOADER=grub         # grub | limine | systemd-boot | refind | uki | efistub | syslinux
GRUB_BOOT=encrypted     # encrypted | separate   (only GRUB + encryption)
SWAP=zram               # none | zram | file
SWAP_SIZE=4             # GiB, for SWAP=file
# Kernels: "linux" is always installed and boots by default. Extra kernels:
KERNELS="linux linux-lts"   # boot order, first = default: linux linux-lts linux-mainline linuxX.Y
LIBC=glibc              # glibc | musl
MIRROR=https://repo-default.voidlinux.org
HOST_NAME=void
KEYMAP=us
LOCALE=en_US.UTF-8
TIMEZONE=UTC
ROOT_PASS=""
USER_NAME=""            # primary user (first in USERS): owns xbps-src and the dotfiles
USERS=()                # login names, in order
declare -A U_FULL=() U_PASS=() U_SUDO=()   # per user: full name, password, sudo level (sudo|nopasswd|none)
BS_PROGS=""             # LARBS-style programs list: local path or http(s) URL of a CSV
BS_DOTFILES=""          # git URL of a dotfiles repository, copied into the primary user's home
BS_BRANCH=""            # branch of the dotfiles repository (empty = default)
BS_SHELL=bash           # login shell of the primary user: bash | zsh | fish
BS_POWER=0              # 1 = wheel may run shutdown/reboot/mount/xbps updates without a password
STANDALONE=0            # 1 = --bootstrap on an installed system (TARGET=/)
LUKS_PASS=""
NET="nm"                # nm | dhcpcd | none
DESKTOP=none            # none, or a list of desktop/WM ids from desktop_table (xfce kde i3 sway ...)
DM=auto                 # login screen: auto | lightdm | sddm | gdm | greetd | none
DOTS=""                 # dotfile presets from dots_table (cachyos-i3 larbs ...)
EXTRA_PKGS=""
GPU=auto                # auto | none | list of: intel amd nouveau nvidia nvidia580 nvidia470 nvidia390 vm
APPS=""                 # list chosen in the Applications menu
GAMING=""               # list of: multilib steam wine lutris gamemode winetricks
PERIPH=""               # peripheral support: see periph_table
XSRC_PKGS=""            # packages to build from source with xbps-src
XSRC_SETUP=0            # 1 = set up ~/void-packages even when nothing is built

# ---- detected / computed ----------------------------------------------------
FIRMWARE=bios           # uefi | bios
EFI_BITS=64
ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
BIOSBOOT_PART="" BIOSBOOT_NUM=""
BOOT_PART="" BOOT_NUM="" BOOT_FS=""
ROOT_PART="" ROOT_NUM=""
ALL_PARTS=()
INSTALL_STARTED=0

# =============================================================================
#  Small helpers
# =============================================================================
die() {
	clear 2>/dev/null
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

# Hide credentials embedded in URLs (https://user:token@host/...) on stdin.
mask_secrets() { sed -u -E 's#(://)[^/@[:space:]"'"'"']+@#\1***@#g'; }

# Record a non-fatal problem (shown at the end of the installation).
warn() {
	printf 'WARNING: %s\n' "$*" >&2
	printf '%s\n' "$*" | mask_secrets >>"$WARN_FILE"
}

trim() {
	local s=$*
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

encrypted()        { [[ $ENC != none ]]; }
grub_unlocks()     { [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == encrypted ]]; }
# Boot methods whose kernel and initramfs live on the EFI system partition
# (mounted at /boot): the firmware or boot manager can only read FAT.
kernels_on_esp()   { [[ $BOOTLOADER == limine || $BOOTLOADER == systemd-boot || $BOOTLOADER == refind || $BOOTLOADER == efistub ]]; }
# Methods that need 64-bit UEFI / BIOS firmware.
uefi_only()        { [[ $BOOTLOADER == systemd-boot || $BOOTLOADER == refind || $BOOTLOADER == uki || $BOOTLOADER == efistub ]]; }
bios_only()        { [[ $BOOTLOADER == syslinux ]]; }
# Methods whose menu is written by /usr/local/bin/update-boot-menu.
uses_boot_menu()   { uefi_only || bios_only; }
boot_is_separate() { kernels_on_esp || bios_only || [[ $BOOTLOADER == grub && $ENC != none && $GRUB_BOOT == separate ]]; }
efi_arch()         { if [[ $EFI_BITS == 32 ]]; then echo ia32; else echo x64; fi; }

xbps_arch() {
	if [[ $LIBC == musl ]]; then echo x86_64-musl; else echo x86_64; fi
}

repo_url() {
	if [[ $LIBC == musl ]]; then echo "${MIRROR%/}/current/musl"; else echo "${MIRROR%/}/current"; fi
}

grub_efi_target() {
	if [[ $EFI_BITS == 32 ]]; then echo i386-efi; else echo x86_64-efi; fi
}

root_device() {
	if encrypted; then echo "/dev/mapper/$CRYPT_NAME"; else echo "$ROOT_PART"; fi
}

# /dev/sda + 2 -> /dev/sda2 ; /dev/nvme0n1 + 2 -> /dev/nvme0n1p2
part_name() {
	if [[ $1 =~ [0-9]$ ]]; then echo "${1}p${2}"; else echo "${1}${2}"; fi
}

# has "<space separated list>" <word>
has() { [[ " $1 " == *" $2 "* ]]; }
without() { # without "<list>" word -> the list minus that word
	local w out=""
	for w in $1; do [[ $w == "$2" ]] || out+="${out:+ }$w"; done
	printf '%s\n' "$out"
}

multilib_on() { has "$GAMING" multilib || has "$GAMING" steam; }

# GPU vendors found on the PCI bus -> driver keywords
detect_gpus() {
	local id out=""
	while read -r id; do
		case ${id:1:4} in
			8086) out+=" intel" ;;
			1002) out+=" amd" ;;
			10de) out+=" nouveau" ;;
			80ee | 15ad | 1af4 | 1234 | 1b36) out+=" vm" ;;
		esac
	done < <(lspci -nn 2>/dev/null | grep -E '\[03(00|02|80)\]' | grep -oE '\[[0-9a-f]{4}:[0-9a-f]{4}\]' || true)
	tr ' ' '\n' <<<"$out" | awk 'NF && !seen[$0]++' | paste -sd ' ' -
}

vm_type() {
	local v
	v=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ') || true
	case $v in
		*innotek* | *VirtualBox*) echo virtualbox ;;
		*VMware*) echo vmware ;;
		*QEMU* | *KVM* | *Bochs* | *"Red Hat"*) echo qemu ;;
		*) echo none ;;
	esac
}

# Effective GPU driver list ("auto" only installs drivers when they are useful)
gpu_list() {
	case $GPU in
		none) ;;
		auto) if desktop_on || multilib_on; then detect_gpus; fi ;;
		*) echo "$GPU" ;;
	esac
}

nvidia_driver() { # prints the proprietary NVIDIA package chosen, if any
	local g
	for g in $(gpu_list); do
		if [[ $g == nvidia* ]]; then echo "$g"; return 0; fi
	done
	return 0
}

get_uuid() {
	local u
	u=$(blkid -c /dev/null -s UUID -o value "$1" 2>/dev/null) || true
	if [[ -z $u ]]; then
		echo "Could not read the UUID of $1" >&2
		return 1
	fi
	printf '%s\n' "$u"
}

swapfile_path() {
	if [[ $FS == btrfs ]]; then echo /swap/swapfile; else echo /swapfile; fi
}

ram_gib() {
	awk '/^MemTotal:/ { printf "%d", ($2 + 1048575) / 1048576 }' /proc/meminfo
}

# Run a command inside the target system with a clean environment.
in_target() {
	chroot "$TARGET" /usr/bin/env -i HOME=/root TERM=dumb LANG=C \
		PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$@"
}

# =============================================================================
#  dialog wrappers
# =============================================================================
# ui: run dialog, print the answer on stdout, keep dialog's exit status.
ui() {
	# shellcheck disable=SC2069  # answer (stderr) -> caller, screen (stdout) -> terminal
	dialog --backtitle "$BACKTITLE" --colors --cancel-label "Back" "$@" 2>&1 >/dev/tty
}

msg() { # msg "text" [title] [height] [width]
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Notice} " \
		--msgbox "$1" "${3:-10}" "${4:-70}" >/dev/tty 2>&1 || true
}

yesno() { # yesno "text" [title] [defaultno: 1] [height] [width]
	local -a opt=()
	if [[ ${3:-0} == 1 ]]; then opt=(--defaultno); fi
	dialog --backtitle "$BACKTITLE" --colors --title " ${2:-Confirm} " "${opt[@]}" \
		--yesno "$1" "${4:-10}" "${5:-70}" >/dev/tty 2>&1
}

# Ask for a secret twice; prints it on stdout.
ask_password() { # ask_password "title" "what"
	local p1 p2
	while true; do
		p1=$(ui --title " $1 " --insecure --passwordbox "Enter $2:" 9 64) || return 1
		if [[ -z $p1 ]]; then
			msg "The password must not be empty." "$1"
			continue
		fi
		p2=$(ui --title " $1 " --insecure --passwordbox "Repeat $2:" 9 64) || return 1
		if [[ $p1 == "$p2" ]]; then
			printf '%s' "$p1"
			return 0
		fi
		msg "The two entries did not match. Please try again." "$1"
	done
}

# Interactive shell; Ctrl-C inside it must not terminate the installer.
run_shell() { # run_shell <command...>
	trap ':' INT
	"$@" </dev/tty >/dev/tty 2>&1 || true
	trap 'exit 130' INT TERM
}

# =============================================================================
#  Environment checks
# =============================================================================
detect_firmware() {
	if [[ -d /sys/firmware/efi ]]; then
		FIRMWARE=uefi
		EFI_BITS=$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)
		[[ $EFI_BITS == 32 ]] || EFI_BITS=64
	else
		FIRMWARE=bios
	fi
}

preflight() {
	[[ $EUID -eq 0 ]] || die "Run this installer as root."
	[[ $(uname -m) == x86_64 ]] || die "This installer supports x86_64 only."
	command -v xbps-install >/dev/null 2>&1 ||
		die "xbps-install not found. Boot an official Void Linux live ISO and run the installer from there."
	[[ -t 0 && -t 1 ]] || die "Run the installer from an interactive terminal."
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	detect_firmware
	local r
	r=$(ram_gib)
	if [[ $r =~ ^[0-9]+$ ]] && ((r > 0)); then
		SWAP_SIZE=$((r < 2 ? 2 : (r > 8 ? 8 : r)))
	fi
}

ensure_dialog() {
	command -v dialog >/dev/null 2>&1 && return 0
	echo "Installing 'dialog' into the live system ..."
	if ! xbps-install -Sy dialog; then
		if ! { xbps-install -Syu xbps && xbps-install -Sy dialog; }; then
			die "Could not install 'dialog'. Check your internet connection (e.g. dhcpcd, wpa_supplicant, nmtui)."
		fi
	fi
}

net_ok() {
	timeout 30 xbps-install -S >/dev/null 2>&1
}

wifi_setup() {
	if command -v nmtui >/dev/null 2>&1 && pgrep -x NetworkManager >/dev/null 2>&1; then
		clear
		nmtui-connect 2>/dev/null || nmtui || true
		return 0
	fi

	local -a ifs=()
	local d
	for d in /sys/class/net/*/wireless; do
		[[ -e $d ]] || continue
		d=${d%/wireless}
		ifs+=("${d##*/}" "wireless")
	done
	if ((${#ifs[@]} == 0)); then
		msg "No wireless interface was found." "Wi-Fi"
		return 0
	fi

	local ifc ssid psk
	ifc=$(ui --title " Wi-Fi " --menu "Wireless interface:" 12 50 4 "${ifs[@]}") || return 0
	ip link set "$ifc" up >/dev/null 2>&1 || true

	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Scanning on $ifc ..." 3 40 >/dev/tty 2>&1
	local -a nets=()
	local s
	while IFS= read -r s; do
		[[ -n $s ]] && nets+=("$s" "")
	done < <(iw dev "$ifc" scan 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | sort -u)
	nets+=("<other>" "enter the name manually")

	ssid=$(ui --title " Wi-Fi " --menu "Network:" 18 60 10 "${nets[@]}") || return 0
	if [[ $ssid == "<other>" ]]; then
		ssid=$(ui --title " Wi-Fi " --inputbox "Network name (SSID):" 9 60) || return 0
	fi
	[[ -n $ssid ]] || return 0
	psk=$(ui --title " Wi-Fi " --insecure --passwordbox "Passphrase for '$ssid' (leave empty for an open network):" 9 64) || return 0

	local conf=/etc/wpa_supplicant/wpa_supplicant.conf block
	mkdir -p /etc/wpa_supplicant
	[[ -s $conf ]] || printf 'ctrl_interface=/run/wpa_supplicant\nupdate_config=1\n' >"$conf"
	if [[ -n $psk ]]; then
		if ! block=$(wpa_passphrase "$ssid" "$psk" 2>&1); then
			msg "wpa_passphrase failed:\n$block" "Wi-Fi"
			return 0
		fi
		printf '%s\n' "$block" | grep -v '^[[:space:]]*#psk=' >>"$conf"
	else
		printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$ssid" >>"$conf"
	fi

	if [[ -e /var/service/wpa_supplicant ]]; then
		sv restart wpa_supplicant >/dev/null 2>&1 || true
	else
		pkill -x wpa_supplicant >/dev/null 2>&1 || true
		wpa_supplicant -B -i "$ifc" -c "$conf" >/dev/null 2>&1 || true
	fi
	if [[ ! -e /var/service/dhcpcd ]]; then
		dhcpcd -b "$ifc" >/dev/null 2>&1 || true
	fi
	dialog --backtitle "$BACKTITLE" --title " Wi-Fi " --infobox "Connecting to '$ssid' ..." 3 50 >/dev/tty 2>&1
	sleep 10
}

ensure_network() {
	dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection to the Void repositories ..." 3 60 >/dev/tty 2>&1
	while ! net_ok; do
		local c
		c=$(ui --title " No network " --cancel-label "Quit" --menu \
			"The Void package repositories cannot be reached.\nThe installer downloads everything, so it needs internet access." 15 72 4 \
			retry "Try again" \
			wifi "Connect to a Wi-Fi network" \
			shell "Open a shell to fix it manually ('exit' returns here)" \
			quit "Quit the installer") || c=quit
		case $c in
			retry) ;;
			wifi) wifi_setup ;;
			shell)
				clear
				echo "Set up the network (dhcpcd, wpa_supplicant, nmtui, ...), then type 'exit'."
				run_shell bash -i
				;;
			*) clear; exit 1 ;;
		esac
		dialog --backtitle "$BACKTITLE" --title " Network " --infobox "Checking the connection ..." 3 50 >/dev/tty 2>&1
	done
}

# =============================================================================
#  Partition layout
# =============================================================================
compute_layout() {
	local n=1
	ESP_PART="" ESP_NUM="" ESP_MOUNT="" ESP_SIZE=0
	BIOSBOOT_PART="" BIOSBOOT_NUM=""
	BOOT_PART="" BOOT_NUM="" BOOT_FS=""
	ALL_PARTS=()

	if [[ $FIRMWARE == uefi ]]; then
		ESP_NUM=$n
		ESP_PART=$(part_name "$DISK" "$n")
		n=$((n + 1))
		if boot_is_separate; then
			ESP_MOUNT=/boot
			ESP_SIZE=$BOOT_SIZE_MIB
		elif [[ $BOOTLOADER == uki ]]; then
			ESP_MOUNT=/boot/efi      # kernels stay in /boot; the UKIs (~50-100 MiB each) go here
			ESP_SIZE=$BOOT_SIZE_MIB
		else
			ESP_MOUNT=/boot/efi
			ESP_SIZE=$ESP_SIZE_MIB
		fi
		ALL_PARTS+=("$ESP_PART")
	else
		# SYSLINUX boots from a flagged /boot partition and needs no BIOS boot partition.
		if ! bios_only; then
			BIOSBOOT_NUM=$n
			BIOSBOOT_PART=$(part_name "$DISK" "$n")
			n=$((n + 1))
			ALL_PARTS+=("$BIOSBOOT_PART")
		fi
		if boot_is_separate; then
			BOOT_NUM=$n
			BOOT_PART=$(part_name "$DISK" "$n")
			n=$((n + 1))
			case $BOOTLOADER in
				limine) BOOT_FS=vfat ;;
				syslinux) BOOT_FS=ext2 ;;   # extlinux 6.03 cannot read ext4 with the 64bit feature
				*) BOOT_FS=ext4 ;;
			esac
			ALL_PARTS+=("$BOOT_PART")
		fi
	fi
	ROOT_NUM=$n
	ROOT_PART=$(part_name "$DISK" "$n")
	ALL_PARTS+=("$ROOT_PART")
}

sfdisk_script() {
	local root_type=$GUID_LINUX
	if encrypted; then root_type=$GUID_LUKS; fi
	echo "label: gpt"
	if [[ -n $ESP_PART ]]; then
		echo "size=${ESP_SIZE}MiB, type=$GUID_ESP, name=\"EFI system partition\""
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		echo "size=${BIOSBOOT_SIZE_MIB}MiB, type=$GUID_BIOS, name=\"BIOS boot\""
	fi
	if [[ -n $BOOT_PART ]]; then
		if bios_only; then
			# gptmbr.bin boots the partition carrying this attribute.
			echo "size=${BOOT_SIZE_MIB}MiB, type=$GUID_LINUX, name=\"boot\", attrs=\"LegacyBIOSBootable\""
		else
			echo "size=${BOOT_SIZE_MIB}MiB, type=$GUID_LINUX, name=\"boot\""
		fi
	fi
	echo "type=$root_type, name=\"void\""
}

required_mib() {
	local mib=$((MIN_ROOT_GIB * 1024 + 8 + ESP_SIZE))
	if [[ -n $BIOSBOOT_PART ]]; then mib=$((mib + BIOSBOOT_SIZE_MIB)); fi
	if [[ -n $BOOT_PART ]]; then mib=$((mib + BOOT_SIZE_MIB)); fi
	if [[ $SWAP == file ]]; then mib=$((mib + SWAP_SIZE * 1024)); fi
	echo "$mib"
}

enc_desc() {
	case $ENC in
		luks1) echo "LUKS1 (PBKDF2)" ;;
		luks2) if grub_unlocks; then echo "LUKS2 (PBKDF2)"; else echo "LUKS2 (Argon2id)"; fi ;;
		*) echo "none" ;;
	esac
}

layout_row() { printf '  %-18s %-9s %s\n' "$1" "$2" "$3"; }

layout_lines() {
	local rootdesc
	if [[ -n $ESP_PART ]]; then
		layout_row "$ESP_PART" "${ESP_SIZE} MiB" "FAT32 -> $ESP_MOUNT (EFI system partition)"
	fi
	if [[ -n $BIOSBOOT_PART ]]; then
		layout_row "$BIOSBOOT_PART" "${BIOSBOOT_SIZE_MIB} MiB" "BIOS boot (no filesystem)"
	fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "FAT32 -> /boot" ;;
			ext2) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext2 -> /boot (legacy BIOS bootable)" ;;
			*) layout_row "$BOOT_PART" "${BOOT_SIZE_MIB} MiB" "ext4 -> /boot" ;;
		esac
	fi
	if encrypted; then rootdesc="$(enc_desc) -> $FS -> /"; else rootdesc="$FS -> /"; fi
	layout_row "$ROOT_PART" "rest" "$rootdesc"
}

# =============================================================================
#  Menu labels
# =============================================================================
lbl_disk() {
	if [[ -n $DISK ]]; then
		printf '%s  %s' "$DISK" "$(lsblk -dno SIZE "$DISK" 2>/dev/null | tr -d ' ')"
	else
		printf '\\Z1(not set)\\Zn'
	fi
}
lbl_enc() {
	case $ENC in
		none) printf 'none' ;;
		*) printf '%s' "${ENC^^}"; [[ -n $LUKS_PASS ]] || printf ' \\Z1(passphrase not set)\\Zn' ;;
	esac
}
lbl_boot() {
	case $BOOTLOADER in
		limine) printf 'Limine' ;;
		systemd-boot) printf 'systemd-boot' ;;
		refind) printf 'rEFInd' ;;
		uki) printf 'UKI (unified kernel images)' ;;
		efistub) printf 'EFISTUB (no boot menu)' ;;
		syslinux) printf 'SYSLINUX (EXTLINUX)' ;;
		*)
			if ! encrypted; then
				printf 'GRUB'
			elif [[ $GRUB_BOOT == encrypted ]]; then
				printf 'GRUB (/boot encrypted)'
			else
				printf 'GRUB (unencrypted /boot)'
			fi
			;;
	esac
}
lbl_swap() {
	case $SWAP in
		file) printf 'swap file, %s GiB' "$SWAP_SIZE" ;;
		zram) printf 'zram' ;;
		*) printf 'none' ;;
	esac
}
lbl_set()    { if [[ -n $1 ]]; then printf 'set'; else printf '\\Z1(not set)\\Zn'; fi; }
sudo_word() { case ${U_SUDO[$1]:-} in sudo) printf 'sudo' ;; nopasswd) printf 'sudo, no password' ;; *) printf 'no sudo' ;; esac; }
lbl_user() {
	local u out=""
	if ((${#USERS[@]} == 0)); then printf '\\Z1(not set)\\Zn'; return 0; fi
	for u in "${USERS[@]}"; do out+="${out:+, }$u ($(sudo_word "$u"))"; done
	printf '%s' "$out"
}
lbl_bootstrap() {
	local out=""
	[[ -n $BS_PROGS ]] && out+="programs list"
	[[ -n $BS_DOTFILES ]] && out+="${out:+, }dotfiles"
	[[ $BS_SHELL != bash ]] && out+="${out:+, }$BS_SHELL"
	[[ $BS_POWER == 1 ]] && out+="${out:+, }power cmds"
	printf '%s' "${out:-(none)}"
}
lbl_locale() { if [[ $LIBC == musl ]]; then printf 'n/a (musl)'; else printf '%s' "$LOCALE"; fi; }
lbl_net() {
	case $NET in
		nm) printf 'NetworkManager' ;;
		dhcpcd) printf 'dhcpcd' ;;
		*) printf 'none' ;;
	esac
}
lbl_gpu() {
	local l
	case $GPU in
		none) printf 'none' ;;
		auto)
			l=$(detect_gpus)
			if ! desktop_on && ! multilib_on; then printf 'auto (only with a desktop)'; else printf 'auto (%s)' "${l:-nothing detected}"; fi
			;;
		*) printf '%s' "$GPU" ;;
	esac
}
lbl_list() { if [[ -n $1 ]]; then printf '%s' "$1"; else printf '(none)'; fi; }
lbl_xsrc() {
	if [[ -n $XSRC_PKGS ]]; then printf 'build: %s' "$XSRC_PKGS"
	elif [[ $XSRC_SETUP == 1 ]]; then printf 'set up only'
	else printf '(none)'; fi
}

# =============================================================================
#  Menus (each returns 1 when the user goes back without a change)
# =============================================================================
live_media_disk() {
	local src pk
	src=$(findmnt -no SOURCE /run/initramfs/live 2>/dev/null) || true
	[[ -b $src ]] || return 0
	pk=$(lsblk -no PKNAME "$src" 2>/dev/null | head -n1 | tr -d ' ')
	if [[ -n $pk ]]; then echo "/dev/$pk"; else echo "$src"; fi
}

menu_disk() {
	local live d size model tran desc
	local -a items=()
	live=$(live_media_disk)
	while read -r d; do
		[[ $d =~ ^/dev/(loop|ram|zram|sr|fd) ]] && continue
		[[ $(lsblk -dno TYPE "$d" 2>/dev/null | tr -d ' ') == disk ]] || continue
		[[ $(lsblk -dno RO "$d" 2>/dev/null | tr -d ' ') == 0 ]] || continue
		size=$(lsblk -dno SIZE "$d" | tr -d ' ')
		model=$(trim "$(lsblk -dno MODEL "$d" 2>/dev/null)")
		tran=$(trim "$(lsblk -dno TRAN "$d" 2>/dev/null)")
		desc="$size  ${model:-unknown model}${tran:+  [$tran]}"
		[[ $d == "$live" ]] && desc+="  (live media)"
		items+=("$d" "$desc")
	done < <(lsblk -dnpo NAME)

	if ((${#items[@]} == 0)); then
		msg "No suitable disk was found." "Disk"
		return 1
	fi

	local sel
	sel=$(ui --title " Target disk " --default-item "${DISK:-${items[0]}}" --menu \
		"Select the disk to install Void Linux on.\n\Z1\ZbThe whole disk will be erased.\Zn" 0 0 0 "${items[@]}") || return 1

	if [[ -n $live && $sel == "$live" ]]; then
		msg "$sel holds the live system you booted from. Choose another disk." "Disk"
		return 1
	fi
	local bytes
	bytes=$(blockdev --getsize64 "$sel" 2>/dev/null || echo 0)
	if ((bytes < (MIN_ROOT_GIB + 2) * 1024 * 1024 * 1024)); then
		msg "$sel is too small. At least $((MIN_ROOT_GIB + 2)) GiB are needed." "Disk"
		return 1
	fi

	local current
	current=$(lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$sel" 2>/dev/null | head -n 12)
	if dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Confirm disk " --defaultno \
		--yesno "Current content of $sel:\n\n$current\n\n\Z1\ZbEverything on $sel will be erased when the installation starts.\Zn\nUse this disk?" \
		0 78 >/dev/tty 2>&1; then
		DISK=$sel
		return 0
	fi
	return 1
}

menu_fs() {
	local c
	c=$(ui --title " Filesystem " --default-item "$FS" --menu "Root filesystem:" 11 78 2 \
		ext4 "Classic journaling filesystem" \
		btrfs "Subvolumes (@, @home, @snapshots, ...), zstd compression") || return 1
	FS=$c
}

menu_grub_boot() {
	local c
	c=$(ui --title " GRUB and encryption " --default-item "$GRUB_BOOT" --menu \
		"Where should the kernel and initramfs live?\n\n\Zbencrypted\Zn: everything except the ESP is encrypted. GRUB asks for the passphrase (US keyboard layout, unlocking takes ~10-30 s); LUKS2 is created with PBKDF2.\n\n\Zbseparate\Zn: a 1 GiB unencrypted /boot holds kernel + initramfs; the initramfs asks for the passphrase and LUKS2 keeps Argon2id." \
		19 78 2 \
		encrypted "/boot inside the encrypted root (GRUB unlocks it)" \
		separate "Unencrypted /boot partition") || return 1
	GRUB_BOOT=$c
}

menu_enc() {
	local c
	c=$(ui --title " Encryption " --default-item "$ENC" --menu "Encrypt the root partition?" 12 78 3 \
		none "No encryption" \
		luks1 "LUKS1 - PBKDF2, widest GRUB compatibility" \
		luks2 "LUKS2 - Argon2id (PBKDF2 when GRUB must unlock it)") || return 1
	ENC=$c
	if encrypted; then
		if [[ -z $LUKS_PASS ]] || ! yesno "An encryption passphrase is already set.\n\nKeep it?" "Passphrase"; then
			ask_luks_pass || true
		fi
		if [[ $BOOTLOADER == grub ]]; then menu_grub_boot || true; fi
	fi
	return 0
}

ask_luks_pass() {
	local p
	p=$(ask_password "Encryption passphrase" "the disk encryption passphrase") || return 1
	if ((${#p} < 8)) && ! yesno "This passphrase is shorter than 8 characters.\n\nUse it anyway?" "Weak passphrase" 1; then
		return 1
	fi
	LUKS_PASS=$p
}

menu_bootloader() {
	local c note
	local -a items=(
		grub "GRUB 2 - can unlock an encrypted /boot"
		limine "Limine - fast and simple; kernels on a FAT32 /boot")
	if [[ $FIRMWARE == uefi && $EFI_BITS == 64 ]]; then
		items+=(
			systemd-boot "systemd-boot - plain UEFI menu; kernels on the ESP"
			refind "rEFInd - graphical UEFI boot manager"
			uki "UKI - unified kernel images, started by the firmware"
			efistub "EFISTUB - the firmware starts the kernel; no menu")
		note=""
	elif [[ $FIRMWARE == uefi ]]; then
		note="\n\nsystemd-boot, rEFInd, UKI and EFISTUB need 64-bit UEFI and are hidden."
	else
		items+=(syslinux "SYSLINUX / EXTLINUX - small BIOS boot loader")
		note="\n\nsystemd-boot, rEFInd, UKI and EFISTUB need UEFI and are hidden."
	fi
	items+=(zfsbootmenu "ZFSBootMenu - needs a ZFS root (not available)")
	local n=$((${#items[@]} / 2)) h
	h=$((n + 8))
	if [[ -n $note ]]; then h=$((h + 2)); fi
	c=$(ui --title " Boot loader " --default-item "$BOOTLOADER" --menu \
		"Boot loader (firmware: ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo ", ${EFI_BITS}-bit"))${note}" \
		"$h" 78 "$n" "${items[@]}") || return 1
	if [[ $c == zfsbootmenu ]]; then
		msg "ZFSBootMenu only boots systems whose root filesystem is a ZFS pool. This installer creates ext4 or btrfs root filesystems, so ZFSBootMenu cannot boot them.\n\nPick another boot loader. The boot loader was not changed (still: $(lbl_boot))." "ZFSBootMenu" 11 72
		return 0
	fi
	BOOTLOADER=$c
	case $BOOTLOADER in
		grub)
			if encrypted; then menu_grub_boot || true; fi
			;;
		limine)
			if encrypted; then
				msg "Limine only reads FAT filesystems, so the kernel and initramfs are placed on an unencrypted 1 GiB FAT32 /boot partition. The root filesystem stays encrypted and the initramfs asks for the passphrase." "Limine and LUKS" 10 72
			fi
			;;
		systemd-boot | refind)
			msg "The EFI system partition (1 GiB, FAT32) is mounted at /boot and holds the kernels and initramfs images. $(lbl_boot) lists them with the normal kernel first and LTS second; the list is rewritten by 'update-boot-menu' on every kernel update.$(encrypted && printf '%s' '\n\nThe root filesystem stays encrypted; the initramfs asks for the passphrase.')" "$(lbl_boot)" 12 72
			;;
		uki)
			msg "Each kernel, its initramfs and the kernel command line are bundled into one EFI program (EFI/Linux/void-<version>.efi on a 1 GiB ESP at /boot/efi) and get their own UEFI boot entry: normal kernel first, LTS second. The default one is also copied to EFI/BOOT/BOOTX64.EFI.\n\nTo boot another kernel, use the firmware's boot menu (often F8, F11 or F12). After changing the command line in /etc/default/void-boot run: update-boot-menu --rebuild$(encrypted && printf '%s' '\n\nThe UKIs are unencrypted; the root filesystem stays encrypted.')" "Unified kernel images" 15 74
			;;
		efistub)
			msg "The firmware starts the kernel directly from the ESP (mounted at /boot); one UEFI boot entry per kernel, normal kernel first, LTS second. There is no boot menu: pick another kernel in the firmware's boot menu (often F8, F11 or F12).\n\nThis needs firmware that keeps the boot entries the installer writes into NVRAM. Some boards ignore or forget them; choose UKI or systemd-boot for those." "EFISTUB" 13 74
			;;
		syslinux)
			msg "EXTLINUX is installed on a 1 GiB ext2 /boot partition marked 'legacy BIOS bootable', with SYSLINUX's GPT boot code in the first sector. No BIOS boot partition is needed.$(encrypted && printf '%s' '\n\n/boot is unencrypted; the root filesystem stays encrypted and the initramfs asks for the passphrase.')" "SYSLINUX" 10 72
			;;
	esac
	return 0
}

menu_swap() {
	local c s
	c=$(ui --title " Swap " --default-item "$SWAP" --menu "Swap space:" 12 70 3 \
		none "No swap" \
		zram "Compressed swap in RAM (zramen service)" \
		file "Swap file on the root filesystem") || return 1
	if [[ $c == file ]]; then
		s=$(ui --title " Swap file " --inputbox "Swap file size in GiB (1-128):" 9 50 "$SWAP_SIZE") || return 1
		if ! [[ $s =~ ^[0-9]+$ ]] || ((s < 1 || s > 128)); then
			msg "Please enter a whole number between 1 and 128." "Swap file"
			return 1
		fi
		SWAP_SIZE=$s
	fi
	SWAP=$c
}

# ---- kernels: any of Void's kernels, in the boot order you choose -------------
# KERNELS is the boot order: the first one boots by default, the others follow
# in the boot menu. "linux", "linux-lts" and "linux-mainline" are Void's meta
# packages that follow new releases; "linuxX.Y" stays on one series.

KERNEL_LIST=""   # "package|version|description" lines from the repository

# Fill KERNEL_LIST (call it directly, not in $(...), so the result is kept).
load_kernel_list() {
	local out
	[[ -n $KERNEL_LIST ]] && return 0
	ui --infobox "Looking up the kernels in the repository ..." 3 52 || true
	XBPS_ARCH="$(xbps_arch)" xbps-install -S -R "$(repo_url)" >/dev/null 2>&1 || true
	out=$(XBPS_ARCH="$(xbps_arch)" xbps-query -R --repository="$(repo_url)" --regex \
		-s '^linux([0-9]+\.[0-9]+|-lts|-mainline)?-[0-9]' 2>/dev/null |
		sed -nE 's/^\[.\] (linux([0-9]+\.[0-9]+|-lts|-mainline)?)-([0-9][^ ]*) +(.*)$/\1|\3|\4/p') || true
	if [[ -z $out ]]; then
		# Offline: a known list. Every name is checked when the packages install.
		out=$(printf '%s\n' "linux||meta" "linux-lts||meta" "linux-mainline||meta" \
			"linux6.18||series" "linux6.12||series" "linux6.6||series" "linux6.1||series" "linux5.15||series" "linux5.10||series")
	fi
	# meta packages first, then the series packages, newest first
	KERNEL_LIST=$(
		grep -E '^linux\|' <<<"$out"
		grep -E '^linux-lts\|' <<<"$out"
		grep -E '^linux-mainline\|' <<<"$out"
		grep -E '^linux[0-9]' <<<"$out" | sort -t'|' -k1,1 -rV
	) || true
}

kernel_ver() { # package -> its version without the revision ("6.12.117"), or ""
	local v
	v=$(awk -F'|' -v p="$1" '$1 == p { print $2; exit }' <<<"$KERNEL_LIST")
	printf '%s' "${v%_*}"
}

kernel_label() { # package -> one line for the menus
	local p=$1 v s d lts main tag=""
	v=$(kernel_ver "$p")
	d=$(kernel_ver linux) lts=$(kernel_ver linux-lts) main=$(kernel_ver linux-mainline)
	case $p in
		linux) printf "Void's default, follows new releases (now %s)" "${v:-6.x}" ;;
		linux-lts) printf 'LTS, follows new LTS releases (now %s)' "${v:-6.x}" ;;
		linux-mainline) printf 'Mainline, for experts (now %s)' "${v:-7.x}" ;;
		*)
			s=${p#linux}
			if [[ -n $d && $s == "$d" ]]; then tag="  = Void's default"; fi
			if [[ -n $lts && $s == "$lts" ]]; then tag="  = LTS"; fi
			if [[ -n $main && $s == "$main" ]]; then tag="  = mainline"; fi
			printf 'Kernel %s, stays on %s%s' "${v:-$s}" "$s" "$tag"
			;;
	esac
}

lbl_kernels() {
	local k out=""
	for k in $KERNELS; do out+="${out:+ > }$k"; done
	printf '%s' "${out:-\\Z1(none)\\Zn}"
}

# Header packages for every kernel (DKMS builds modules for each)
kernel_headers() {
	local k
	for k in $KERNELS; do echo "${k}-headers"; done
}

kernel_pick() { # tick the kernels to install; new ones join at the end
	local sel k p out=""
	local -a items=()
	while IFS='|' read -r p _ _; do
		[[ -n $p ]] && items+=("$p" "$(kernel_label "$p")")
	done <<<"$KERNEL_LIST"
	sel=$(checklist "Kernels" "Tick every kernel to install. Newly ticked ones are added at the end of the boot order; reorder them on the next screen." "$KERNELS" "${items[@]}") || return 1
	for k in $KERNELS; do
		if has "$sel" "$k"; then out+=" $k"; fi
	done
	for k in $sel; do
		if ! has "$out" "$k"; then out+=" $k"; fi
	done
	KERNELS=$(trim "$out")
}

kernel_move() { # kernel_move <package>: boot first / up / down / remove
	local k=$1 c i pos=0 n t
	local -a ks
	read -ra ks <<<"$KERNELS"
	n=${#ks[@]}
	for i in "${!ks[@]}"; do
		if [[ ${ks[i]} == "$k" ]]; then pos=$i; fi
	done
	c=$(ui --title " $k " --menu "$(kernel_label "$k")\n\nNow number $((pos + 1)) of $n in the boot order." 14 72 4 \
		first "Boot first (makes it the default)" \
		up "Move up" \
		down "Move down" \
		remove "Remove") || return 1
	case $c in
		first) KERNELS="$k $(without "$KERNELS" "$k")" ;;
		up)
			if ((pos > 0)); then
				t=${ks[pos - 1]} ks[pos - 1]=${ks[pos]} ks[pos]=$t
				KERNELS="${ks[*]}"
			fi
			;;
		down)
			if ((pos < n - 1)); then
				t=${ks[pos + 1]} ks[pos + 1]=${ks[pos]} ks[pos]=$t
				KERNELS="${ks[*]}"
			fi
			;;
		remove) KERNELS=$(without "$KERNELS" "$k") ;;
	esac
	KERNELS=$(trim "$KERNELS")
}

menu_kernel() {
	local orig=$KERNELS c="" k i n
	local -a items
	load_kernel_list
	while :; do
		items=()
		i=0
		for k in $KERNELS; do
			i=$((i + 1))
			items+=("$k" "$i. $(kernel_label "$k")")
		done
		items+=(add "+ Add or remove kernels ..." "done" "= Done")
		n=$((${#items[@]} / 2))
		c=$(ui --title " Kernels and boot order " --default-item "${c:-done}" \
			--ok-label Select --cancel-label Back --menu \
			"Kernels to install, in boot order: number 1 boots by default, the others are the next entries in the boot menu (fallbacks). Select a kernel to move or remove it." \
			$((n + 9)) 78 "$n" "${items[@]}") || {
			KERNELS=$orig
			return 1
		}
		case $c in
			done)
				if [[ -z $KERNELS ]]; then
					msg "Pick at least one kernel." "Kernels"
					continue
				fi
				if [[ $KERNELS != *" "* ]] &&
					! yesno "Only one kernel: if it fails to boot after an update there is no other kernel to choose in the boot menu.\n\nContinue with one kernel?" "One kernel" 1; then
					continue
				fi
				return 0
				;;
			add) kernel_pick || true ;;
			*) kernel_move "$c" || true ;;
		esac
	done
}

menu_libc() {
	local c
	c=$(ui --title " C library " --default-item "$LIBC" --menu "C library of the installed system:" 11 74 2 \
		glibc "GNU libc - most compatible (proprietary software, locales)" \
		musl "musl libc - small and simple; no glibc-only software") || return 1
	LIBC=$c
}

DEFAULT_MIRROR=https://repo-default.voidlinux.org

# Can the repository index of a mirror be downloaded? (uses the chosen libc/arch)
mirror_ok() { # mirror_ok <base url>
	local url
	if [[ $LIBC == musl ]]; then url="${1%/}/current/musl/x86_64-musl-repodata"; else url="${1%/}/current/x86_64-repodata"; fi
	if command -v xbps-fetch >/dev/null 2>&1; then
		timeout 60 xbps-fetch -o /dev/null "$url" >/dev/null 2>&1
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 60 -o /dev/null "$url"
	else
		return 0   # cannot test; the base-system step will report problems
	fi
}

# Test $MIRROR; when it fails offer the default mirror. Returns 1 if no working mirror.
check_mirror() {
	dialog --backtitle "$BACKTITLE" --title " Mirror " --infobox "Testing the mirror\n$MIRROR ..." 5 70 >/dev/tty 2>&1
	mirror_ok "$MIRROR" && return 0
	if [[ ${MIRROR%/} == "$DEFAULT_MIRROR" ]]; then
		msg "The default mirror cannot be reached:\n$MIRROR\n\nCheck the network connection (Wi-Fi, cable, DNS) and try again." "Mirror unreachable" 11 72
		return 1
	fi
	if yesno "The mirror does not respond (it may have shut down, or is down right now):\n\n$MIRROR\n\nUse the default mirror instead?\n$DEFAULT_MIRROR" "Mirror unreachable" 0 13 74; then
		MIRROR=$DEFAULT_MIRROR
		dialog --backtitle "$BACKTITLE" --title " Mirror " --infobox "Testing the mirror\n$MIRROR ..." 5 70 >/dev/tty 2>&1
		if mirror_ok "$MIRROR"; then return 0; fi
		msg "The default mirror cannot be reached either. Check the network connection and try again." "Mirror unreachable" 9 70
	fi
	return 1
}

menu_mirror() {
	local -a items=("https://repo-default.voidlinux.org" "Default (redirects to a tier-1 mirror)")
	local region url location tier c
	if [[ -r /usr/share/xmirror/mirrors.lst ]]; then
		while IFS=$'\t' read -r region url location tier; do
			[[ $url == http* ]] || continue
			url=${url%/}
			[[ $url == https://repo-default.voidlinux.org ]] && continue
			items+=("$url" "$location ($region, tier ${tier:-?})")
		done </usr/share/xmirror/mirrors.lst
	else
		items+=(
			"https://repo-fastly.voidlinux.org" "Fastly global CDN (tier 1)"
			"https://repo-fi.voidlinux.org" "Helsinki, Finland (tier 1)"
			"https://repo-de.voidlinux.org" "Frankfurt, Germany (tier 1)"
			"https://mirrors.summithq.com/voidlinux" "Chicago, USA (tier 1)"
		)
	fi
	items+=(custom "Enter a mirror URL")
	c=$(ui --title " Mirror " --default-item "$MIRROR" --menu "Package mirror:" 0 0 0 "${items[@]}") || return 1
	if [[ $c == custom ]]; then
		c=$(ui --title " Mirror " --inputbox "Mirror base URL (the part before /current):" 9 72 "$MIRROR") || return 1
		c=${c%/}
		c=${c%/current}
		if ! [[ $c =~ ^https?://[^[:space:]]+$ ]]; then
			msg "That does not look like an http(s) URL." "Mirror"
			return 1
		fi
	fi
	MIRROR=$c
	check_mirror || true
	return 0
}

menu_hostname() {
	local c
	c=$(ui --title " Hostname " --inputbox "Hostname of the new system:" 9 60 "$HOST_NAME") || return 1
	if ! [[ $c =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
		msg "Use letters, digits and '-' only (1-63 characters, no leading/trailing '-')." "Hostname"
		return 1
	fi
	HOST_NAME=$c
}

menu_keymap() {
	local -a maps=()
	local c
	mapfile -t maps < <(find /usr/share/kbd/keymaps -type f -name '*.map.gz' -printf '%f\n' 2>/dev/null |
		sed 's/\.map\.gz$//' | sort -u)
	if ((${#maps[@]})); then
		c=$(ui --title " Keyboard " --default-item "$KEYMAP" --no-items --menu "Console keymap:" 0 0 0 "${maps[@]}") || return 1
	else
		c=$(ui --title " Keyboard " --inputbox "Console keymap (e.g. us, de, fr, uk):" 9 60 "$KEYMAP") || return 1
	fi
	[[ $c =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	KEYMAP=$c
	# Use it right away, so passphrases typed in this installer match the boot prompt.
	loadkeys "$KEYMAP" >/dev/null 2>&1 || true
}

menu_locale() {
	local -a items=()
	local c
	if [[ $LIBC == musl ]]; then
		msg "musl has no locale support, so this setting is not used." "Locale"
		return 0
	fi
	if [[ -r /etc/default/libc-locales ]]; then
		mapfile -t items < <(grep -E '^#?[^ #]+ UTF-8$' /etc/default/libc-locales | sed -E 's/^#//; s/ .*//' | sort -u)
	fi
	if ((${#items[@]})); then
		c=$(ui --title " Locale " --default-item "$LOCALE" --no-items --menu "System locale:" 0 0 0 "${items[@]}") || return 1
	else
		c=$(ui --title " Locale " --inputbox "System locale (e.g. en_US.UTF-8):" 9 60 "$LOCALE") || return 1
		[[ $c =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] || { msg "Please enter a UTF-8 locale such as en_US.UTF-8." "Locale"; return 1; }
	fi
	LOCALE=$c
}

menu_timezone() {
	local -a regions=(UTC Africa America Antarctica Arctic Asia Atlantic Australia Europe Indian Pacific)
	local -a cities=()
	local r c
	r=$(ui --title " Timezone " --default-item "${TIMEZONE%%/*}" --no-items --menu "Region:" 0 0 0 "${regions[@]}") || return 1
	if [[ $r == UTC ]]; then
		TIMEZONE=UTC
		return 0
	fi
	mapfile -t cities < <(cd "/usr/share/zoneinfo/$r" 2>/dev/null && find . -type f | sed 's|^\./||' | sort)
	if ((${#cities[@]} == 0)); then
		msg "No time zones found for $r." "Timezone"
		return 1
	fi
	c=$(ui --title " Timezone: $r " --default-item "${TIMEZONE#*/}" --no-items --menu "City:" 0 0 0 "${cities[@]}") || return 1
	TIMEZONE="$r/$c"
}

menu_rootpass() {
	local p
	p=$(ask_password "Root password" "the root password") || return 1
	ROOT_PASS=$p
}

sync_primary() {
	if ((${#USERS[@]})); then
		USER_NAME=${USERS[0]}
	else
		USER_NAME=""
	fi
}

valid_login() { # valid_login <name> [allow existing on this system: 1]
	if ! [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
		msg "Invalid login name. Start with a lowercase letter or _, then lowercase letters, digits, - or _ (max 31)." "User"
		return 1
	fi
	if [[ ${2:-0} != 1 ]] && { [[ $1 == root ]] || grep -q "^${1}:" /etc/passwd 2>/dev/null; }; then
		msg "'$1' is a reserved system account name." "User"
		return 1
	fi
	return 0
}

menu_sudo_level() { # menu_sudo_level <user> -> prints sudo|nopasswd|none
	ui --title " sudo for $1 " --default-item "${U_SUDO[$1]:-sudo}" --menu "Administrator rights for $1:" 12 72 3 \
		sudo "Administrator: sudo asks for the password (wheel)" \
		nopasswd "Administrator: sudo never asks for a password" \
		none "Regular user, no sudo"
}

# Add (no argument) or edit a user.
user_dialog() {
	local u=${1:-} n p lvl
	if [[ -z $u ]]; then
		u=$(ui --title " New user " --inputbox "Login name (lowercase letters, digits, '-', '_'):" 9 64) || return 1
		valid_login "$u" || return 1
		if [[ -n ${U_SUDO[$u]+x} ]]; then
			msg "'$u' is already in the list." "User"
			return 1
		fi
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64 "${U_FULL[$u]:-}") || return 1
	if [[ $n == *:* ]]; then
		msg "The full name must not contain ':'." "User"
		return 1
	fi
	if [[ -n ${U_PASS[$u]:-} ]] && yesno "Keep the current password of $u?" "User $u"; then
		p=${U_PASS[$u]}
	else
		p=$(ask_password "Password for $u" "the password for $u") || return 1
	fi
	lvl=$(menu_sudo_level "$u") || return 1
	if [[ -z ${U_SUDO[$u]+x} ]]; then USERS+=("$u"); fi
	U_FULL[$u]=$n
	U_PASS[$u]=$p
	U_SUDO[$u]=$lvl
	sync_primary
}

remove_user() {
	local u=$1 x
	local -a keep=()
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || keep+=("$x"); done
	USERS=("${keep[@]}")
	unset 'U_FULL[$u]' 'U_PASS[$u]' 'U_SUDO[$u]'
	sync_primary
}

make_primary() {
	local u=$1 x
	local -a order=("$u")
	for x in "${USERS[@]}"; do [[ $x == "$u" ]] || order+=("$x"); done
	USERS=("${order[@]}")
	sync_primary
}

menu_user() {
	local c u a
	local -a items=()
	while true; do
		items=()
		for u in "${USERS[@]}"; do
			items+=("$u" "${U_FULL[$u]:+${U_FULL[$u]} - }$(sudo_word "$u")$([[ $u == "${USERS[0]}" ]] && echo ' - primary')")
		done
		items+=("+add" "Add a user")
		c=$(ui --title " Users " --cancel-label "Done" --menu \
			"Accounts on the new system. The primary user (first) also gets xbps-src and the dotfiles. Select a user to edit it." \
			0 0 0 "${items[@]}") || break
		if [[ $c == "+add" ]]; then
			user_dialog || true
			continue
		fi
		a=$(ui --title " $c " --menu "What to do with $c?" 12 60 4 \
			edit "Change name, password or sudo level" \
			primary "Make $c the primary user" \
			delete "Remove $c from the list") || continue
		case $a in
			edit) user_dialog "$c" || true ;;
			primary) make_primary "$c" ;;
			delete) if yesno "Remove $c?" "Users" 1; then remove_user "$c"; fi ;;
		esac
	done
	((${#USERS[@]} > 0))
}

# ---- LARBS-style bootstrap settings ---------------------------------------------
menu_bootstrap() {
	local c v re_url='^(https?|git)://[^[:space:]]+$|^git@[^[:space:]]+$'
	while true; do
		c=$(ui --title " Bootstrap (LARBS-style) " --cancel-label "Done" --menu \
			"After the base install: install a list of programs, copy a dotfiles repository into the primary user's home, set a login shell. Everything here is optional." \
			18 78 6 \
			progs "Programs list: ${BS_PROGS:-(none)}" \
			presets "Dotfile presets: $(lbl_dots)" \
			dotfiles "Own dotfiles repo: ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}" \
			shell "Login shell: $BS_SHELL" \
			power "Passwordless power/mount/update commands for wheel: $([[ $BS_POWER == 1 ]] && echo yes || echo no)" \
			example "Show the programs list format") || break
		case $c in
			presets) menu_dotfiles || true ;;
			progs)
				v=$(ui --title " Programs list " --inputbox "Path or http(s) URL of a programs CSV (see 'example'). Leave empty for none." 10 78 "$BS_PROGS") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ ^https?:// && ! -f $v ]]; then
					msg "File not found: $v" "Programs list"
					continue
				fi
				if [[ -n $v && -f $v ]]; then v=$(readlink -f "$v"); fi
				BS_PROGS=$v
				;;
			dotfiles)
				v=$(ui --title " Dotfiles " --inputbox "Git URL of a dotfiles repository (copied into the primary user's home, like LARBS). Leave empty for none." 10 78 "$BS_DOTFILES") || continue
				v=$(trim "$v")
				if [[ -n $v && ! $v =~ $re_url ]]; then
					msg "That does not look like a git URL." "Dotfiles"
					continue
				fi
				BS_DOTFILES=$v
				if [[ -n $v ]]; then
					v=$(ui --title " Dotfiles " --inputbox "Branch (leave empty for the repository's default):" 9 60 "$BS_BRANCH") || continue
					v=$(trim "$v")
					if [[ -n $v && ! $v =~ ^[A-Za-z0-9._/-]+$ ]]; then msg "Invalid branch name." "Dotfiles"; continue; fi
					BS_BRANCH=$v
				else
					BS_BRANCH=""
				fi
				;;
			shell)
				v=$(ui --title " Login shell " --default-item "$BS_SHELL" --menu "Login shell for the primary user:" 11 50 3 \
					bash "GNU Bash" zsh "Z shell" fish "fish") || continue
				BS_SHELL=$v
				;;
			power)
				if yesno "Let members of wheel run shutdown, reboot, poweroff, zzz, mount, umount and 'xbps-install -Su' without typing a password (like LARBS)?" "Power commands" 1; then BS_POWER=1; else BS_POWER=0; fi
				;;
			example)
				dialog --backtitle "$BACKTITLE" --title " Programs list format " --cr-wrap --no-collapse --msgbox \
"One program per line:  TAG,PROGRAM,DESCRIPTION
Lines starting with # are ignored. TAG:
  (empty)  package from the Void repositories
  G        git repository, built with make && make install
  S        package built from source with xbps-src
  P        Python program installed with pipx (as the user)
  F        Flatpak app from Flathub

Example:
#TAG,NAME IN REPO (OR GIT URL),PURPOSE
,firefox,\"is the web browser.\"
,vlc,\"plays videos and music.\"
G,https://git.suckless.org/st,\"is the terminal.\"
S,discord-ptb,\"is built from source.\"
P,yt-dlp,\"downloads videos.\"
F,com.spotify.Client,\"plays music.\"" 22 74 >/dev/tty 2>&1 || true
				;;
		esac
	done
	return 0
}

menu_network() {
	local c
	c=$(ui --title " Network " --default-item "$NET" --menu "Network management on the new system:" 12 76 3 \
		nm "NetworkManager (recommended; Wi-Fi via nmtui or applet)" \
		dhcpcd "dhcpcd (+ wpa_supplicant if Wi-Fi was set up here)" \
		none "Configure networking yourself later") || return 1
	NET=$c
}

# ---- desktops and window managers --------------------------------------------
# id|kind|label|packages that must install|packages installed when available
# kind: de = desktop environment, x11 / wl = X11 / Wayland window manager
desktop_table() {
	cat <<'EOF'
xfce|de|Xfce|xfce4 xfce4-pulseaudio-plugin xfce4-whiskermenu-plugin pavucontrol gnome-keyring|
kde|de|KDE Plasma|kde-plasma kde-baseapps|
gnome|de|GNOME|gnome|
mate|de|MATE|mate mate-extra pavucontrol|
cinnamon|de|Cinnamon|cinnamon gnome-terminal|
lxqt|de|LXQt|lxqt pavucontrol-qt|
budgie|de|Budgie|budgie-desktop gnome-terminal pavucontrol|
lxde|de|LXDE|lxde|
enlightenment|de|Enlightenment|enlightenment terminology|
i3|x11|i3|i3 i3status i3lock|i3blocks autotiling
bspwm|x11|bspwm|bspwm sxhkd polybar|dmenu
dwm|x11|dwm|dwm dmenu st slstatus slock|
awesome|x11|awesome|awesome|
qtile|x11|Qtile|qtile|python3-psutil python3-dbus-fast
herbstluftwm|x11|herbstluftwm|herbstluftwm|polybar
openbox|x11|Openbox|openbox obconf tint2|jgmenu lxappearance-obconf
fluxbox|x11|Fluxbox|fluxbox|
icewm|x11|IceWM|icewm|
spectrwm|x11|spectrwm|spectrwm|
leftwm|x11|LeftWM|leftwm|polybar
sway|wl|Sway|sway swaylock swayidle swaybg Waybar|xdg-desktop-portal-wlr autotiling
niri|wl|niri|niri xwayland-satellite swaybg swaylock swayidle Waybar|xdg-desktop-portal-gnome
river|wl|river|river swaybg swaylock swayidle Waybar|xdg-desktop-portal-wlr
labwc|wl|labwc|labwc swaybg swaylock swayidle Waybar|xdg-desktop-portal-wlr
wayfire|wl|Wayfire|wayfire wcm swaybg swaylock|xdg-desktop-portal-wlr
EOF
}

# The "rounded" set every X11 / Wayland window manager gets: terminal, launcher,
# notifications, compositor/wallpaper, file manager, polkit agent, lock,
# volume/brightness/media keys, screenshots, fonts and themes.
WM_X11_TOOLS="alacritty rofi dunst picom feh Thunar thunar-volman gvfs tumbler polkit-gnome xss-lock brightnessctl playerctl pamixer pavucontrol maim xclip xdotool flameshot lxappearance dex xsetroot numlockx setxkbmap xrandr arandr udiskie font-awesome6 nerd-fonts-symbols-ttf papirus-icon-theme arc-theme"
WM_WL_TOOLS="foot alacritty fuzzel wofi mako grim slurp swappy wl-clipboard cliphist brightnessctl playerctl pamixer pavucontrol Thunar thunar-volman gvfs tumbler polkit-gnome nwg-look kanshi wlogout xdg-desktop-portal xdg-desktop-portal-gtk xorg-server-xwayland udiskie font-awesome6 nerd-fonts-symbols-ttf papirus-icon-theme arc-theme"

desktop_on() { [[ -n $DESKTOP && $DESKTOP != none ]]; }
desktop_field() { desktop_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }
desktop_kind() { desktop_field "$1" 2; }
has_kind() { # has_kind de|x11|wl: is any selected desktop of that kind?
	local d
	desktop_on || return 1
	for d in $DESKTOP; do
		if [[ $(desktop_kind "$d") == "$1" ]]; then return 0; fi
	done
	return 1
}

lbl_desktop() {
	local d out=""
	if ! desktop_on; then
		printf 'none (console only)'
		return 0
	fi
	for d in $DESKTOP; do out+="${out:+, }$(desktop_field "$d" 3)"; done
	printf '%s' "$out"
}

# Login screen: an explicit choice, or picked from the selected desktops.
desktop_dm() {
	desktop_on || return 0
	case $DM in
		none) return 0 ;;
		lightdm | sddm | gdm | greetd) echo "$DM" ;;
		*)
			if has "$DESKTOP" kde || has "$DESKTOP" lxqt; then echo sddm
			elif has "$DESKTOP" gnome; then echo gdm
			elif has_kind wl && ! has_kind x11 && ! has_kind de; then echo greetd
			else echo lightdm; fi
			;;
	esac
}
lbl_dm() {
	if ! desktop_on; then printf 'n/a (no desktop)'; return 0; fi
	case $DM in
		auto) printf 'auto: %s' "$(desktop_dm)" ;;
		none) printf 'none (console + startx)' ;;
		*) printf '%s' "$DM" ;;
	esac
}

dm_packages() {
	case $(desktop_dm) in
		lightdm) printf '%s\n' lightdm lightdm-gtk-greeter ;;
		sddm) echo sddm ;;
		gdm) echo gdm ;;
		greetd)
			printf '%s\n' greetd tuigreet
			if has_kind x11 || has_kind de; then echo xinit; fi
			;;
		*) if has_kind x11 || has_kind de; then echo xinit; fi ;;
	esac
}

desktop_packages() {
	local d
	desktop_on || return 0
	printf '%s\n' xorg-minimal xorg-fonts xorg-input-drivers mesa-dri dbus elogind polkit \
		pipewire alsa-pipewire xdg-user-dirs xdg-utils noto-fonts-ttf dejavu-fonts-ttf
	for d in $DESKTOP; do
		desktop_field "$d" 4 | tr ' ' '\n'
	done
	dm_packages
}

# Installed with install_available: a missing one is skipped with a warning.
desktop_extra_packages() {
	local d
	desktop_on || return 0
	for d in $DESKTOP; do
		desktop_field "$d" 5 | tr ' ' '\n'
	done
	if has_kind x11; then tr ' ' '\n' <<<"$WM_X11_TOOLS"; fi
	if has_kind wl; then tr ' ' '\n' <<<"$WM_WL_TOOLS"; fi
	if [[ $NET == nm ]]; then
		if has_kind x11 || has_kind wl || has "$DESKTOP" xfce || has "$DESKTOP" mate ||
			has "$DESKTOP" budgie || has "$DESKTOP" lxde; then
			echo network-manager-applet
		fi
		if has "$DESKTOP" lxqt; then echo nm-tray; fi
	fi
}

menu_desktop() {
	local c id kind label
	local -a items=()
	while IFS='|' read -r id kind label _; do
		case $kind in
			de) label="Desktop:     $label" ;;
			x11) label="WM, X11:     $label" ;;
			*) label="WM, Wayland: $label" ;;
		esac
		items+=("$id" "$label")
	done < <(desktop_table)
	c=$(checklist "Desktops and window managers" "Pick any number (space toggles); each one becomes a session on the login screen. Window managers come with a bar, launcher, terminal, notifications, file manager, lock and screenshot tools." "$DESKTOP" "${items[@]}") || return 1
	DESKTOP=${c:-none}
	prune_dots
	if [[ -n $PRUNED ]]; then
		msg "These dotfile presets were removed because their desktop is no longer selected:\n\n$PRUNED" "Dotfiles" 11 70
	fi
	if desktop_on && [[ $NET != nm ]]; then
		if yesno "Desktops work best with NetworkManager.\n\nSwitch the network setting to NetworkManager?" "Network"; then
			NET="nm"
		fi
	fi
	return 0
}

menu_dm() {
	local c now
	if ! desktop_on; then
		msg "Choose a desktop or window manager first." "Login screen"
		return 1
	fi
	now=$(DM=auto desktop_dm)
	c=$(ui --title " Login screen " --default-item "$DM" --menu "Display manager for: $(lbl_desktop)" 13 78 6 \
		auto "Choose for me (now: $now)" \
		lightdm "LightDM + GTK greeter - X11 and Wayland sessions" \
		sddm "SDDM - KDE's login screen, X11 and Wayland" \
		gdm "GDM - GNOME's login screen" \
		greetd "greetd + tuigreet - text login, best for Wayland WMs" \
		none "None - log in on the console, start it yourself") || return 1
	DM=$c
}

# ---- dotfile presets ------------------------------------------------------------
# id|for (desktop ids or "any")|label|sources|packages|note
# source = <git url>#<branch>#<how>; how: skel = repo's etc/skel -> ~,
# dots = the repo's dot-files -> ~, config = repo's config/ -> ~/.config,
# build = clone to ~/.local/src and make install, fish / bash = shell configs.
dots_table() {
	local gh=https://github.com gl=https://gitlab.com/garuda-linux/themes-and-settings/settings
	local cx="$gh/CachyOS/cachyos-alacritty-config#master#skel" cp="$gh/CachyOS/cachyos-picom-config#develop#skel"
	local cdev="libX11-devel libXft-devel libXinerama-devel libxcb-devel freetype-devel fontconfig-devel harfbuzz-devel make gcc pkg-config"
	cat <<EOF
cachyos-i3|i3|CachyOS i3|$gh/CachyOS/cachyos-i3wm-settings#develop#skel $cx $cp|polybar rofi dunst picom feh pamixer polkit-gnome xob dex jq alacritty redshift font-hack-ttf|
cachyos-niri|niri|CachyOS niri|$gh/CachyOS/cachyos-niri-settings#master#skel $cx|Waybar swaybg awww swaylock mako wofi wlogout wl-clipboard bemenu kvantum qt5ct brightnessctl pamixer wob polkit-kde-agent xwayland-satellite font-awesome6 noto-fonts-emoji alacritty|
cachyos-qtile|qtile|CachyOS Qtile|$gh/CachyOS/cachyos-qtile-settings#master#skel|picom rofi Thunar alacritty python3-psutil python3-pulsectl python3-pulsectl-asyncio python3-dbus-fast polkit-gnome gnome-keyring feh qt5ct flameshot playerctl dunst font-awesome6 fonts-roboto-ttf font-ibm-plex-ttf|Its 'wired' notification daemon is not packaged by Void; dunst is installed instead.
cachyos-wayfire|wayfire|CachyOS Wayfire|$gh/CachyOS/cachyos-wayfire-settings#develop#skel $cx|bemenu kvantum qt5ct alacritty xorg-server-xwayland|
cachyos-openbox|openbox|CachyOS Openbox|$gh/CachyOS/cachyos-openbox-settings#develop#skel $cx $cp|dunst nitrogen rofi tint2 picom brightnessctl scrot xclip xsettingsd xss-lock Thunar thunar-volman tumbler mpv pavucontrol xfce4-power-manager polkit-gnome jgmenu alacritty|
cachyos-kde|kde|CachyOS KDE Plasma look|$gh/CachyOS/cachyos-kde-settings#develop#skel $cx|alacritty font-hack-ttf|
cachyos-xfce|xfce|CachyOS Xfce look|$gh/CachyOS/cachyos-xfce-settings#develop#skel $cx|alacritty kvantum qt5ct xfce4-whiskermenu-plugin|
cachyos-fish|any|CachyOS fish config (login shell: fish)|$gh/CachyOS/cachyos-fish-config#main#fish|fish-shell fastfetch bat eza fzf|
eos-i3|i3|EndeavourOS i3|$gh/endeavouros-team/endeavouros-i3wm-setup#main#skel|i3blocks rofi dunst picom dex xfce4-terminal Thunar xss-lock numlockx nitrogen feh scrot autotiling playerctl clipman polkit-gnome brightnessctl|
eos-sway|sway|EndeavourOS Sway (community)|$gh/EndeavourOS-Community-Editions/sway#main#dots|Waybar wofi mako foot swaybg swaylock swayidle grim slurp wl-clipboard|
eos-bspwm|bspwm|EndeavourOS bspwm (community)|$gh/EndeavourOS-Community-Editions/bspwm#main#dots|sxhkd polybar rofi dunst picom nitrogen feh xfce4-terminal|
eos-openbox|openbox|EndeavourOS Openbox (community)|$gh/EndeavourOS-Community-Editions/openbox#main#dots|tint2 obconf jgmenu picom|
eos-awesome|awesome|EndeavourOS awesome (community)|$gh/EndeavourOS-Community-Editions/awesome#master#dots|xfce4-terminal rofi picom|
garuda-sway|sway|Garuda Sway|$gl/garuda-sway-settings.git#master#skel|Waybar wofi mako foot swaybg swaylock swayidle grim slurp wl-clipboard|
garuda-i3|i3|Garuda i3|$gl/garuda-i3-settings.git#master#skel|rofi dunst kitty polkit-gnome numlockx xfce4-power-manager dex playerctl brightnessctl dmenu|
garuda-bspwm|bspwm|Garuda bspwm|$gl/garuda-bspwm-settings.git#master#skel|sxhkd polybar rofi dunst picom|
garuda-wayfire|wayfire|Garuda Wayfire|$gl/garuda-wayfire-settings.git#master#skel|alacritty|
larbs|dwm|LARBS (Luke Smith): voidrice, dwm, st, dmenu|$gh/LukeSmithxyz/voidrice#master#dots $gh/LukeSmithxyz/dwm#master#build $gh/LukeSmithxyz/st#master#build $gh/LukeSmithxyz/dmenu#master#build $gh/LukeSmithxyz/dwmblocks#master#build|zsh lf nsxiv mpv zathura zathura-pdf-mupdf dunst picom xwallpaper maim xclip xdotool unclutter pulsemixer neovim ffmpeg fzf font-awesome6 noto-fonts-emoji $cdev|dwm, st, dmenu and dwmblocks are built from source into /usr/local; the login shell becomes zsh.
gh0stzk-bspwm|bspwm|gh0stzk bspwm (themed rices)|$gh/gh0stzk/dotfiles#master#config|polybar sxhkd picom rofi dunst eww feh alacritty kitty jq xdotool maim xclip brightnessctl playerctl pamixer xsettingsd|Written for Arch: some scripts call tools Void does not package.
titus-bash|any|Chris Titus mybash (.bashrc + starship prompt)|$gh/ChrisTitusTech/mybash#main#bash|starship fzf zoxide bat eza fastfetch trash-cli tree multitail neovim|
EOF
}
dots_field() { dots_table | awk -F'|' -v i="$1" -v f="$2" '$1 == i { print $f; exit }'; }

# Drop presets whose desktop is no longer selected. Sets PRUNED to their labels.
PRUNED=""
prune_dots() {
	local id d kept=""
	PRUNED=""
	for id in $DOTS; do
		d=$(dots_field "$id" 2)
		if [[ $d == any ]] || has "$DESKTOP" "$d"; then
			kept+="${kept:+ }$id"
		else
			PRUNED+="${PRUNED:+, }$(dots_field "$id" 3)"
		fi
	done
	DOTS=$kept
}

lbl_dots() {
	local n
	n=$(wc -w <<<"$DOTS")
	if ((n == 0)); then printf '(none)'; elif ((n == 1)); then dots_field "$DOTS" 3; else printf '%s presets' "$n"; fi
}

menu_dotfiles() {
	local c id for label d show added="" out
	local -a items=()
	while IFS='|' read -r id for label _; do
		show=0
		if [[ $for == any ]] || ! desktop_on; then show=1; fi
		for d in $for; do
			if has "$DESKTOP" "$d"; then show=1; fi
		done
		if ((show)); then
			if [[ $for == any ]]; then items+=("$id" "$label"); else items+=("$id" "$label  [$(desktop_field "$for" 3)]"); fi
		fi
	done < <(dots_table)
	c=$(checklist "Dotfiles" "Popular configurations, copied into the primary user's home at the end of the install (an existing file is kept as name.~1~). The Void packages they use are installed when available.$(desktop_on && echo " Only presets for your desktops are shown.")" "$DOTS" "${items[@]}") || return 1
	# A preset needs its window manager.
	for id in $c; do
		for d in $(dots_field "$id" 2); do
			[[ $d == any ]] && continue
			if ! has "$DESKTOP" "$d"; then
				if desktop_on; then DESKTOP+=" $d"; else DESKTOP=$d; fi
				added+="${added:+, }$(desktop_field "$d" 3)"
			fi
		done
	done
	DOTS=$c
	out=""
	if [[ -n $added ]]; then out+="Added to Desktops: $added.\n\n"; fi
	if has "$DOTS" larbs && has "$DOTS" cachyos-fish; then
		out+="LARBS uses zsh and the CachyOS preset uses fish; the login shell is set to fish (change it under Bootstrap).\n\n"
		BS_SHELL=fish
	elif has "$DOTS" larbs && [[ $BS_SHELL == bash ]]; then
		BS_SHELL=zsh
		out+="LARBS's dotfiles expect zsh: the login shell is now zsh.\n\n"
	elif has "$DOTS" cachyos-fish && [[ $BS_SHELL != fish ]]; then
		BS_SHELL=fish
		out+="The CachyOS fish preset sets the login shell to fish.\n\n"
	fi
	if [[ -n $out ]]; then msg "${out%\\n\\n}" "Dotfiles" 11 70; fi
	return 0
}

# checklist helper: checklist "title" "text" "<current list>" tag desc tag desc ...
checklist() {
	local title=$1 text=$2 cur=$3 out
	shift 3
	local -a items=()
	while (($# >= 2)); do
		if has "$cur" "$1"; then items+=("$1" "$2" on); else items+=("$1" "$2" off); fi
		shift 2
	done
	out=$(ui --title " $title " --separate-output --checklist "$text" 0 0 0 "${items[@]}") || return 1
	printf '%s\n' "$out" | paste -sd ' ' -
}

menu_gpu() {
	local c sel det
	det=$(detect_gpus)
	c=$(ui --title " GPU drivers " --default-item "$([[ $GPU == auto || $GPU == none ]] && echo "$GPU" || echo choose)" --menu \
		"Detected: \Zb${det:-no known GPU}\Zn\n\nAuto picks open-source drivers (nouveau for NVIDIA). Choose the proprietary NVIDIA driver yourself for best NVIDIA performance." 15 78 3 \
		auto "Install drivers for the detected GPUs" \
		choose "Pick the drivers yourself" \
		none "No GPU packages") || return 1
	if [[ $c != choose ]]; then
		GPU=$c
		return 0
	fi
	sel=$(checklist "GPU drivers" "Space selects. Pick ONE NVIDIA driver at most (check your card family)." \
		"$([[ $GPU == auto || $GPU == none ]] && echo "$det" || echo "$GPU")" \
		intel "Intel - Mesa, Vulkan, VA-API" \
		amd "AMD - Mesa, RADV Vulkan, VA-API" \
		nouveau "NVIDIA open source (nouveau)" \
		nvidia "NVIDIA proprietary: RTX / GTX 16xx and newer" \
		nvidia580 "NVIDIA proprietary: GTX 9xx/10xx (Maxwell-Volta)" \
		nvidia470 "NVIDIA legacy: GTX 6xx/7xx (Kepler)" \
		nvidia390 "NVIDIA legacy: GTX 4xx/5xx (Fermi)" \
		vm "Virtual machine - Mesa + guest tools") || return 1
	GPU=${sel:-none}
}

menu_apps() {
	local sel
	sel=$(checklist "Applications" "Space selects. Installed from the Void repositories." "$APPS" \
		firefox "Firefox web browser" \
		chromium "Chromium web browser" \
		thunderbird "Thunderbird mail" \
		vlc "VLC media player" \
		mpv "mpv media player" \
		libreoffice "LibreOffice suite" \
		gimp "GIMP image editor" \
		obs "OBS Studio" \
		keepassxc "KeePassXC password manager" \
		telegram-desktop "Telegram" \
		discord "Discord (nonfree repository)" \
		flatpak "Flatpak + Flathub remote" \
		git "Git" \
		htop "htop" \
		neovim "Neovim") || return 1
	APPS=$sel
}

menu_gaming() {
	local sel
	if [[ $LIBC == musl ]]; then
		msg "32-bit libraries, Steam and Wine need glibc. Switch the C library to glibc to use this menu." "Gaming"
		return 1
	fi
	sel=$(checklist "Gaming" "Space selects. Steam turns on the 32-bit libraries and the nonfree repository automatically." "$GAMING" \
		multilib "32-bit libraries (multilib): Mesa, Vulkan, GPU driver" \
		steam "Steam (nonfree)" \
		wine "Wine (+ 32-bit Wine with multilib)" \
		winetricks "Winetricks" \
		lutris "Lutris game launcher" \
		gamemode "Feral GameMode") || return 1
	GAMING=$sel
}

menu_xsrc() {
	local c
	c=$(ui --title " xbps-src " --inputbox \
		"Packages to BUILD FROM SOURCE with xbps-src (void-packages), separated by spaces. Use it for restricted packages that Void cannot ship as binaries, or for your own templates.\n\nBuilding runs as your user and can take a long time. Leave empty to skip." \
		13 78 "$XSRC_PKGS") || return 1
	c=$(trim "$(printf '%s' "$c" | tr ',' ' ' | tr -s ' ')")
	if ! pkg_words_ok "$c"; then
		msg "Package names may only contain letters, digits and . _ + -, and must start with a letter or digit." "xbps-src"
		return 1
	fi
	XSRC_PKGS=$c
	if [[ -z $c ]]; then
		if yesno "Clone void-packages into ~/void-packages and prepare xbps-src anyway, so you can build packages later?" "xbps-src" 1; then
			XSRC_SETUP=1
		else
			XSRC_SETUP=0
		fi
	fi
	return 0
}

menu_extras() {
	local c
	c=$(ui --title " Extra packages " --inputbox \
		"Additional packages, separated by spaces (optional).\nExamples: firefox vim git htop chrony void-repo-nonfree intel-ucode" \
		10 78 "$EXTRA_PKGS") || return 1
	c=$(trim "$(printf '%s' "$c" | tr ',' ' ' | tr -s ' ')")
	if ! pkg_words_ok "$c"; then
		msg "Package names may only contain letters, digits and . _ + -, and must start with a letter or digit." "Extra packages"
		return 1
	fi
	EXTRA_PKGS=$c
}

# =============================================================================
#  Validation and confirmation
# =============================================================================
validate() {
	local -a missing=()
	[[ -n $DISK && -b $DISK ]] || missing+=("target disk")
	[[ -n $ROOT_PASS ]] || missing+=("root password")
	((${#USERS[@]} > 0)) || missing+=("at least one user account")
	if encrypted && [[ -z $LUKS_PASS ]]; then missing+=("encryption passphrase (or choose 'none')"); fi
	if ((${#missing[@]})); then
		msg "Please set first:\n$(printf '  - %s\\n' "${missing[@]}")" "Incomplete" 12 70
		return 1
	fi

	local nv count=0 g
	for g in $(gpu_list); do [[ $g == nvidia* ]] && count=$((count + 1)); done
	nv=$(nvidia_driver)
	if ((count > 1)); then
		msg "Select only one proprietary NVIDIA driver." "GPU drivers"
		return 1
	fi
	if [[ -n $nv ]] && has "$(gpu_list)" nouveau; then
		msg "The proprietary NVIDIA driver and nouveau cannot be installed together. Pick one." "GPU drivers"
		return 1
	fi
	if [[ $LIBC == musl ]] && { [[ -n $nv ]] || [[ -n $GAMING ]] || has "$APPS" discord; }; then
		msg "With musl, the proprietary NVIDIA driver, Discord and the gaming options are not available (they need glibc)." "musl"
		return 1
	fi
	if [[ $nv == nvidia470 || $nv == nvidia390 ]] && { has "$KERNELS" linux-mainline || has "$KERNELS" "linux$(kernel_ver linux-mainline)"; }; then
		yesno "Legacy NVIDIA drivers often fail to build against the mainline kernel. Continue anyway?" "NVIDIA" 1 || return 1
	fi
	if [[ -n $GAMING || -n $nv ]] && ! desktop_on; then
		yesno "You selected GPU or gaming packages without a desktop. Continue anyway?" "No desktop" 1 || return 1
	fi
	if has "$PERIPH" openlinkhub && has "$PERIPH" ckb-next; then
		msg "Pick ckb-next OR OpenLinkHub in Peripherals: they drive the same Corsair devices." "Peripherals"
		return 1
	fi
	if [[ $LIBC == musl ]] && has "$PERIPH" openlogi; then
		msg "OpenLogi is only built for glibc. Remove it from Peripherals, or use glibc." "Peripherals"
		return 1
	fi
	if periph_gui && ! desktop_on; then
		yesno "Some peripheral tools you picked are desktop apps, and no desktop is selected. Continue anyway?" "No desktop" 1 || return 1
	fi

	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		msg "$(lbl_boot) needs 64-bit UEFI firmware, but this computer was started with ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)"). Choose another boot loader." "Boot loader"
		return 1
	fi
	if bios_only && [[ $FIRMWARE != bios ]]; then
		msg "$(lbl_boot) is only offered for BIOS (legacy) systems. Choose another boot loader." "Boot loader"
		return 1
	fi
	if [[ $BOOTLOADER == efistub || $BOOTLOADER == uki ]] && [[ ! -d /sys/firmware/efi/efivars ]]; then
		msg "$(lbl_boot) writes UEFI boot entries, but the EFI variables (/sys/firmware/efi/efivars) are not available." "Boot loader"
		return 1
	fi

	if [[ -z $KERNELS ]]; then
		msg "Choose at least one kernel (menu item Kernel)." "Kernel"
		return 1
	fi

	check_mirror || return 1

	compute_layout
	local bytes need
	bytes=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
	need=$(required_mib)
	if ((bytes / 1048576 < need)); then
		msg "$DISK is too small for this configuration: $((need / 1024 + 1)) GiB are required." "Disk too small"
		return 1
	fi
	if desktop_on && ((bytes / 1073741824 < 20)); then
		yesno "A desktop installation should have at least 20 GiB.\n\nContinue anyway?" "Small disk" 1 || return 1
	fi
	if grub_unlocks && [[ $LUKS_PASS == *[![:ascii:]]* ]]; then
		yesno "The passphrase contains non-ASCII characters. GRUB reads the passphrase with a US keyboard layout and may not be able to unlock the disk.\n\nContinue anyway?" "Passphrase" 1 || return 1
	fi
	if grub_unlocks && [[ $KEYMAP != us ]]; then
		msg "Note: GRUB asks for the passphrase using the US keyboard layout, not '$KEYMAP'. Characters that differ between the layouts must be typed at their US positions." "Keyboard layout" 9 72
	fi
	return 0
}

build_summary() {
	local model
	model=$(trim "$(lsblk -dno MODEL "$DISK" 2>/dev/null)")
	cat <<EOF
Disk        $DISK  $(lsblk -dno SIZE "$DISK" | tr -d ' ')  ${model}
            \Z1\ZbEVERYTHING ON THIS DISK WILL BE ERASED\Zn
Firmware    ${FIRMWARE^^}$([[ $FIRMWARE == uefi ]] && echo " (${EFI_BITS}-bit)")
Partitions  GPT:
$(layout_lines)
Boot loader $(lbl_boot)
Swap        $(lbl_swap)
System      $LIBC; kernels: $(lbl_kernels)
Mirror      $MIRROR
Host        $HOST_NAME, keymap $KEYMAP, locale $(lbl_locale), $TIMEZONE
Users       $(lbl_user)
Bootstrap   $(lbl_bootstrap)$([[ -n $DOTS ]] && printf '; dotfiles: %s' "$DOTS")
Desktop     $(lbl_desktop)
Login       $(lbl_dm); network: $(lbl_net)
GPU         $(lbl_gpu)
Software    $(lbl_list "$(trim "$APPS $EXTRA_PKGS")"); gaming: $(lbl_list "$GAMING")
Peripherals $(lbl_periph)
xbps-src    $(lbl_xsrc)
EOF
}

confirm_install() {
	local word
	dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Summary " \
		--yes-label "Continue" --no-label "Back" --defaultno \
		--yesno "$(build_summary)" 0 0 >/dev/tty 2>&1 || return 1
	word=$(ui --title " Last chance " --inputbox \
		"\Z1\ZbAll data on $DISK will be destroyed.\Zn\n\nType the disk name (\Zb${DISK#/dev/}\Zn) to start the installation:" \
		11 70) || return 1
	if [[ $word != "${DISK#/dev/}" ]]; then
		msg "The confirmation did not match. Nothing was changed." "Cancelled"
		return 1
	fi
	return 0
}

# =============================================================================
#  Installation steps
#  Each step runs in a subshell with "set -Eeuo pipefail": the first failing
#  command aborts the step and the installer shows the end of the log.
# =============================================================================
step_prepare_live() {
	local -a need=()
	# The live ISO's xbps may be older than the repository requires.
	echo "Updating xbps on the live system (if needed) ..."
	xbps-install -Syu xbps || echo "Could not update xbps on the live system; continuing."
	command -v sfdisk >/dev/null || need+=(util-linux)
	command -v wipefs >/dev/null || need+=(util-linux)
	command -v mkfs.vfat >/dev/null || need+=(dosfstools)
	command -v mkfs.ext4 >/dev/null || need+=(e2fsprogs)
	command -v chattr >/dev/null || need+=(e2fsprogs)
	if [[ $FS == btrfs ]] && ! command -v mkfs.btrfs >/dev/null; then need+=(btrfs-progs); fi
	if encrypted && ! command -v cryptsetup >/dev/null; then need+=(cryptsetup); fi
	if ((${#need[@]} == 0)); then
		echo "All tools needed by the installer are present."
		return 0
	fi
	mapfile -t need < <(printf '%s\n' "${need[@]}" | sort -u)
	echo "Installing into the live system: ${need[*]}"
	if ! xbps-install -Sy "${need[@]}"; then
		echo "Updating xbps on the live system first ..."
		xbps-install -Syu xbps
		xbps-install -Sy "${need[@]}"
	fi
}

release_disk() {
	local disk=$1 dev mp type sw
	# Unmount everything on the disk (deepest devices first) and disable swap.
	while read -r dev; do
		while read -r mp; do
			[[ -n $mp ]] || continue
			# swap files that live on this filesystem
			while read -r sw; do
				if [[ -n $sw ]]; then swapoff "$sw" 2>/dev/null || true; fi
			done < <(awk -v m="${mp%/}/" 'NR > 1 && index($1, m) == 1 { print $1 }' /proc/swaps 2>/dev/null || true)
			echo "Unmounting $mp"
			umount -R "$mp" 2>/dev/null || umount -Rl "$mp" 2>/dev/null || true
		done < <(findmnt -rn -o TARGET -S "$dev" 2>/dev/null | sort -r || true)
		swapoff "$dev" 2>/dev/null || true
	done < <(lsblk -lnpo NAME "$disk" | tac)
	# Close LUKS / LVM mappings stacked on it.
	while read -r dev type; do
		case $type in
			crypt)
				echo "Closing $dev"
				cryptsetup close "$dev" 2>/dev/null || dmsetup remove "$dev" 2>/dev/null || true
				;;
			lvm)
				echo "Removing $dev"
				dmsetup remove "$dev" 2>/dev/null || true
				;;
		esac
	done < <(lsblk -lnpo NAME,TYPE "$disk" | tac)
}

wait_for_partitions() {
	local p _
	partprobe "$DISK" 2>/dev/null || partx -u "$DISK" 2>/dev/null || blockdev --rereadpt "$DISK" 2>/dev/null || true
	udevadm settle 2>/dev/null || true
	for p in "${ALL_PARTS[@]}"; do
		for _ in $(seq 1 30); do
			[[ -b $p ]] && break
			sleep 0.5
		done
		if [[ ! -b $p ]]; then
			echo "Partition $p did not appear." >&2
			return 1
		fi
	done
}

step_partition() {
	local p
	echo "Releasing $DISK ..."
	release_disk "$DISK"
	if mountpoint -q "$TARGET"; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET"
	fi

	echo "Removing old signatures ..."
	while read -r p; do
		[[ $p == "$DISK" ]] && continue
		wipefs -af "$p" >/dev/null 2>&1 || true
	done < <(lsblk -lnpo NAME "$DISK")
	wipefs -af "$DISK"

	echo "Partition script:"
	sfdisk_script | sed 's/^/    /'
	sfdisk_script | sfdisk --wipe always --wipe-partitions always "$DISK"
	wait_for_partitions

	if [[ $FIRMWARE == bios ]] && command -v parted >/dev/null; then
		# Some old BIOSes only boot GPT disks whose protective MBR is "active".
		parted -s "$DISK" disk_set pmbr_boot on || true
	fi
	echo
	lsblk -o NAME,SIZE,TYPE,PARTTYPENAME,PARTLABEL "$DISK" || lsblk "$DISK"
}

step_encrypt() {
	local -a fmt=(--batch-mode --type "$ENC")
	if [[ $ENC == luks2 ]]; then
		if grub_unlocks; then fmt+=(--pbkdf pbkdf2); else fmt+=(--pbkdf argon2id); fi
	fi
	echo "Creating $(enc_desc) container on $ROOT_PART ..."
	printf '%s' "$LUKS_PASS" | cryptsetup luksFormat "${fmt[@]}" --key-file=- "$ROOT_PART"
	echo "Opening it as /dev/mapper/$CRYPT_NAME ..."
	printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT_PART" "$CRYPT_NAME"
	cryptsetup luksDump "$ROOT_PART" | grep -E '^(Version|Cipher|PBKDF|Hash)|^[[:space:]]+(PBKDF|Cipher):' || true
}

mount_target() {
	local rootdev e sv mp
	rootdev=$(root_device)
	mkdir -p "$TARGET"
	if [[ $FS == btrfs ]]; then
		mount -o "$BTRFS_OPTS,subvol=@" "$rootdev" "$TARGET"
		for e in "${BTRFS_SUBVOLS[@]:1}"; do
			sv=${e%%:*}
			mp=${e#*:}
			mkdir -p "$TARGET$mp"
			mount -o "$BTRFS_OPTS,subvol=$sv" "$rootdev" "$TARGET$mp"
		done
		if [[ $SWAP == file ]]; then
			mkdir -p "$TARGET/swap"
			mount -o "noatime,subvol=@swap" "$rootdev" "$TARGET/swap"
		fi
	else
		mount -o noatime "$rootdev" "$TARGET"
	fi
	if [[ -n $BOOT_PART ]]; then
		mkdir -p "$TARGET/boot"
		if [[ $BOOT_FS == vfat ]]; then
			mount -o umask=0077 "$BOOT_PART" "$TARGET/boot"
		else
			mount -o noatime "$BOOT_PART" "$TARGET/boot"
		fi
	fi
	if [[ -n $ESP_PART ]]; then
		mkdir -p "$TARGET$ESP_MOUNT"
		mount -o umask=0077 "$ESP_PART" "$TARGET$ESP_MOUNT"
	fi
}

make_swapfile() {
	local f
	f="$TARGET$(swapfile_path)"
	echo "Creating a ${SWAP_SIZE} GiB swap file at $(swapfile_path) ..."
	if [[ $FS == btrfs ]] && btrfs filesystem mkswapfile --help >/dev/null 2>&1; then
		btrfs filesystem mkswapfile --size "${SWAP_SIZE}g" "$f"
	else
		if [[ $FS == btrfs ]]; then
			truncate -s 0 "$f"
			chattr +C "$f"   # no copy-on-write / compression for swap on btrfs
		fi
		dd if=/dev/zero of="$f" bs=1M count=$((SWAP_SIZE * 1024)) status=none
		chmod 600 "$f"
		mkswap "$f"
	fi
	chmod 600 "$f"
}

step_filesystems() {
	local rootdev e
	rootdev=$(root_device)
	case $FS in
		ext4)
			mkfs.ext4 -F -L void "$rootdev"
			;;
		btrfs)
			mkfs.btrfs -f -L void "$rootdev"
			mkdir -p "$TARGET"
			mount "$rootdev" "$TARGET"
			for e in "${BTRFS_SUBVOLS[@]}"; do
				btrfs subvolume create "$TARGET/${e%%:*}"
			done
			if [[ $SWAP == file ]]; then btrfs subvolume create "$TARGET/@swap"; fi
			umount "$TARGET"
			;;
	esac
	if [[ -n $ESP_PART ]]; then mkfs.vfat -F 32 -n EFI "$ESP_PART"; fi
	if [[ -n $BOOT_PART ]]; then
		case $BOOT_FS in
			vfat) mkfs.vfat -F 32 -n BOOT "$BOOT_PART" ;;
			ext2) mkfs.ext2 -F -L boot "$BOOT_PART" ;;
			*) mkfs.ext4 -F -L boot "$BOOT_PART" ;;
		esac
	fi

	echo "Mounting the new filesystems under $TARGET ..."
	mount_target
	if [[ $SWAP == file ]]; then make_swapfile; fi
	findmnt -R "$TARGET" || true
}

mount_chroot_fs() {
	local d
	if [[ $FIRMWARE == uefi && -d /sys/firmware/efi/efivars ]] && ! mountpoint -q /sys/firmware/efi/efivars; then
		mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
	fi
	for d in dev proc sys; do
		mkdir -p "$TARGET/$d"
		if ! mountpoint -q "$TARGET/$d"; then
			mount --rbind "/$d" "$TARGET/$d"
			mount --make-rslave "$TARGET/$d"
		fi
	done
	# A private /run, so package scripts cannot touch the live system's services.
	mkdir -p "$TARGET/run"
	if ! mountpoint -q "$TARGET/run"; then
		mount -t tmpfs -o mode=0755,nosuid,nodev tmpfs "$TARGET/run"
		if [[ -d /run/udev ]]; then
			mkdir -p "$TARGET/run/udev"
			mount --bind /run/udev "$TARGET/run/udev"
		fi
	fi
}

# base-system depends on the "linux" meta package. When it is not one of the
# chosen kernels, tell xbps to ignore it (Void's documented way), so only the
# chosen kernels are installed - now and on every update.
write_kernel_ignore() {
	local f="$TARGET/etc/xbps.d/10-void-install-kernels.conf"
	if has "$KERNELS" linux; then
		rm -f "$f"
		return 0
	fi
	mkdir -p "${f%/*}"
	cat >"$f" <<'EOF'
# Written by void-install.sh: the "linux" meta package was not chosen, so it
# is not installed even though base-system depends on it. Delete this file
# (then: xbps-install linux) to get Void's default kernel back.
ignorepkg=linux
ignorepkg=linux-headers
EOF
	echo "Kernels: $KERNELS (the 'linux' meta package is ignored)"
}

step_bootstrap() {
	local -a pkgs=(base-system)
	if encrypted; then pkgs+=(cryptsetup); fi
	mkdir -p "$TARGET/var/db/xbps/keys"
	cp -a /var/db/xbps/keys/. "$TARGET/var/db/xbps/keys/"
	write_kernel_ignore
	mount_chroot_fs
	echo "Repository:    $(repo_url)"
	echo "Architecture:  $(xbps_arch)"
	echo "Packages:      ${pkgs[*]}"
	XBPS_ARCH="$(xbps_arch)" stdbuf -oL xbps-install -S -y -r "$TARGET" -R "$(repo_url)" "${pkgs[@]}"
	rm -f "$TARGET/etc/resolv.conf"
	cp -L /etc/resolv.conf "$TARGET/etc/resolv.conf" || true
}

set_locale() {
	local f="$TARGET/etc/default/libc-locales"
	if [[ ! -f $f ]]; then
		warn "$f not found; locale not configured."
		return 0
	fi
	awk -v loc="$LOCALE" '
		{ s = $0; sub(/^#/, "", s); split(s, a, /[ \t]+/) }
		a[1] == loc && !done { print s; done = 1; next }
		{ print }
		END { if (!done) print loc " UTF-8" }' "$f" >"$f.new"
	mv "$f.new" "$f"
	printf 'LANG=%s\nLC_COLLATE=C\n' "$LOCALE" >"$TARGET/etc/locale.conf"
	in_target xbps-reconfigure -f glibc-locales
}

write_fstab() {
	local fs_uuid boot_uuid="" esp_uuid="" e sv mp
	fs_uuid=$(get_uuid "$(root_device)")
	if [[ -n $BOOT_PART ]]; then boot_uuid=$(get_uuid "$BOOT_PART"); fi
	if [[ -n $ESP_PART ]]; then esp_uuid=$(get_uuid "$ESP_PART"); fi
	{
		echo "# /etc/fstab - generated by void-install.sh"
		echo "# <device>                                 <dir>             <type> <options>                         <dump> <pass>"
		if [[ $FS == btrfs ]]; then
			for e in "${BTRFS_SUBVOLS[@]}"; do
				sv=${e%%:*}
				mp=${e#*:}
				printf 'UUID=%s  %-16s  btrfs  %s,subvol=%s  0 0\n' "$fs_uuid" "$mp" "$BTRFS_OPTS" "$sv"
			done
			if [[ $SWAP == file ]]; then
				printf 'UUID=%s  %-16s  btrfs  noatime,subvol=@swap  0 0\n' "$fs_uuid" "/swap"
			fi
		else
			printf 'UUID=%s  %-16s  ext4   defaults,noatime  0 1\n' "$fs_uuid" "/"
		fi
		if [[ -n $BOOT_PART ]]; then
			case $BOOT_FS in
				vfat) printf 'UUID=%s  %-16s  vfat   defaults,noatime,umask=0077  0 2\n' "$boot_uuid" "/boot" ;;
				ext2) printf 'UUID=%s  %-16s  ext2   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
				*) printf 'UUID=%s  %-16s  ext4   defaults,noatime  0 2\n' "$boot_uuid" "/boot" ;;
			esac
		fi
		if [[ -n $ESP_PART ]]; then
			printf 'UUID=%s  %-16s  vfat   defaults,noatime,umask=0077  0 2\n' "$esp_uuid" "$ESP_MOUNT"
		fi
		printf 'tmpfs  %-16s  tmpfs  defaults,nosuid,nodev  0 0\n' "/tmp"
		if [[ $SWAP == file ]]; then
			printf '%s  none  swap  defaults  0 0\n' "$(swapfile_path)"
		fi
	} >"$TARGET/etc/fstab"
	echo "--- /etc/fstab ---"
	cat "$TARGET/etc/fstab"
}

setup_crypt_target() {
	local luks_uuid kf=/boot/volume.key
	luks_uuid=$(get_uuid "$ROOT_PART")
	mkdir -p "$TARGET/etc/dracut.conf.d"
	if grub_unlocks; then
		# GRUB already asked for the passphrase; a key file inside the (encrypted)
		# initramfs unlocks root a second time without asking again.
		echo "Adding a key file for the initramfs ..."
		(umask 077 && head -c 64 /dev/urandom >"$TARGET$kf")
		local -a kopts=(--batch-mode --pbkdf-force-iterations 1000)
		if [[ $ENC == luks2 ]]; then kopts+=(--pbkdf pbkdf2); fi
		printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey "${kopts[@]}" --key-file=- "$ROOT_PART" "$TARGET$kf"
		chmod 000 "$TARGET$kf"
		chmod -R g-rwx,o-rwx "$TARGET/boot"
		printf '%s\tUUID=%s\t%s\tluks\n' "$CRYPT_NAME" "$luks_uuid" "$kf" >"$TARGET/etc/crypttab"
		chmod 600 "$TARGET/etc/crypttab"
		printf 'add_dracutmodules+=" crypt "\ninstall_items+=" %s /etc/crypttab "\n' "$kf" \
			>"$TARGET/etc/dracut.conf.d/10-crypt.conf"
	else
		# No crypttab entry for root: Void's boot scripts would ask for the
		# passphrase a second time. The kernel command line names the volume.
		printf 'add_dracutmodules+=" crypt "\n' >"$TARGET/etc/dracut.conf.d/10-crypt.conf"
	fi
}

# Set a password. On Void, plain "chpasswd" goes through PAM, where its service
# file ends in pam_permit: it reports success and changes NOTHING. "-c SHA512"
# makes chpasswd write /etc/shadow itself (Void's own installer does the same).
# The password travels on stdin only: never in a command line, never in the log.
set_password() { # set_password <user> <password>
	printf '%s:%s\n' "$1" "$2" | in_target chpasswd -c SHA512
	if ! awk -F: -v u="$1" '$1 == u && $2 ~ /^\$6\$/ { ok = 1 } END { exit !ok }' "$TARGET/etc/shadow"; then
		echo "The password of '$1' was not stored in /etc/shadow." >&2
		return 1
	fi
	echo "Password set for '$1'."
}

setup_users() {
	local base="" g u groups shell=/bin/bash
	for g in audio video floppy cdrom optical kvm input storage scanner lp network plugdev users xbuilder; do
		if grep -q "^${g}:" "$TARGET/etc/group"; then base+="${base:+,}$g"; fi
	done
	for u in "${USERS[@]}"; do
		groups=$base
		if [[ ${U_SUDO[$u]} != none ]]; then groups="wheel,$groups"; fi
		if grep -q "^${u}:" "$TARGET/etc/passwd"; then
			in_target usermod -a -G "$groups" "$u"
			if [[ -n ${U_FULL[$u]} ]]; then in_target usermod -c "${U_FULL[$u]}" "$u"; fi
		else
			in_target useradd -m -s "$shell" -G "$groups" -c "${U_FULL[$u]}" "$u"
		fi
		set_password "$u" "${U_PASS[$u]}"
		mkdir -p "$TARGET/etc/sudoers.d"
		if [[ ${U_SUDO[$u]} == nopasswd ]]; then
			printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$u" >"$TARGET/etc/sudoers.d/20-nopasswd-$u"
			chmod 440 "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		else
			rm -f "$TARGET/etc/sudoers.d/20-nopasswd-$u"
		fi
		echo "User '$u': groups $groups, $(sudo_word "$u")."
	done
	if [[ -n $ROOT_PASS ]]; then
		set_password root "$ROOT_PASS"
	fi
	mkdir -p "$TARGET/etc/sudoers.d"
	if [[ ! -e $TARGET/etc/sudoers.d/10-wheel ]]; then
		printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$TARGET/etc/sudoers.d/10-wheel"
		chmod 440 "$TARGET/etc/sudoers.d/10-wheel"
	fi
	if [[ $BS_POWER == 1 ]]; then
		cat >"$TARGET/etc/sudoers.d/30-wheel-power" <<'EOF'
# void-install.sh (LARBS-style): wheel may run these without a password
%wheel ALL=(ALL:ALL) NOPASSWD: /usr/bin/shutdown,/usr/bin/reboot,/usr/bin/poweroff,/usr/bin/halt,/usr/bin/zzz,/usr/bin/ZZZ,/usr/bin/mount,/usr/bin/umount,/usr/bin/xbps-install -Su,/usr/bin/xbps-install -Syu
EOF
		chmod 440 "$TARGET/etc/sudoers.d/30-wheel-power"
	fi
	in_target visudo -c
	if [[ $STANDALONE == 0 ]]; then
		cp -n "$TARGET"/etc/skel/.[!.]* "$TARGET/root/" 2>/dev/null || true
	fi
}

step_configure() {
	in_target /bin/sh -c 'chown root:root / && chmod 755 /'
	in_target xbps-reconfigure -f base-files
	in_target xbps-reconfigure -a

	echo "Hostname, keymap, timezone ..."
	echo "$HOST_NAME" >"$TARGET/etc/hostname"
	if ! grep -qw "$HOST_NAME" "$TARGET/etc/hosts" 2>/dev/null; then
		printf '127.0.1.1\t%s\n' "$HOST_NAME" >>"$TARGET/etc/hosts"
	fi
	cat >>"$TARGET/etc/rc.conf" <<EOF

# Set by void-install.sh
KEYMAP="$KEYMAP"
HARDWARECLOCK="UTC"
EOF
	printf 'KEYMAP=%s\n' "$KEYMAP" >"$TARGET/etc/vconsole.conf"   # read by dracut
	ln -sfn "/usr/share/zoneinfo/$TIMEZONE" "$TARGET/etc/localtime"

	mkdir -p "$TARGET/etc/xbps.d"
	printf 'repository=%s\n' "$(repo_url)" >"$TARGET/etc/xbps.d/00-repository-main.conf"

	if [[ $LIBC == glibc ]]; then
		echo "Locale $LOCALE ..."
		set_locale
	fi

	write_fstab
	if encrypted; then setup_crypt_target; fi
	if [[ $FS == btrfs ]]; then
		mkdir -p "$TARGET/etc/dracut.conf.d"
		printf 'add_dracutmodules+=" btrfs "\n' >"$TARGET/etc/dracut.conf.d/20-btrfs.conf"
	fi
	setup_users
}

target_packages() {
	local k
	for k in $KERNELS; do echo "$k"; done
	# firmware, dracut and the rest that the "linux" meta package normally brings
	if ! has "$KERNELS" linux; then echo linux-base; fi
	case $BOOTLOADER in
		grub)
			echo grub
			if [[ $FIRMWARE == uefi ]]; then
				echo "grub-$(grub_efi_target)"
				echo efibootmgr
			fi
			;;
		limine)
			echo limine
			if [[ $FIRMWARE == uefi ]]; then echo efibootmgr; fi
			;;
		systemd-boot) printf '%s\n' systemd-boot efibootmgr ;;
		refind) printf '%s\n' refind efibootmgr ;;
		uki) printf '%s\n' dracut-uefi efibootmgr ;;   # dracut-uefi pulls binutils + the systemd EFI stub
		efistub) echo efibootmgr ;;
		syslinux) echo syslinux ;;
	esac
	if [[ $NET == nm ]]; then
		echo NetworkManager
		echo dbus
	fi
	if [[ $SWAP == zram ]]; then echo zramen; fi
	desktop_packages
}

link_in_target() { # link_in_target <existing file> <link path>   (paths inside the target)
	if [[ -e $TARGET$1 ]]; then
		ln -sfn "$1" "$TARGET$2"
	else
		warn "$1 not found in the new system; skipped."
	fi
}

# Console keymap -> X11 keyboard layout ("layout" or "layout variant")
xkb_layout_of() {
	local k=${1%.map.gz}
	case $k in
		us | us-acentos) echo us ;;
		uk | gb) echo gb ;;
		dvorak | dvorak-*) echo "us dvorak" ;;
		colemak) echo "us colemak" ;;
		de-latin1-nodeadkeys) echo "de nodeadkeys" ;;
		de | de-latin1 | de_CH-latin1) [[ $k == de_CH* ]] && echo ch || echo de ;;
		sg | sg-latin1 | ch-de) echo ch ;;
		fr_CH | fr_CH-latin1 | ch-fr) echo "ch fr" ;;
		fr | fr-latin1 | fr-latin9 | fr-pc) echo fr ;;
		be-latin1 | be) echo be ;;
		br-abnt2 | br-abnt) echo br ;;
		la-latin1) echo latam ;;
		es | es-cp850) echo es ;;
		pt-latin1 | pt-latin9 | pt) echo pt ;;
		it | it2 | it-ibm) echo it ;;
		se-lat6 | se-latin1 | sv-latin1) echo se ;;
		no | no-latin1) echo no ;;
		dk | dk-latin1) echo dk ;;
		'fi') echo 'fi' ;;
		pl | pl2) echo pl ;;
		cz | cz-qwertz | cz-lat2) echo cz ;;
		cz-us-qwertz) echo "cz qwerty" ;;
		sk-qwertz) echo sk ;;
		hu) echo hu ;;
		ru | ruwin_*) echo ru ;;
		ua | ua-utf) echo ua ;;
		jp106) echo jp ;;
		tr_q-latin5 | trq) echo tr ;;
		*) k=${k%%[-_]*}; echo "${k%%[0-9]*}" ;;
	esac
}

# Make graphical logins (LightDM, SDDM, GDM on X11) use the same keyboard
# layout as the console, so passwords type the same everywhere.
write_x_keyboard() {
	local lv layout variant=""
	[[ $KEYMAP == us ]] && return 0
	lv=$(xkb_layout_of "$KEYMAP")
	layout=${lv%% *}
	if [[ $lv == *" "* ]]; then variant=${lv#* }; fi
	if [[ -z $layout ]]; then
		warn "Could not map keymap '$KEYMAP' to an X11 layout; the graphical login uses a US layout."
		return 0
	fi
	if [[ ! -d $TARGET/usr/share/X11/xkb/symbols ]] || [[ ! -e $TARGET/usr/share/X11/xkb/symbols/$layout ]]; then
		warn "X11 has no keyboard layout '$layout' (from keymap '$KEYMAP'); the graphical login uses a US layout. Set it in /etc/X11/xorg.conf.d/00-keyboard.conf."
		return 0
	fi
	mkdir -p "$TARGET/etc/X11/xorg.conf.d"
	{
		echo "# Written by void-install.sh from the console keymap '$KEYMAP'"
		echo 'Section "InputClass"'
		echo '	Identifier "system-keyboard"'
		echo '	MatchIsKeyboard "on"'
		echo "	Option \"XkbLayout\" \"$layout\""
		if [[ -n $variant ]]; then echo "	Option \"XkbVariant\" \"$variant\""; fi
		echo 'EndSection'
	} >"$TARGET/etc/X11/xorg.conf.d/00-keyboard.conf"
	echo "X11 keyboard layout: $layout${variant:+ ($variant)} (from keymap $KEYMAP)"
}

configure_desktop() {
	desktop_on || return 0
	write_x_keyboard
	echo "Configuring PipeWire (WirePlumber, PulseAudio and ALSA interfaces, autostart) ..."
	mkdir -p "$TARGET/etc/pipewire/pipewire.conf.d" "$TARGET/etc/xdg/autostart" "$TARGET/etc/alsa/conf.d"
	link_in_target /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/10-wireplumber.conf
	link_in_target /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/20-pipewire-pulse.conf
	link_in_target /usr/share/applications/pipewire.desktop /etc/xdg/autostart/pipewire.desktop
	link_in_target /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/50-pipewire.conf
	link_in_target /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/99-pipewire-default.conf
}

gpu_packages() {
	local g list
	list=$(gpu_list)
	[[ -n $list ]] || return 0
	printf '%s\n' mesa-dri vulkan-loader
	for g in $list; do
		case $g in
			intel) printf '%s\n' mesa-vulkan-intel intel-video-accel ;;
			amd) printf '%s\n' mesa-vulkan-radeon mesa-vaapi libvdpau-va-gl xf86-video-amdgpu ;;
			nouveau) printf '%s\n' mesa-vulkan-nouveau mesa-vaapi libvdpau-va-gl xf86-video-nouveau ;;
			nvidia*) echo "$g"; kernel_headers ;;   # DKMS needs headers for every kernel
			vm)
				case $(vm_type) in
					virtualbox) echo virtualbox-ose-guest ;;
					vmware) echo open-vm-tools ;;
					qemu) printf '%s\n' spice-vdagent qemu-ga ;;
				esac
				;;
		esac
	done
	if multilib_on; then
		printf '%s\n' mesa-dri-32bit vulkan-loader-32bit
		for g in $list; do
			case $g in
				intel) echo mesa-vulkan-intel-32bit ;;
				amd) echo mesa-vulkan-radeon-32bit ;;
				nvidia*) echo "${g}-libs-32bit" ;;
			esac
		done
	fi
}

app_packages() {
	local -a a=()
	read -ra a <<<"$APPS"
	if ((${#a[@]})); then printf '%s\n' "${a[@]}"; fi
}

gaming_packages() {
	local g
	if multilib_on; then
		printf '%s\n' glibc-32bit libgcc-32bit libstdc++-32bit libdrm-32bit libglvnd-32bit mesa-dri-32bit vulkan-loader-32bit
	fi
	for g in $GAMING; do
		case $g in
			steam) echo steam ;;
			wine)
				echo wine
				if multilib_on; then echo wine-32bit; fi
				;;
			winetricks | lutris | gamemode) echo "$g" ;;
		esac
	done
}

# ---- peripherals --------------------------------------------------------------
# id|menu text (max 39 characters)|Void packages ("-": not from Void, installed by its own function)|needs a desktop
periph_table() {
	cat <<'EOF'
bluetooth|Bluetooth: bluez, Blueman (service)|bluez|0
solaar|Logitech: Solaar - pairing, battery|Solaar|1
openlogi|Logitech: OpenLogi beta [not Void]|-|1
logiops|Logitech: logiops, MX mice (service)|logiops|0
g810-led|Logitech: G keyboard lighting|g810-led|0
piper|Gaming mice: Piper (service)|piper|1
openlinkhub|Corsair: OpenLinkHub [not Void]|-|0
ckb-next|Corsair: ckb-next (service)|ckb-next|1
openrazer|Razer: OpenRazer, Polychromatic|openrazer-meta polychromatic|1
openrgb|RGB lighting, many brands: OpenRGB|openrgb|1
coolercontrol|Fans, pumps: CoolerControl (service)|coolercontrol|1
controllers|PlayStation/Switch/Steam/8BitDo pads|steam-udev-rules|0
xone|Xbox dongle, USB pads: xone (driver)|xone|0
xpadneo|Xbox pads, Bluetooth: xpadneo (driver)|xpadneo|0
sc-controller|Gamepad mapper: SC Controller|sc-controller|1
antimicrox|Gamepad to keys/mouse: AntiMicroX|antimicrox|1
oversteer|Steering wheels: Oversteer|oversteer|1
wacom|Drawing tablets: Wacom|xf86-input-wacom libwacom|0
input-remapper|Key/button remapper (service)|input-remapper|1
keyd|Key remapping daemon (service)|keyd|0
kanata|Key remapper: kanata|kanata|0
EOF
}
periph_field() { periph_table | awk -F'|' -v id="$1" -v f="$2" '$1 == id { print $f }'; }
periph_ids() { periph_table | cut -d'|' -f1; }
periph_gui() { local p; for p in $PERIPH; do [[ $(periph_field "$p" 4) == 1 ]] && return 0; done; return 1; }

# IDs that match what is plugged in (USB vendor:product) or built in (Bluetooth).
detect_periph() {
	local d v p ids="" usb=" "
	for d in /sys/bus/usb/devices/*; do
		[[ -r $d/idVendor && -r $d/idProduct ]] || continue
		v=$(<"$d/idVendor") p=$(<"$d/idProduct")
		usb+="$v:$p $v "
	done
	[[ $usb == *" 046d "* ]] && ids+=" solaar"
	[[ $usb == *" 1b1c "* ]] && ids+=" openlinkhub"
	[[ $usb == *" 1532 "* ]] && ids+=" openrazer"
	[[ $usb =~ \ (054c|057e|28de|2dc8)\  ]] && ids+=" controllers"
	[[ $usb =~ \ 045e:(02e6|02fe|02f9|091e|02ea|02dd|02e3|0b00|0b12|0b13)\  ]] && ids+=" xone"
	[[ $usb == *" 056a "* ]] && ids+=" wacom"
	compgen -G '/sys/class/bluetooth/hci*' >/dev/null && ids+=" bluetooth"
	trim "$ids"
}

PERIPH_ASKED=0
CORSAIR_HELP="Both drive the same Corsair USB devices, so only one can be installed.

\ZbOpenLinkHub\Zn (recommended): newer and actively developed. Covers the iCUE LINK hub with its fans and coolers, Commander Core / Core XT / Pro, most Corsair AIO coolers, many keyboards, mice and headsets, and DDR4/DDR5 memory lighting. Runs as a background service; you set it up in a web browser at http://127.0.0.1:27003. Not in Void: built from a fixed release (0.9.4) during the install, and not updated by xbps.

\Zbckb-next\Zn: in Void's repository and updated with the system. Keyboards and mice only (lighting, macros, remapping); no AIO coolers, fan hubs or iCUE LINK. A desktop app with a tray icon."

menu_periph() {
	local sel det cur c p
	local -a items=()
	det=$(detect_periph)
	cur=$PERIPH
	if ((PERIPH_ASKED == 0)) && [[ -z $cur ]]; then cur=$det; fi
	while IFS='|' read -r p c _ _; do items+=("$p" "$c"); done < <(periph_table)
	sel=$(checklist "Peripherals" "Detected now: \Zb${det:-nothing known}\Zn (ticked the first time). [not from Void]: downloaded from its project, checked against a fixed checksum, and not updated by xbps. Pick ckb-next OR OpenLinkHub for Corsair." "$cur" "${items[@]}") || return 1
	PERIPH_ASKED=1
	if has "$sel" openlinkhub && has "$sel" ckb-next; then
		c=$(ui --title " Corsair: pick one " --default-item openlinkhub --menu "$CORSAIR_HELP" 22 78 2 \
			openlinkhub "AIOs, hubs, iCUE LINK, more (recommended)" \
			ckb-next "keyboards and mice, from Void's repository") || return 1
		if [[ $c == openlinkhub ]]; then sel=$(without "$sel" ckb-next); else sel=$(without "$sel" openlinkhub); fi
	fi
	if [[ $LIBC == musl ]] && has "$sel" openlogi; then
		msg "OpenLogi is only built for glibc; it was left out. Use Solaar or logiops with musl." "Peripherals"
		sel=$(without "$sel" openlogi)
	fi
	c=0
	for p in solaar openlogi logiops; do has "$sel" "$p" && c=$((c + 1)); done
	if ((c > 1)); then
		yesno "Solaar, OpenLogi and logiops each take over a Logitech device; only one can control a given mouse or receiver at a time. Keep all of them anyway?" "Logitech" 1 || return 1
	fi
	PERIPH=$sel
}

lbl_periph() { lbl_list "$PERIPH"; }

periph_packages() {
	local p
	for p in $PERIPH; do
		case $p in
			bluetooth)
				echo bluez
				if desktop_on; then echo blueman; fi
				;;
			*) [[ $(periph_field "$p" 3) == - ]] || periph_field "$p" 3 | tr ' ' '\n' ;;
		esac
	done
}

periph_dkms() { has "$PERIPH" openrazer || has "$PERIPH" xone || has "$PERIPH" xpadneo; }

periph_services() {
	local p
	for p in $PERIPH; do
		case $p in
			bluetooth | xpadneo) printf '%s\n' dbus bluetoothd ;;
			logiops) echo logid ;;
			piper) printf '%s\n' dbus ratbagd ;;
			openlinkhub) echo openlinkhub ;;
			ckb-next) echo ckb-next-daemon ;;
			coolercontrol) echo coolercontrold ;;
			input-remapper) printf '%s\n' dbus input-remapper ;;
			keyd) echo keyd ;;
		esac
	done
}

# Build tools added only for an install from source, and removed afterwards.
TOOLS_ADDED=""
tools_add() { # tools_add <pkg>...; 1 if they cannot be installed
	local p add=""
	for p in "$@"; do
		in_target xbps-query "$p" >/dev/null 2>&1 || add+=" $p"
	done
	[[ -n $add ]] || return 0
	# shellcheck disable=SC2086
	in_target stdbuf -oL xbps-install -y $add || return 1
	TOOLS_ADDED+="$add"
}
tools_remove() {
	[[ -n $TOOLS_ADDED ]] || return 0
	# shellcheck disable=SC2086
	if in_target xbps-remove -y $TOOLS_ADDED >/dev/null 2>&1; then
		echo "Removed the build tools again:$TOOLS_ADDED"
		in_target xbps-remove -y -o >/dev/null 2>&1 || true
	else
		echo "Build tools left installed (another package needs them):$TOOLS_ADDED"
	fi
	TOOLS_ADDED=""
}

sha256_is() { # sha256_is <file> <expected>
	local got
	got=$(sha256sum "$1" 2>/dev/null | cut -d' ' -f1)
	if [[ $got != "$2" ]]; then
		echo "Checksum mismatch for ${1##*/}: expected $2, got ${got:-nothing}" >&2
		return 1
	fi
}

write_runit_service() { # write_runit_service <name> <run script body>
	local d=$TARGET/etc/sv/$1
	mkdir -p "$d/log"
	printf '#!/bin/sh\n# runit service written by void-install.sh\nexec 2>&1\n%s\n' "$2" >"$d/run"
	printf '#!/bin/sh\nexec vlogger -t %s -p daemon\n' "$1" >"$d/log/run"
	chmod 755 "$d/run" "$d/log/run"
	ln -sfn "/run/runit/supervise.$1" "$d/supervise"
	ln -sfn "/run/runit/supervise.$1-log" "$d/log/supervise"
}

# ---- not from Void: pinned releases ---------------------------------------------
OPENLOGI_VERSION=0.9.0
OPENLOGI_URL=https://github.com/AprilNEA/OpenLogi/releases/download/v0.9.0/openlogi-v0.9.0-linux-amd64.pkg.tar.zst
OPENLOGI_SHA256=ba428a1d8043e7ef82c9576e9fa1d37c31be781cca304e59d655af4a0ab045d4
OPENLINKHUB_VERSION=0.9.4
OPENLINKHUB_GIT=https://github.com/jurkovic-nikola/OpenLinkHub
OPENLINKHUB_COMMIT=a08204cf88fd373a0bbdbe1f4382e8c64024adca

# Each install_* below is called in "if": errexit is off, so every step checks itself.

# OpenLogi: the project's signed Linux build (glibc), unpacked into /usr/local.
install_openlogi() {
	local d=/tmp/void-openlogi
	echo "OpenLogi $OPENLOGI_VERSION (not from Void): installing the project's Linux build ..."
	tools_add bsdtar || return 1
	rm -rf "$TARGET$d" && mkdir -p "$TARGET$d" || return 1
	in_target xbps-fetch -o "$d/openlogi.pkg.tar.zst" "$OPENLOGI_URL" || return 1
	sha256_is "$TARGET$d/openlogi.pkg.tar.zst" "$OPENLOGI_SHA256" || return 1
	# usr/* -> /usr/local/*, the udev rule -> /etc; no systemd unit, no package metadata.
	in_target bsdtar -xpf "$d/openlogi.pkg.tar.zst" -C / --exclude '.*' --exclude 'usr/lib' \
		-s ',^usr/,usr/local/,' || return 1
	[[ -x $TARGET/usr/local/bin/openlogi-agent ]] || return 1
	in_target bsdtar -tf "$d/openlogi.pkg.tar.zst" --exclude '.*' --exclude 'usr/lib' |
		sed -e 's,^usr/,/usr/local/,' -e 's,^etc/,/etc/,' >"$TARGET/usr/local/share/openlogi.files" || true
	# The agent belongs to the desktop session (Wayland/X11, session bus): start it at login.
	mkdir -p "$TARGET/etc/xdg/autostart"
	cat >"$TARGET/etc/xdg/autostart/openlogi-agent.desktop" <<-'DESKTOP'
		[Desktop Entry]
		Type=Application
		Name=OpenLogi agent
		Comment=Logitech HID++ device control (started by void-install.sh)
		Exec=/usr/local/bin/openlogi-agent
		X-GNOME-Autostart-enabled=true
		NoDisplay=true
	DESKTOP
	mkdir -p "$TARGET/etc/modules-load.d"
	echo uinput >"$TARGET/etc/modules-load.d/openlogi.conf"
	rm -rf "$TARGET$d"
	echo "OpenLogi installed: run openlogi-desktop; the agent starts at login. Files: /usr/local/share/openlogi.files"
}

# OpenLinkHub: a fixed release built with Void's Go, run by runit as its own user.
install_openlinkhub() {
	local o=/opt/OpenLinkHub head
	echo "OpenLinkHub $OPENLINKHUB_VERSION (not from Void): building from source ..."
	tools_add go gcc git eudev-libudev-devel || return 1
	rm -rf "$TARGET$o"
	in_target git -c advice.detachedHead=false clone -q --depth 1 -b "$OPENLINKHUB_VERSION" "$OPENLINKHUB_GIT" "$o" || return 1
	head=$(in_target git -C "$o" rev-parse HEAD) || return 1
	if [[ $head != "$OPENLINKHUB_COMMIT" ]]; then
		echo "OpenLinkHub: tag $OPENLINKHUB_VERSION points to $head, expected $OPENLINKHUB_COMMIT" >&2
		return 1
	fi
	# go.sum pins every Go module; GOTOOLCHAIN=local keeps Void's Go (no toolchain download).
	in_target /bin/sh -c "cd $o && GOTOOLCHAIN=local GOFLAGS=-mod=readonly GOPATH=/tmp/void-go GOCACHE=/tmp/void-go/cache CGO_ENABLED=1 go build -trimpath -o OpenLinkHub ." || return 1
	rm -rf "$TARGET/tmp/void-go" "$TARGET$o/.git"
	[[ -x $TARGET$o/OpenLinkHub ]] || return 1
	if ! grep -q '^openlinkhub:' "$TARGET/etc/passwd"; then
		in_target useradd -r -M -d "$o" -s /bin/false openlinkhub || return 1
	fi
	in_target chown -R openlinkhub:openlinkhub "$o" || return 1
	mkdir -p "$TARGET/etc/udev/rules.d"
	cp "$TARGET$o/99-openlinkhub.rules" "$TARGET/etc/udev/rules.d/99-openlinkhub.rules" || return 1
	write_runit_service openlinkhub "# Corsair devices get their permissions from udev first.
udevadm trigger --subsystem-match=usb --attr-match=idVendor=1b1c >/dev/null 2>&1
udevadm settle --timeout=30 >/dev/null 2>&1
cd $o || exit 1
exec chpst -u openlinkhub:openlinkhub ./OpenLinkHub"
	echo "OpenLinkHub installed: service 'openlinkhub', web UI at http://127.0.0.1:27003"
}

# After the peripheral packages: drivers from outside Void, configs, groups.
periph_finish() {
	local p u ok
	[[ -n $PERIPH ]] || return 0
	TOOLS_ADDED=""
	for p in openlogi openlinkhub; do
		has "$PERIPH" "$p" || continue
		ok=0
		case $p in
			openlogi) if install_openlogi; then ok=1; fi ;;
			openlinkhub) if install_openlinkhub; then ok=1; fi ;;
		esac
		if ((ok == 0)); then
			warn "$p could not be installed (details in the log); the rest of the install continues."
			PERIPH=$(without "$PERIPH" "$p")   # its service is then not enabled
		fi
	done
	tools_remove
	# logid stops without a config file: start with an empty device list.
	if has "$PERIPH" logiops && [[ ! -e $TARGET/etc/logid.cfg ]]; then
		printf '%s\n' '// logiops (void-install.sh): add your devices, see https://github.com/PixlOne/logiops/wiki/Configuration' \
			'// then: sudo sv restart logid' 'devices: ();' >"$TARGET/etc/logid.cfg"
	fi
	# Groups that only exist once their package is installed.
	for u in "${USERS[@]}"; do
		if { has "$PERIPH" bluetooth || has "$PERIPH" xpadneo; } && grep -q '^bluetooth:' "$TARGET/etc/group"; then
			in_target usermod -a -G bluetooth "$u"
		fi
		if has "$PERIPH" keyd && grep -q '^keyd:' "$TARGET/etc/group"; then
			in_target usermod -a -G keyd "$u"
		fi
	done
	if has "$PERIPH" xone; then
		echo "xone: the wireless dongle needs Microsoft's firmware once; run: sudo xone-get-firmware.sh"
	fi
	return 0
}

# Extra repositories needed by the selections (+ void-repo-* typed by the user)
needed_repos() {
	local nv p
	nv=$(nvidia_driver)
	if [[ -n $nv ]] || has "$GAMING" steam || has "$APPS" discord; then echo void-repo-nonfree; fi
	if multilib_on; then
		echo void-repo-multilib
		if [[ -n $nv ]]; then echo void-repo-multilib-nonfree; fi
	fi
	for p in $EXTRA_PKGS; do
		if [[ $p == void-repo-* ]]; then echo "$p"; fi
	done
}

enable_repos() { # enable_repos void-repo-...
	local f
	(($#)) || return 0
	echo "Enabling repositories: $*"
	if ! in_target stdbuf -oL xbps-install -y "$@"; then
		warn "Could not enable the repositories: $*"
		return 0
	fi
	# Point the new repositories at the selected mirror as well.
	for f in "$TARGET"/usr/share/xbps.d/*-repository-*.conf; do
		[[ -e $f ]] || continue
		sed "s|https://repo-default.voidlinux.org|${MIRROR%/}|g" "$f" >"$TARGET/etc/xbps.d/${f##*/}"
	done
	in_target stdbuf -oL xbps-install -S || warn "Synchronizing the new repositories failed."
}

# Install the packages that exist in the repositories; never fails the install.
install_available() { # install_available "label" pkg...
	local label=$1 p
	shift
	local -a want=() avail=() missing=()
	mapfile -t want < <(printf '%s\n' "$@" | awk 'NF && !seen[$0]++')
	((${#want[@]})) || return 0
	for p in "${want[@]}"; do
		if in_target xbps-query -R "$p" >/dev/null 2>&1; then avail+=("$p"); else missing+=("$p"); fi
	done
	if ((${#missing[@]})); then warn "$label - not found in the repositories, skipped: ${missing[*]}"; fi
	((${#avail[@]})) || return 0
	echo "Installing $label: ${avail[*]}"
	if ! in_target stdbuf -oL xbps-install -y "${avail[@]}"; then
		warn "$label - installing them together failed; trying one by one."
		for p in "${avail[@]}"; do
			in_target stdbuf -oL xbps-install -y "$p" || warn "$label - could not install $p"
		done
	fi
}

install_software() {
	local -a repos=() list=() extras=()
	local p
	mapfile -t repos < <(needed_repos | awk 'NF && !seen[$0]++')
	enable_repos "${repos[@]}"

	mapfile -t list < <(desktop_extra_packages)
	install_available "desktop and window manager tools" "${list[@]}"
	mapfile -t list < <(gpu_packages)
	install_available "GPU drivers" "${list[@]}"
	mapfile -t list < <(app_packages)
	install_available "applications" "${list[@]}"
	mapfile -t list < <(gaming_packages)
	install_available "gaming packages" "${list[@]}"
	if periph_dkms; then
		mapfile -t list < <(kernel_headers)
		install_available "kernel headers (for the peripheral drivers)" "${list[@]}"
	fi
	mapfile -t list < <(periph_packages)
	install_available "peripheral support" "${list[@]}"
	for p in $EXTRA_PKGS; do
		if [[ $p != void-repo-* ]]; then extras+=("$p"); fi
	done
	install_available "extra packages" "${extras[@]}"

	if has "$APPS" flatpak; then
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo ||
			warn "Could not add the Flathub remote; run: flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"
	fi
}

wifi_conf_present() {
	grep -qs '^[[:space:]]*network=' /etc/wpa_supplicant/wpa_supplicant.conf
}

enable_services() {
	local -a svcs=()
	local s
	case $NET in
		nm) svcs+=(dbus NetworkManager) ;;
		dhcpcd)
			svcs+=(dhcpcd)
			if wifi_conf_present; then
				mkdir -p "$TARGET/etc/wpa_supplicant"
				cp /etc/wpa_supplicant/wpa_supplicant.conf "$TARGET/etc/wpa_supplicant/wpa_supplicant.conf"
				chmod 600 "$TARGET/etc/wpa_supplicant/wpa_supplicant.conf"
				svcs+=(wpa_supplicant)
			fi
			;;
	esac
	if desktop_on; then
		svcs+=(dbus elogind)
		s=$(desktop_dm)
		if [[ -n $s ]]; then svcs+=("$s"); fi
	fi
	if [[ $SWAP == zram ]]; then svcs+=(zramen); fi
	while read -r s; do svcs+=("$s"); done < <(periph_services)
	if has "$(gpu_list)" vm; then
		case $(vm_type) in
			virtualbox) svcs+=(vboxservice) ;;
			vmware) svcs+=(vmtoolsd) ;;
			qemu) svcs+=(spice-vdagentd qemu-ga) ;;
		esac
	fi
	mkdir -p "$TARGET/etc/runit/runsvdir/default"
	while read -r s; do
		[[ -n $s ]] || continue
		if [[ -d $TARGET/etc/sv/$s ]]; then
			ln -sfn "/etc/sv/$s" "$TARGET/etc/runit/runsvdir/default/$s"
			echo "Enabled service: $s"
		else
			warn "Service '$s' does not exist in the new system; not enabled."
		fi
	done < <(printf '%s\n' "${svcs[@]}" | awk 'NF && !seen[$0]++')
}

# ---- desktops: install side ---------------------------------------------------
session_exec() { # desktop id -> command a login-screen session starts
	case $1 in
		qtile) echo "qtile start" ;;
		herbstluftwm) echo "herbstluftwm --locked" ;;
		openbox) echo openbox-session ;;
		fluxbox) echo startfluxbox ;;
		icewm) echo icewm-session ;;
		dwm) echo /usr/local/bin/dwm-session ;;
		niri) echo "niri --session" ;;
		*) echo "$1" ;;
	esac
}

# /usr/local/bin/void-session: starts a bare window manager the way a desktop
# environment starts itself - inside a D-Bus session and with PipeWire running.
# Without it a window manager has no sound, and (on Wayland) no notifications
# or portals, because nothing starts the session bus or PipeWire.
write_session_wrapper() {
	mkdir -p "$TARGET/usr/local/bin"
	cat >"$TARGET/usr/local/bin/void-session" <<'EOF'
#!/bin/sh
# void-session <window manager command...>        (written by void-install.sh)
# Starts a bare window manager the way a desktop environment starts itself:
# inside a D-Bus session (notifications, portals and tray apps need one) and
# with PipeWire running for sound. Used by the "(Void session)" login entries;
# from the console: void-session sway
if [ $# -eq 0 ]; then
	echo "usage: void-session <command> [arguments]" >&2
	exit 2
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v dbus-run-session >/dev/null 2>&1; then
	exec dbus-run-session -- "$0" "$@"
fi
# Started by startx or greetd instead of a display manager: load the same
# profile files a display manager would.
if [ -n "${VOID_XPROFILE:-}" ]; then
	unset VOID_XPROFILE
	for f in /etc/profile "$HOME/.profile" /etc/xprofile "$HOME/.xprofile"; do
		if [ -f "$f" ]; then . "$f"; fi
	done
fi
pw=""
if [ -n "${XDG_RUNTIME_DIR:-}" ] && command -v pipewire >/dev/null 2>&1; then
	if pgrep -u "$(id -u)" -x pipewire >/dev/null 2>&1 && [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
		sleep 1 # perhaps started a moment ago by the profile
	fi
	if [ ! -S "$XDG_RUNTIME_DIR/pipewire-0" ]; then
		pkill -u "$(id -u)" -x pipewire 2>/dev/null # left over from an earlier login
		pipewire >/dev/null 2>&1 &
		pw=$!
	fi
fi
"$@"
rc=$?
if [ -n "$pw" ]; then
	# PipeWire and the helpers it started (pipewire-pulse, WirePlumber) end with the session
	kill "$pw" 2>/dev/null
	pkill -u "$(id -u)" -x wireplumber 2>/dev/null
	pkill -u "$(id -u)" -x pipewire 2>/dev/null
fi
exit "$rc"
EOF
	chmod 755 "$TARGET/usr/local/bin/void-session"
}

session_file() { # desktop id -> path of its "(Void session)" file inside the target
	if [[ $(desktop_kind "$1") == x11 ]]; then
		echo "/usr/share/xsessions/void-install-$1.desktop"
	else
		echo "/usr/share/wayland-sessions/void-install-$1.desktop"
	fi
}

# Every selected window manager gets a "<name> (Void session)" login entry that
# starts it through void-session. Entries shipped by the packages stay as they are.
ensure_sessions() {
	local d kind cmd bin f names
	write_session_wrapper
	if has "$DESKTOP" dwm; then
		cat >"$TARGET/usr/local/bin/dwm-session" <<'EOF'
#!/bin/sh
# dwm session (void-install.sh): status bar, then dwm.
if command -v dwmblocks >/dev/null 2>&1; then dwmblocks &
elif command -v slstatus >/dev/null 2>&1; then slstatus &
fi
exec dwm
EOF
		chmod 755 "$TARGET/usr/local/bin/dwm-session"
	fi
	for d in $DESKTOP; do
		kind=$(desktop_kind "$d")
		[[ $kind == x11 || $kind == wl ]] || continue
		cmd=$(session_exec "$d")
		bin=${cmd%% *}
		bin=${bin##*/}
		if [[ $d == dwm ]]; then bin=dwm; fi
		if [[ ! -x $TARGET/usr/bin/$bin && ! -x $TARGET/usr/local/bin/$bin ]]; then
			warn "$(desktop_field "$d" 3): '$bin' is not installed; no login session for it."
			continue
		fi
		f="$TARGET$(session_file "$d")"
		mkdir -p "${f%/*}"
		names=$d
		printf '[Desktop Entry]\nName=%s (Void session)\nComment=%s with a D-Bus session and PipeWire sound - written by void-install.sh\nExec=/usr/local/bin/void-session %s\nType=Application\nDesktopNames=%s\n' \
			"$(desktop_field "$d" 3)" "$bin" "$cmd" "$names" >"$f"
		echo "Login session: ${f#"$TARGET"}"
	done
}

de_start_cmd() { # desktop environment id -> command that starts it from startx
	case $1 in
		xfce) echo startxfce4 ;;
		kde) echo startplasma-x11 ;;
		gnome) echo gnome-session ;;
		mate) echo mate-session ;;
		cinnamon) echo cinnamon-session ;;
		lxqt) echo startlxqt ;;
		budgie) echo budgie-desktop ;;
		lxde) echo startlxde ;;
		enlightenment) echo enlightenment_start ;;
	esac
}

# Per-user defaults: the session LightDM preselects, and with no login screen
# an ~/.xinitrc so that "startx" starts the first X11 choice.
session_defaults() {
	local u home d first="" firstx="" line="" dm
	dm=$(desktop_dm)
	for d in $DESKTOP; do
		if [[ -z $first ]]; then first=$d; fi
		if [[ -z $firstx && $(desktop_kind "$d") != wl ]]; then firstx=$d; fi
	done
	if [[ -n $firstx ]]; then
		if [[ $(desktop_kind "$firstx") == x11 ]]; then
			line="exec /usr/local/bin/void-session $(session_exec "$firstx")"
		else
			line="exec dbus-run-session $(de_start_cmd "$firstx")"
		fi
	fi
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if [[ $dm == lightdm && $(desktop_kind "$first") != de && -e $TARGET$(session_file "$first") && ! -e $home/.dmrc ]]; then
			printf '[Desktop]\nSession=void-install-%s\n' "$first" >"$home/.dmrc"
			in_target chown "$u:" "/home/$u/.dmrc"
		fi
		if [[ -z $dm && -n $line && ! -e $home/.xinitrc ]]; then
			printf '#!/bin/sh\n# Written by void-install.sh: "startx" starts this session.\nexport VOID_XPROFILE=1\n%s\n' "$line" >"$home/.xinitrc"
			in_target chown "$u:" "/home/$u/.xinitrc"
			echo "No login screen: 'startx' starts ${line#exec } for $u"
		fi
	done
	if [[ -z $dm ]] && has_kind wl; then
		echo "No login screen: start a Wayland window manager from the console with e.g. 'void-session sway'."
	fi
}

# bspwm and river start with an empty screen without a config: give each user
# the package's example (dotfile presets may replace it later).
wm_default_configs() {
	local u home src d
	for u in "${USERS[@]}"; do
		home="$TARGET/home/$u"
		[[ -d $home ]] || continue
		if has "$DESKTOP" bspwm && [[ ! -e $home/.config/bspwm/bspwmrc ]]; then
			# The examples have sub-folders with their own bspwmrc/sxhkdrc: take the top-level pair.
			src=""
			for d in "$TARGET/usr/share/doc/bspwm/examples" "$TARGET/usr/share/examples/bspwm" "$TARGET/usr/share/doc/bspwm"; do
				if [[ -f $d/bspwmrc ]]; then
					src=$d/bspwmrc
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/bspwm" "$home/.config/sxhkd"
				install -m 755 "$src" "$home/.config/bspwm/bspwmrc"
				if [[ -f ${src%/*}/sxhkdrc ]]; then sed 's/\burxvt\b/alacritty/' "${src%/*}/sxhkdrc" >"$home/.config/sxhkd/sxhkdrc"; fi
				in_target chown -R "$u:" "/home/$u/.config"
				echo "bspwm: example config for $u"
			else
				warn "bspwm: no example bspwmrc found; create ~/.config/bspwm/bspwmrc."
			fi
		fi
		if has "$DESKTOP" river && [[ ! -e $home/.config/river/init ]]; then
			src=""
			for d in "$TARGET/usr/share/examples/river" "$TARGET/usr/share/doc/river/examples" "$TARGET/usr/share/doc/river"; do
				if [[ -f $d/init ]]; then
					src=$d/init
					break
				fi
			done
			if [[ -n $src ]]; then
				mkdir -p "$home/.config/river"
				install -m 755 "$src" "$home/.config/river/init"
				in_target chown -R "$u:" "/home/$u/.config"
				echo "river: example init for $u"
			fi
		fi
	done
}

write_greetd_config() {
	local x="" cmd="" first=${DESKTOP%% *}
	# X11 sessions: startx, and let void-session load ~/.xprofile as a display manager would.
	if has_kind x11 || has_kind de; then x=" --xsessions /usr/share/xsessions --xsession-wrapper 'startx /usr/bin/env VOID_XPROFILE=1'"; fi
	# Until a session was chosen once (F2), Enter starts the first Wayland choice.
	if [[ $(desktop_kind "$first") == wl && -e $TARGET$(session_file "$first") ]]; then
		cmd=" --cmd '/usr/local/bin/void-session $(session_exec "$first")'"
	fi
	mkdir -p "$TARGET/etc/greetd"
	cat >"$TARGET/etc/greetd/config.toml" <<EOF
# greetd + tuigreet (void-install.sh). F2 in tuigreet picks the session.
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --remember --remember-session --asterisks --sessions /usr/share/wayland-sessions${x}${cmd}"
user = "_greeter"
EOF
	echo "greetd: tuigreet on tty7"
}

# After all desktop packages are in: sessions, starter configs, login screen.
finish_desktop() {
	desktop_on || return 0
	ensure_sessions
	wm_default_configs
	session_defaults
	if [[ $(desktop_dm) == greetd ]]; then write_greetd_config; fi
}

# ---- dotfile presets: install side ------------------------------------------
write_dots_helper() {
	cat >"$TARGET/tmp/void-dots.sh" <<'EOF'
#!/bin/sh
# void-dots.sh <git url> <branch> <how> - run as the user (void-install.sh)
set -eu
url=$1 branch=$2 how=$3
tmp=$(mktemp -d /tmp/void-dots.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
git clone -q --depth 1 -b "$branch" "$url" "$tmp/r"
r=$tmp/r
cpb() { cp -a --backup=numbered "$@"; }
case $how in
	skel)
		[ -d "$r/etc/skel" ] || { echo "no etc/skel in $url" >&2; exit 1; }
		cpb "$r/etc/skel/." "$HOME/"
		;;
	dots)
		for f in "$r"/.[!.]* "$r"/..?*; do
			[ -e "$f" ] || continue
			case ${f##*/} in
				.git | .github | .gitignore | .gitmodules | .gitattributes | .editorconfig) continue ;;
			esac
			cpb "$f" "$HOME/"
		done
		;;
	config)
		[ -d "$r/config" ] || { echo "no config/ in $url" >&2; exit 1; }
		mkdir -p "$HOME/.config"
		cpb "$r/config/." "$HOME/.config/"
		;;
	build)
		name=${url##*/}
		name=${name%.git}
		mkdir -p "$HOME/.local/src"
		rm -rf "${HOME:?}/.local/src/$name"
		cp -a "$r" "$HOME/.local/src/$name"
		cd "$HOME/.local/src/$name"
		make
		;;
	fish)
		mkdir -p "$HOME/.config/fish"
		sed '/^source \/usr\/share\/cachyos-fish-config/d' "$r/cachyos-config.fish" >"$HOME/.config/fish/cachyos-config.fish"
		grep -qs cachyos-config.fish "$HOME/.config/fish/config.fish" ||
			echo 'source ~/.config/fish/cachyos-config.fish' >>"$HOME/.config/fish/config.fish"
		;;
	bash)
		cpb "$r/.bashrc" "$HOME/.bashrc"
		mkdir -p "$HOME/.config"
		cpb "$r/starship.toml" "$HOME/.config/starship.toml"
		;;
	*) echo "unknown method $how" >&2; exit 1 ;;
esac
EOF
	chmod 755 "$TARGET/tmp/void-dots.sh"
}

bs_presets() {
	local id d line label sources pkgs note src url branch how name re_url='^https://[A-Za-z0-9./_-]+$' re_br='^[A-Za-z0-9._/-]+$'
	local -a plist=() wm=()
	in_target stdbuf -oL xbps-install -y git || warn "Dotfiles: could not install git."
	write_dots_helper
	for id in $DOTS; do
		label="" sources="" pkgs="" note=""
		line=$(dots_table | awk -F'|' -v i="$id" '$1 == i')
		if [[ -n $line ]]; then IFS='|' read -r _ _ label sources pkgs note <<<"$line"; fi
		if [[ -z $label ]]; then
			warn "Dotfiles: unknown preset '$id' skipped."
			continue
		fi
		echo "==> Dotfiles: $label"
		if [[ -n $note ]]; then echo "    Note: $note"; fi
		read -ra plist <<<"$pkgs"
		if [[ $STANDALONE == 1 ]]; then
			# On an installed system the window manager itself may be missing.
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then read -ra wm <<<"$(desktop_field "$d" 4) $(desktop_field "$d" 5)"; plist=("${wm[@]}" "${plist[@]}"); fi
			done
		fi
		install_available "packages for $label" "${plist[@]}"
		if [[ $STANDALONE == 1 ]]; then
			# ... and it needs its "(Void session)" login entry.
			for d in $(dots_field "$id" 2); do
				if [[ $d != any ]]; then DESKTOP=$d ensure_sessions; fi
			done
		fi
		for src in $sources; do
			IFS='#' read -r url branch how <<<"$src"
			if ! [[ $url =~ $re_url && $branch =~ $re_br && $how =~ ^[a-z]+$ ]]; then
				warn "Dotfiles: bad source '$src' skipped."
				continue
			fi
			echo "    $url ($branch, $how)"
			if ! in_target su - "$USER_NAME" -c "sh /tmp/void-dots.sh '$url' '$branch' '$how'"; then
				warn "Dotfiles: $label - $url failed."
				continue
			fi
			if [[ $how == build ]]; then
				name=${url##*/}
				name=${name%.git}
				in_target /bin/sh -c "cd '/home/$USER_NAME/.local/src/$name' && make install" ||
					warn "Dotfiles: $label - 'make install' of $name failed."
			fi
		done
		if [[ $id == larbs ]]; then
			# LARBS sets PATH (status bar scripts) and its environment in
			# ~/.config/shell/profile, read by zsh on a console login. Login screens
			# read ~/.profile instead, so point that at the same file.
			in_target su - "$USER_NAME" -c '[ -e ~/.profile ] || [ ! -f ~/.config/shell/profile ] || ln -s .config/shell/profile ~/.profile' ||
				warn "Dotfiles: LARBS - could not link ~/.profile."
		fi
	done
	rm -f "$TARGET/tmp/void-dots.sh"
}

step_packages() {
	local -a pkgs=()
	echo "Updating xbps inside the new system ..."
	in_target stdbuf -oL xbps-install -Syu xbps
	mapfile -t pkgs < <(target_packages | awk 'NF && !seen[$0]++')
	if ((${#pkgs[@]})); then
		echo "Installing: ${pkgs[*]}"
		in_target stdbuf -oL xbps-install -y "${pkgs[@]}"
	fi
	configure_desktop
	install_software
	finish_desktop
	periph_finish
	enable_services
}

# ---- xbps-src -----------------------------------------------------------------
XSRC_READY=0

# Prepare ~/void-packages for the primary user. Returns 1 (after a warning) on failure.
xsrc_setup() {
	local dir="/home/$USER_NAME/void-packages"
	[[ $XSRC_READY == 1 ]] && return 0
	echo "Preparing xbps-src in ~$USER_NAME/void-packages ..."
	if ! in_target stdbuf -oL xbps-install -y git xtools; then
		warn "xbps-src: could not install git and xtools."
		return 1
	fi
	if [[ ! -d $TARGET$dir/.git ]]; then
		if ! in_target su - "$USER_NAME" -c "git clone --depth 1 https://github.com/void-linux/void-packages.git ~/void-packages"; then
			warn "xbps-src: cloning void-packages failed."
			return 1
		fi
	fi
	if ! grep -qs 'void-install.sh' "$TARGET$dir/etc/conf"; then
		{
			echo "# Added by void-install.sh"
			echo "XBPS_ALLOW_RESTRICTED=yes"
			echo "XBPS_MIRROR=${MIRROR%/}/current"
			echo "XBPS_MAKEJOBS=$(nproc)"
			if [[ $STANDALONE == 0 ]]; then
				echo "# xbps-uunshare cannot work inside the installer's chroot; uchroot can."
				echo "# After booting the new system you may delete the next line."
				echo "XBPS_CHROOT_CMD=uchroot"
			fi
		} >>"$TARGET$dir/etc/conf" || { warn "xbps-src: cannot write etc/conf."; return 1; }
		in_target chown "$USER_NAME:" "$dir/etc/conf" || true
	fi
	echo "Bootstrapping the build environment ..."
	if ! in_target su - "$USER_NAME" -c "cd ~/void-packages && ./xbps-src binary-bootstrap"; then
		warn "xbps-src: binary-bootstrap failed. After booting, run: cd ~/void-packages && ./xbps-src binary-bootstrap"
		return 1
	fi
	XSRC_READY=1
	return 0
}

# Build one package with xbps-src and install it. Never fails the install.
xsrc_build() {
	local p=$1 dir="/home/$USER_NAME/void-packages" d
	local -a repos=()
	echo "Building $p with xbps-src (this can take a long time) ..."
	if ! in_target su - "$USER_NAME" -c "cd ~/void-packages && ./xbps-src pkg $p"; then
		warn "xbps-src: building $p failed (see the log). Retry later with: ./xbps-src pkg $p"
		return 0
	fi
	for d in "$dir/hostdir/binpkgs" "$dir/hostdir/binpkgs/nonfree" "$dir/hostdir/binpkgs/multilib" "$dir/hostdir/binpkgs/multilib/nonfree"; do
		if [[ -d $TARGET$d ]]; then repos+=("--repository=$d"); fi
	done
	in_target xbps-install -y "${repos[@]}" "$p" || warn "xbps-src: $p was built but could not be installed."
	return 0
}

step_xbps_src() {
	local p
	local -a pkgs=()
	read -ra pkgs <<<"$XSRC_PKGS"
	if ! xsrc_setup; then return 0; fi
	for p in "${pkgs[@]}"; do xsrc_build "$p"; done
}

# ---- LARBS-style bootstrap ---------------------------------------------------------
bs_install_progs() {
	local csv="$TARGET/tmp/void-install-progs.csv" tag prog comment n=0 total name need_dev=0 need_pipx=0 need_flatpak=0
	local re_pkg='^[A-Za-z0-9._+-]+$' re_url='^(https?|git)://[^[:space:]"`$;|&<>]+$'
	if [[ $BS_PROGS =~ ^https?:// ]]; then
		echo "Downloading the programs list: $BS_PROGS"
		if ! in_target xbps-fetch -o /tmp/void-install-progs.csv "$BS_PROGS"; then
			warn "Bootstrap: could not download $BS_PROGS; programs list skipped."
			return 0
		fi
	else
		cp "$BS_PROGS" "$csv"
	fi
	sed -i 's/\r$//' "$csv"
	total=$(grep -cvE '^[[:space:]]*(#|$)' "$csv" || true)
	grep -qE '^G,' "$csv" && need_dev=1
	grep -qE '^P,' "$csv" && need_pipx=1
	grep -qE '^F,' "$csv" && need_flatpak=1
	if ((need_dev)); then in_target stdbuf -oL xbps-install -y git base-devel || warn "Bootstrap: could not install git/base-devel."; fi
	if ((need_pipx)); then in_target stdbuf -oL xbps-install -y python3-pipx || warn "Bootstrap: could not install pipx."; fi
	if ((need_flatpak)); then
		in_target stdbuf -oL xbps-install -y flatpak || warn "Bootstrap: could not install flatpak."
		in_target flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
	fi
	echo "Installing $total programs from the list ..."
	while IFS=, read -r -u 9 tag prog comment || [[ -n $tag$prog ]]; do
		tag=$(trim "$tag")
		prog=$(trim "$prog")
		[[ -z $tag && -z $prog ]] && continue
		[[ $tag == \#* ]] && continue
		comment=$(trim "$comment")
		comment=${comment#\"}
		comment=${comment%\"}
		n=$((n + 1))
		case $tag in
			"" | X)
				echo "==> [$n/$total] $prog $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				in_target stdbuf -oL xbps-install -y "$prog" || warn "Bootstrap: could not install $prog."
				;;
			G)
				name=${prog##*/}
				name=${name%.git}
				echo "==> [$n/$total] $name (git + make) $comment"
				if ! [[ $prog =~ $re_url && $name =~ $re_pkg ]]; then warn "Bootstrap: invalid git URL '$prog' skipped."; continue; fi
				if in_target su - "$USER_NAME" -c "mkdir -p ~/.local/src && cd ~/.local/src && { [ -d '$name' ] && git -C '$name' pull --ff-only || git clone --depth 1 '$prog' '$name'; }"; then
					in_target /bin/sh -c "cd '/home/$USER_NAME/.local/src/$name' && make && make install" || warn "Bootstrap: building $name failed."
				else
					warn "Bootstrap: cloning $prog failed."
				fi
				;;
			S)
				echo "==> [$n/$total] $prog (xbps-src) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid package name '$prog' skipped."; continue; fi
				if xsrc_setup; then xsrc_build "$prog"; fi
				;;
			P)
				echo "==> [$n/$total] $prog (pipx) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid Python package '$prog' skipped."; continue; fi
				in_target su - "$USER_NAME" -c "pipx install '$prog'" || warn "Bootstrap: pipx install $prog failed."
				;;
			F)
				echo "==> [$n/$total] $prog (Flatpak) $comment"
				if ! [[ $prog =~ $re_pkg ]]; then warn "Bootstrap: invalid Flatpak id '$prog' skipped."; continue; fi
				in_target flatpak install -y --noninteractive flathub "$prog" || warn "Bootstrap: Flatpak $prog failed."
				;;
			*)
				warn "Bootstrap: unknown tag '$tag' for $prog skipped."
				;;
		esac
	done 9<"$csv"
	rm -f "$csv"
}

bs_dotfiles() {
	local tmp=/tmp/void-install-dotfiles branch=""
	if [[ -n $BS_BRANCH ]]; then branch="-b '$BS_BRANCH'"; fi
	echo "Copying dotfiles from $BS_DOTFILES into ~$USER_NAME ..."
	in_target stdbuf -oL xbps-install -y git || true
	if in_target su - "$USER_NAME" -c "rm -rf $tmp && git clone --depth 1 $branch '$BS_DOTFILES' $tmp && tar -C $tmp --exclude=./.git --exclude=./README.md --exclude=./LICENSE --exclude=./FUNDING.yml -cf - . | tar -C ~ -xf - && rm -rf $tmp"; then
		echo "Dotfiles installed."
	else
		warn "Bootstrap: installing the dotfiles from $BS_DOTFILES failed."
	fi
}

bs_shell() {
	local pkg path
	case $BS_SHELL in
		zsh) pkg=zsh path=/bin/zsh ;;
		fish) pkg=fish-shell path=/usr/bin/fish ;;
		*) return 0 ;;
	esac
	echo "Setting the login shell of $USER_NAME to $BS_SHELL ..."
	if in_target stdbuf -oL xbps-install -y "$pkg"; then
		in_target usermod -s "$path" "$USER_NAME" || warn "Bootstrap: could not set the login shell."
	else
		warn "Bootstrap: could not install $pkg."
	fi
}

bootstrap_wanted() { [[ -n $BS_PROGS || -n $DOTS || -n $BS_DOTFILES || $BS_SHELL != bash ]]; }

step_bootstrap_user() {
	if [[ -n $BS_PROGS ]]; then bs_install_progs; fi
	if [[ -n $DOTS ]]; then bs_presets; fi
	if [[ -n $BS_DOTFILES ]]; then bs_dotfiles; fi
	bs_shell
}

# ---- boot loader ------------------------------------------------------------
cmdline_extra() {
	local c="" nv
	if encrypted; then
		c="rd.luks.uuid=$(get_uuid "$ROOT_PART")"
		if [[ $KEYMAP != us ]]; then c+=" rd.vconsole.keymap=$KEYMAP"; fi
	fi
	nv=$(nvidia_driver)
	if [[ -n $nv ]]; then c+="${c:+ }nvidia-drm.modeset=1"; fi
	printf '%s\n' "$c"
}

boot_cmdline() {
	local c e
	c="root=UUID=$(get_uuid "$(root_device)") ro loglevel=4"
	if [[ $FS == btrfs ]]; then c+=" rootflags=subvol=@"; fi
	e=$(cmdline_extra)
	if [[ -n $e ]]; then c+=" $e"; fi
	printf '%s\n' "$c"
}

install_grub() {
	local cfg="$TARGET/etc/default/grub" extra t
	extra=$(cmdline_extra)
	if [[ -n $extra ]]; then
		sed -i -E "s|^(GRUB_CMDLINE_LINUX_DEFAULT=\"[^\"]*)\"|\1 ${extra}\"|" "$cfg"
	fi
	if grub_unlocks; then
		if grep -qE '^#?GRUB_ENABLE_CRYPTODISK=' "$cfg"; then
			sed -i -E 's/^#?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' "$cfg"
		else
			echo 'GRUB_ENABLE_CRYPTODISK=y' >>"$cfg"
		fi
	fi
	# Flat menu (no "Advanced options" submenu), so every kernel is visible.
	if grep -qE '^#?GRUB_DISABLE_SUBMENU=' "$cfg"; then
		sed -i -E 's/^#?GRUB_DISABLE_SUBMENU=.*/GRUB_DISABLE_SUBMENU=y/' "$cfg"
	else
		echo 'GRUB_DISABLE_SUBMENU=y' >>"$cfg"
	fi
	write_grub_order "$TARGET"
	grep -E '^GRUB_(CMDLINE_LINUX_DEFAULT|ENABLE_CRYPTODISK|DISABLE_SUBMENU)=' "$cfg" || true

	if [[ $FIRMWARE == uefi ]]; then
		t=$(grub_efi_target)
		if ! in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=Void; then
			warn "grub-install could not register a UEFI boot entry; installed without NVRAM entry (fallback path is used)."
			in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --bootloader-id=Void --no-nvram
		fi
		# Also install to the firmware fallback path \EFI\BOOT\ for picky firmware.
		in_target grub-install --target="$t" --efi-directory="$ESP_MOUNT" --removable
	else
		in_target grub-install --target=i386-pc "$DISK"
	fi
}

# /usr/local/bin/void-kernel-order: the boot order used by every boot loader,
# set by KERNEL_ORDER in /etc/default/kernel-order.
write_kernel_order() { # write_kernel_order <root dir>
	local root=$1
	mkdir -p "$root/usr/local/bin" "$root/etc/default"
	cat >"$root/etc/default/kernel-order" <<EOF
# Boot order of the kernels (void-install.sh). Package names, first = boots by
# default; the others follow in the boot menu. Older versions and kernels not
# listed come last, newest first. linux, linux-lts and linux-mainline follow new releases;
# linuxX.Y stays on one series. After a change, refresh the boot menu:
#   GRUB: update-grub   Limine: update-limine   others: update-boot-menu
KERNEL_ORDER="$KERNELS"
EOF
	cat >"$root/usr/local/bin/void-kernel-order" <<'EOF'
#!/bin/sh
# void-kernel-order - list the kernels in /boot in boot order, one per line:
#     <version> <role>        role: default | lts | mainline | other
# The order is KERNEL_ORDER in /etc/default/kernel-order: package names, the
# first boots by default (role "default"). The newest version of each listed
# kernel comes first, in that order; then all others, newest first.
# Installed by void-install.sh; used by GRUB, Limine and update-boot-menu.
R="${ROOTDIR:-}"
case $R in
	.) R=$(pwd) ;;
	/) R="" ;;
esac
KERNEL_ORDER="linux linux-lts linux-mainline"
[ -r "$R/etc/default/kernel-order" ] && . "$R/etc/default/kernel-order"

series_of() { # package -> kernel series (X.Y)
	case $1 in
		linux[0-9]*.[0-9]*) echo "${1#linux}"; return 0 ;;
	esac
	if [ -n "$R" ]; then
		xbps-query -r "$R" -x "$1" 2>/dev/null
	else
		xbps-query -x "$1" 2>/dev/null
	fi | sed -n 's/^linux\([0-9][0-9]*\.[0-9][0-9]*\)\([<>=].*\)\{0,1\}$/\1/p' | head -n 1
}
ser() { echo "$1" | sed 's/^\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/'; }

versions=$(
	for k in "$R"/boot/vmlinuz-*; do
		[ -e "$k" ] || continue
		v=${k##*/vmlinuz-}
		[ -e "$R/boot/initramfs-$v.img" ] && echo "$v"
	done | sort -rV
)
[ -n "$versions" ] || exit 0

seen=" "
order=""
add() { # add <version>, once
	case $seen in *" $1 "*) return 0 ;; esac
	seen="$seen$1 "
	order="$order $1"
}
# the newest version of each chosen kernel, in the chosen order ...
for p in $KERNEL_ORDER; do
	s=$(series_of "$p")
	[ -n "$s" ] || continue
	for v in $versions; do
		if [ "$(ser "$v")" = "$s" ]; then
			add "$v"
			break
		fi
	done
done
# ... then everything else (older versions kept after updates, other kernels)
for v in $versions; do add "$v"; done

l=$(series_of linux-lts)
m=$(series_of linux-mainline)
n=0
for v in $order; do
	n=$((n + 1))
	s=$(ser "$v")
	if [ "$n" = 1 ]; then r=default
	elif [ -n "$l" ] && [ "$s" = "$l" ]; then r=lts
	elif [ -n "$m" ] && [ "$s" = "$m" ]; then r=mainline
	else r=other; fi
	echo "$v $r"
done
EOF
	chmod 755 "$root/usr/local/bin/void-kernel-order"
}

# GRUB: default entry = first kernel of the order, fallback = the second (regenerated by every
# grub-mkconfig, which Void's 50-grub kernel hook runs on each kernel change).
write_grub_order() { # write_grub_order <root dir>
	local root=$1
	write_kernel_order "$root"
	mkdir -p "$root/etc/grub.d"
	cat >"$root/etc/grub.d/99_void-kernel-order" <<'EOF'
#!/bin/sh
# Installed by void-install.sh: boot the first kernel of the chosen order
# (/etc/default/kernel-order) by default and fall back to the second one if GRUB
# cannot load it. Order comes from /usr/local/bin/void-kernel-order. Delete this file and run update-grub to
# get GRUB's usual "newest kernel first" behaviour back.
# Never fail: an error here would stop grub-mkconfig from writing grub.cfg.
lib="${pkgdatadir:-/usr/share/grub}/grub-mkconfig_lib"
[ -r "$lib" ] || exit 0
. "$lib"
order=$(ROOTDIR=/ /usr/local/bin/void-kernel-order 2>/dev/null) || exit 0
[ -n "$order" ] || exit 0
id=$(grub_get_device_id "${GRUB_DEVICE}") || exit 0
[ -n "$id" ] || exit 0
def=$(echo "$order" | awk 'NR == 1 { print $1 }')
lts=$(echo "$order" | awk 'NR == 2 { print $1 }')
echo "# void-install.sh: kernel order from /etc/default/kernel-order"
echo "if [ -z \"\${boot_once}\" ]; then"
echo "  set default=\"gnulinux-${def}-advanced-${id}\""
echo "fi"
if [ -n "$lts" ] && [ "$lts" != "$def" ]; then
	echo "set fallback=\"gnulinux-${lts}-advanced-${id}\""
fi
exit 0
EOF
	chmod 755 "$root/etc/grub.d/99_void-kernel-order"
}

write_limine_tools() { # write_limine_tools <root dir>
	local root=$1 cmdline efi=BOOTX64.EFI bootpart
	cmdline=$(boot_cmdline)
	if [[ $EFI_BITS == 32 ]]; then efi=BOOTIA32.EFI; fi
	# the partition mounted at /boot: the ESP on UEFI, the FAT32 /boot on BIOS
	bootpart=${ESP_PART:-$BOOT_PART}
	write_kernel_order "$root"
	mkdir -p "$root/usr/local/bin" "$root/etc/default" \
		"$root/etc/kernel.d/post-install" "$root/etc/kernel.d/post-remove"

	cat >"$root/etc/default/limine" <<EOF
# Settings for /usr/local/bin/update-limine, which rewrites
# /boot/limine/limine.conf whenever a kernel is installed or removed.
# After editing, run: update-limine
LIMINE_CMDLINE="$cmdline"
LIMINE_TIMEOUT=5
LIMINE_BRANDING="Void Linux"

# Used to refresh the boot loader itself after the limine package was updated
# (update-limine compares /usr/share/limine with the copies on /boot).
LIMINE_FIRMWARE=$FIRMWARE
LIMINE_EFI=$efi
LIMINE_BOOT_PARTUUID=$(partuuid_of "$bootpart")
LIMINE_BIOS_PART=$BIOSBOOT_NUM
EOF

	cat >"$root/usr/local/bin/update-limine" <<'EOF'
#!/bin/sh
# update-limine - regenerate the Limine boot menu from the kernels in /boot.
# Installed by void-install.sh. Settings: /etc/default/limine
set -eu

R="${ROOTDIR:-}"
[ "$R" = "/" ] && R=""

LIMINE_CMDLINE="ro"
LIMINE_TIMEOUT=5
LIMINE_BRANDING="Void Linux"
LIMINE_FIRMWARE=""
LIMINE_EFI=BOOTX64.EFI
LIMINE_BOOT_PARTUUID=""
LIMINE_BIOS_PART=""
[ -r "$R/etc/default/limine" ] && . "$R/etc/default/limine"

conf="$R/boot/limine/limine.conf"
mkdir -p "$R/boot/limine"

# Boot order: normal kernel first (default), LTS second (fallback), then others.
order=""
if [ -x "$R/usr/local/bin/void-kernel-order" ]; then
	order=$(ROOTDIR="${R:-/}" "$R/usr/local/bin/void-kernel-order") || order=""
fi
if [ -z "$order" ]; then
	order=$(
		for k in "$R"/boot/vmlinuz-*; do
			[ -e "$k" ] || continue
			v=${k##*/vmlinuz-}
			[ -e "$R/boot/initramfs-$v.img" ] && echo "$v other"
		done | sort -rV
	)
fi
if [ -z "$order" ]; then
	echo "update-limine: no kernel with a matching initramfs in $R/boot; $conf left unchanged" >&2
	exit 0
fi

{
	echo "# Generated by update-limine. Edit /etc/default/limine, then run update-limine."
	echo "# The first entry boots by default."
	echo "timeout: $LIMINE_TIMEOUT"
	echo "interface_branding: $LIMINE_BRANDING"
	echo "$order" | while read -r v role; do
		case $role in
			default) label="$v" ;;
			lts) label="$v, LTS" ;;
			mainline) label="$v, mainline" ;;
			*) label="$v" ;;
		esac
		echo
		echo "/$LIMINE_BRANDING ($label)"
		echo "    protocol: linux"
		echo "    path: boot():/vmlinuz-$v"
		echo "    module_path: boot():/initramfs-$v.img"
		echo "    cmdline: $LIMINE_CMDLINE"
	done
} >"$conf.tmp"
mv -f "$conf.tmp" "$conf"
echo "update-limine: wrote $conf ($(echo "$order" | wc -l) entries)"

# Keep the boot loader itself current. After an update of the limine package the
# copies on /boot (and, on BIOS, the boot code on the disk) are still the old
# version; replace them when they differ from /usr/share/limine.
refresh_loader() {
	src="$R/usr/share/limine"
	case $LIMINE_FIRMWARE in
		uefi)
			[ -f "$src/$LIMINE_EFI" ] || return 0
			main="$R/boot/EFI/limine/$LIMINE_EFI"
			fb="$R/boot/EFI/BOOT/$LIMINE_EFI"
			[ -f "$main" ] || return 0
			cmp -s "$src/$LIMINE_EFI" "$main" && return 0
			# the fallback copy is only replaced while it still is Limine's
			if [ -f "$fb" ] && cmp -s "$main" "$fb"; then
				cp -f "$src/$LIMINE_EFI" "$fb"
				echo "update-limine: refreshed ${fb#"$R"}"
			fi
			cp -f "$src/$LIMINE_EFI" "$main"
			echo "update-limine: refreshed ${main#"$R"}"
			;;
		bios)
			[ -f "$src/limine-bios.sys" ] || return 0
			sys="$R/boot/limine/limine-bios.sys"
			if [ -f "$sys" ] && cmp -s "$src/limine-bios.sys" "$sys"; then return 0; fi
			if [ -n "$R" ]; then
				echo "update-limine: the boot loader on the disk is out of date; run update-limine inside the system" >&2
				return 0
			fi
			pk=""
			if [ -n "$LIMINE_BOOT_PARTUUID" ] && [ -e "/dev/disk/by-partuuid/$LIMINE_BOOT_PARTUUID" ]; then
				pk=$(lsblk -no PKNAME "$(readlink -f "/dev/disk/by-partuuid/$LIMINE_BOOT_PARTUUID")" 2>/dev/null | head -n 1)
			fi
			if [ -z "$pk" ] || [ -z "$LIMINE_BIOS_PART" ]; then
				echo "update-limine: cannot find the boot disk; the boot loader was not refreshed. Run: limine bios-install <disk> <BIOS boot partition number> && cp $src/limine-bios.sys /boot/limine/" >&2
				return 0
			fi
			# stage 1+2 (disk) and stage 3 (limine-bios.sys) must be the same version
			cp -f "$src/limine-bios.sys" "$sys.new"
			if limine bios-install "/dev/$pk" "$LIMINE_BIOS_PART"; then
				mv -f "$sys.new" "$sys"
				echo "update-limine: refreshed the BIOS boot code on /dev/$pk and limine-bios.sys"
			else
				rm -f "$sys.new"
				echo "update-limine: 'limine bios-install /dev/$pk $LIMINE_BIOS_PART' failed; the old boot loader was kept" >&2
				return 1
			fi
			;;
	esac
}
refresh_loader
EOF
	chmod 755 "$root/usr/local/bin/update-limine"

	local hook
	for hook in post-install post-remove; do
		cat >"$root/etc/kernel.d/$hook/60-limine" <<'EOF'
#!/bin/sh
# Kernel hook (void-install.sh): refresh the Limine menu after a kernel change.
# Arguments: $1 = package name, $2 = kernel version. Runs from the root dir.
if [ -x usr/local/bin/update-limine ]; then
	ROOTDIR=. exec usr/local/bin/update-limine
fi
exec /usr/local/bin/update-limine
EOF
		chmod 750 "$root/etc/kernel.d/$hook/60-limine"
	done

	# xbps has no hook for "the limine package was updated", so also check once
	# per boot: a refreshed boot loader is in place from the following boot on.
	if ! grep -qs 'update-limine' "$root/etc/rc.local"; then
		printf '\n# void-install.sh: keep the Limine menu and boot loader current (see /etc/default/limine)\n[ -x /usr/local/bin/update-limine ] && /usr/local/bin/update-limine >/dev/null 2>&1\n' >>"$root/etc/rc.local"
	fi
}

# register_efi "<label>" '\EFI\dir\file.efi' - (re)create one UEFI boot entry.
register_efi() {
	in_target /bin/bash -s -- "$DISK" "$ESP_NUM" "$1" "$2" <<'EOS'
disk=$1 part=$2 label=$3 loader=$4
efibootmgr 2>/dev/null | while IFS= read -r line; do
	if [[ $line =~ ^Boot([0-9A-Fa-f]{4})\*?[[:space:]](.*)$ ]]; then
		num=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]%%$'\t'*}
		if [[ $name == "$label" ]]; then efibootmgr -q -b "$num" -B || true; fi
	fi
done
efibootmgr -q -c -d "$disk" -p "$part" -L "$label" -l "$loader"
EOS
}

# efi_entry "<label>" '<loader>' '<fallback path>' - register_efi with a warning on failure.
efi_entry() {
	if register_efi "$1" "$2"; then
		echo "UEFI boot entry '$1' created."
	else
		warn "Could not create the UEFI boot entry '$1'; the firmware fallback $3 will be used."
	fi
}

partuuid_of() { blkid -c /dev/null -s PARTUUID -o value "$1" 2>/dev/null || true; }

# Settings, /usr/local/bin/update-boot-menu and its kernel hooks, for
# systemd-boot, rEFInd, UKI, EFISTUB and SYSLINUX.
write_boot_tools() { # write_boot_tools <root dir>
	local root=$1 partuuid="" esp=/boot hook
	write_kernel_order "$root"
	if [[ -n $ESP_PART ]]; then
		partuuid=$(partuuid_of "$ESP_PART")
		esp=$ESP_MOUNT
	fi
	mkdir -p "$root/usr/local/bin" "$root/etc/default" \
		"$root/etc/kernel.d/post-install" "$root/etc/kernel.d/post-remove"

	cat >"$root/etc/default/void-boot" <<EOF
# Settings for /usr/local/bin/update-boot-menu, which rewrites the boot entries
# whenever a kernel is installed or removed. After editing, run:
#     update-boot-menu            (UKI: update-boot-menu --rebuild)
BOOT_METHOD=$BOOTLOADER
BOOT_CMDLINE="$(boot_cmdline)"
BOOT_TIMEOUT=5
BOOT_BRAND="Void Linux"
# EFI system partition: mount point, PARTUUID, and the disk/partition number
# used if the PARTUUID cannot be resolved.
ESP=$esp
ESP_PARTUUID=$partuuid
ESP_DISK=$DISK
ESP_PARTNUM=$ESP_NUM
EFI_ARCH=$(efi_arch)
EOF

	cat >"$root/usr/local/bin/update-boot-menu" <<'EOF'
#!/bin/sh
# update-boot-menu - regenerate the boot entries for systemd-boot, rEFInd,
# UKI, EFISTUB or SYSLINUX from the kernels in /boot: the normal "linux"
# kernel first (default), the LTS kernel second, then the others.
# Installed by void-install.sh. Settings: /etc/default/void-boot
#   --rebuild   (UKI) rebuild every unified kernel image, e.g. after
#               changing BOOT_CMDLINE
set -eu

REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

R="${ROOTDIR:-}"
case $R in .) R=$(pwd) ;; esac
[ "$R" = "/" ] && R=""

BOOT_METHOD=""
BOOT_CMDLINE="ro"
BOOT_TIMEOUT=5
BOOT_BRAND="Void Linux"
ESP=/boot
ESP_PARTUUID=""
ESP_DISK=""
ESP_PARTNUM=""
EFI_ARCH=x64
[ -r "$R/etc/default/void-boot" ] && . "$R/etc/default/void-boot"
E="$R$ESP"

say() { echo "update-boot-menu: $*"; }

order=""
if [ -x "$R/usr/local/bin/void-kernel-order" ]; then
	order=$(ROOTDIR="${R:-/}" "$R/usr/local/bin/void-kernel-order") || order=""
fi
if [ -z "$order" ]; then
	order=$(
		for k in "$R"/boot/vmlinuz-*; do
			[ -e "$k" ] || continue
			v=${k##*/vmlinuz-}
			[ -e "$R/boot/initramfs-$v.img" ] && echo "$v other"
		done | sort -rV
	)
fi
if [ -z "$order" ]; then
	say "no kernel with a matching initramfs in $R/boot; nothing changed" >&2
	exit 0
fi
def=$(echo "$order" | awk 'NR == 1 { print $1 }')

title_of() { # title_of <version> <role>
	case $2 in
		lts) echo "$BOOT_BRAND ($1, LTS)" ;;
		mainline) echo "$BOOT_BRAND ($1, mainline)" ;;
		*) echo "$BOOT_BRAND ($1)" ;;
	esac
}

# ---- systemd-boot: one loader entry per kernel, sorted by sort-key ----------
sdboot_menu() {
	d="$E/loader/entries"
	mkdir -p "$d"
	# ours (void-boot-*) and any written by the package's 50-systemd-boot hook
	rm -f "$d"/void-*.conf
	n=0
	while read -r v role; do
		n=$((n + 1))
		{
			echo "# Generated by update-boot-menu. Settings: /etc/default/void-boot"
			echo "title    $(title_of "$v" "$role")"
			echo "version  $v"
			printf 'sort-key void-%02d\n' "$n"
			echo "linux    /vmlinuz-$v"
			echo "initrd   /initramfs-$v.img"
			echo "options  $BOOT_CMDLINE"
		} >"$d/void-boot-$v.conf"
	done <<EOT
$order
EOT
	{
		echo "# Generated by update-boot-menu. Settings: /etc/default/void-boot"
		echo "default void-boot-$def.conf"
		echo "timeout $BOOT_TIMEOUT"
		echo "editor  no"
	} >"$E/loader/loader.conf.tmp"
	mv -f "$E/loader/loader.conf.tmp" "$E/loader/loader.conf"
}

# ---- rEFInd: manual stanzas in void-entries.conf (included by refind.conf) --
refind_menu() {
	found=0
	for d in "$E/EFI/refind" "$E/EFI/BOOT"; do
		[ -f "$d/refind.conf" ] || continue
		found=1
		icon=""
		if [ -f "$d/icons/os_void.png" ]; then icon="${d#"$E"}/icons/os_void.png"; fi
		{
			echo "# Generated by update-boot-menu. Settings: /etc/default/void-boot"
			while read -r v role; do
				echo
				echo "menuentry \"$(title_of "$v" "$role")\" {"
				if [ -n "$icon" ]; then echo "    icon    $icon"; fi
				echo "    loader  /vmlinuz-$v"
				echo "    initrd  /initramfs-$v.img"
				echo "    options \"$BOOT_CMDLINE\""
				echo "}"
			done <<EOT
$order
EOT
		} >"$d/void-entries.conf.tmp"
		mv -f "$d/void-entries.conf.tmp" "$d/void-entries.conf"
	done
	if [ "$found" = 0 ]; then
		say "no refind.conf in $E/EFI/refind or $E/EFI/BOOT" >&2
		exit 1
	fi
}

# ---- UEFI boot entries (EFISTUB and UKI) -------------------------------------
esp_target() { # sets ESP_DISK and ESP_PARTNUM
	if [ -n "$ESP_PARTUUID" ] && [ -e "/dev/disk/by-partuuid/$ESP_PARTUUID" ]; then
		dev=$(readlink -f "/dev/disk/by-partuuid/$ESP_PARTUUID")
		name=${dev##*/}
		pk=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -n 1)
		if [ -n "$pk" ] && [ -r "/sys/class/block/$name/partition" ]; then
			ESP_DISK=/dev/$pk
			ESP_PARTNUM=$(cat "/sys/class/block/$name/partition")
		fi
	fi
	if [ -z "$ESP_DISK" ] || [ -z "$ESP_PARTNUM" ]; then
		say "cannot find the EFI system partition (ESP_PARTUUID=$ESP_PARTUUID)" >&2
		return 1
	fi
}

efi_list() { # "<num> <label>" for every UEFI boot entry
	efibootmgr | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\{0,1\}[[:space:]]\{1,\}\(.*\)$/\1 \2/p' | cut -f 1
}

efi_entries() { # efi_entries stub|uki
	esp_target || return 1
	old=$(efi_list) || return 1
	echo "$old" | while read -r num lbl; do
		case $lbl in
			"$BOOT_BRAND ("[0-9]*) efibootmgr -q -b "$num" -B || exit 1 ;;
		esac
	done || return 1
	ours=""
	while read -r v role; do
		lbl=$(title_of "$v" "$role")
		if [ "$1" = stub ]; then
			efibootmgr -q -c -d "$ESP_DISK" -p "$ESP_PARTNUM" -L "$lbl" -l "\\vmlinuz-$v" \
				-u "initrd=\\initramfs-$v.img $BOOT_CMDLINE" || return 1
		else
			efibootmgr -q -c -d "$ESP_DISK" -p "$ESP_PARTNUM" -L "$lbl" -l "\\EFI\\Linux\\void-$v.efi" || return 1
		fi
		num=$(efi_list | awk -v l="$lbl" '{ n = $1; sub(/^[^ ]+ /, ""); if ($0 == l) print n }' | tail -n 1)
		if [ -n "$num" ]; then ours="$ours${ours:+,}$num"; fi
	done <<EOT
$order
EOT
	cur=$(efibootmgr | sed -n 's/^BootOrder:[[:space:]]*//p')
	new=$ours
	for b in $(echo "$cur" | tr ',' ' '); do
		case ",$ours," in
			*",$b,"*) ;;
			*) new="$new${new:+,}$b" ;;
		esac
	done
	if [ -n "$new" ]; then efibootmgr -q -o "$new" || return 1; fi
	say "UEFI boot order: $new"
}

uki_menu() {
	d="$E/EFI/Linux"
	mkdir -p "$d"
	keep=""
	while read -r v role; do
		f="$d/void-$v.efi"
		# shellcheck disable=SC3013  # -nt: supported by dash, bash and busybox sh
		if [ "$REBUILD" = 1 ] || [ ! -s "$f" ] || [ "$R/boot/initramfs-$v.img" -nt "$f" ] || [ "$R/boot/vmlinuz-$v" -nt "$f" ]; then
			say "building $f ..."
			dracut -q --force --uefi --kver "$v" --kernel-cmdline "$BOOT_CMDLINE" "$f"
		fi
		keep="$keep void-$v.efi"
	done <<EOT
$order
EOT
	for f in "$d"/void-*.efi; do
		[ -e "$f" ] || continue
		case " $keep " in
			*" ${f##*/} "*) ;;
			*) rm -f "$f" && say "removed ${f##*/}" ;;
		esac
	done
	A=$(echo "$EFI_ARCH" | tr '[:lower:]' '[:upper:]')
	mkdir -p "$E/EFI/BOOT"
	cp -f "$d/void-$def.efi" "$E/EFI/BOOT/BOOT$A.EFI"
	if ! efi_entries uki; then
		say "warning: UEFI boot entries not updated; the firmware fallback \\EFI\\BOOT\\BOOT$A.EFI starts $def" >&2
	fi
}

# ---- SYSLINUX / EXTLINUX -----------------------------------------------------
syslinux_menu() {
	d="$R/boot/syslinux"
	mkdir -p "$d"
	t=$((BOOT_TIMEOUT * 10))
	[ "$t" -gt 0 ] || t=1
	{
		echo "# Generated by update-boot-menu. Settings: /etc/default/void-boot"
		if [ -f "$d/menu.c32" ]; then
			echo "UI menu.c32"
			echo "MENU TITLE $BOOT_BRAND"
		else
			echo "PROMPT 1"
		fi
		echo "TIMEOUT $t"
		echo "DEFAULT void1"
		n=0
		while read -r v role; do
			n=$((n + 1))
			echo
			echo "LABEL void$n"
			echo "    MENU LABEL $(title_of "$v" "$role")"
			echo "    LINUX /vmlinuz-$v"
			echo "    INITRD /initramfs-$v.img"
			echo "    APPEND $BOOT_CMDLINE"
		done <<EOT
$order
EOT
	} >"$d/syslinux.cfg.tmp"
	mv -f "$d/syslinux.cfg.tmp" "$d/syslinux.cfg"
}

case $BOOT_METHOD in
	systemd-boot) sdboot_menu ;;
	refind) refind_menu ;;
	uki) uki_menu ;;
	efistub) efi_entries stub ;;
	syslinux) syslinux_menu ;;
	*)
		say "unknown BOOT_METHOD '$BOOT_METHOD' in /etc/default/void-boot" >&2
		exit 1
		;;
esac
say "$BOOT_METHOD: $(echo "$order" | wc -l) kernel(s), default $def"
EOF
	chmod 755 "$root/usr/local/bin/update-boot-menu"

	for hook in post-install post-remove; do
		cat >"$root/etc/kernel.d/$hook/60-void-boot" <<'EOF'
#!/bin/sh
# Kernel hook (void-install.sh): refresh the boot entries after a kernel change.
# Arguments: $1 = package name, $2 = kernel version. Runs from the root dir.
if [ -x usr/local/bin/update-boot-menu ]; then
	ROOTDIR=. exec usr/local/bin/update-boot-menu
fi
exec /usr/local/bin/update-boot-menu
EOF
		chmod 750 "$root/etc/kernel.d/$hook/60-void-boot"
	done
}

install_systemd_boot() {
	local a src e="$TARGET$ESP_MOUNT"
	a=$(efi_arch)
	src="$TARGET/usr/lib/systemd/boot/efi/systemd-boot$a.efi"
	if [[ ! -f $src ]]; then
		echo "systemd-boot$a.efi is missing from the systemd-boot package." >&2
		return 1
	fi
	write_boot_tools "$TARGET"
	# The package's 50-systemd-boot hook would add a second set of entries.
	printf '%s\n' "# void-install.sh: boot entries are written by /usr/local/bin/update-boot-menu" \
		"SYSTEMD_BOOT_DISABLE=1" >"$TARGET/etc/default/systemd-boot"
	mkdir -p "$e/EFI/systemd" "$e/EFI/BOOT" "$e/loader/entries"
	cp "$src" "$e/EFI/systemd/systemd-boot$a.efi"
	cp "$src" "$e/EFI/BOOT/BOOT${a^^}.EFI"   # firmware fallback path
	efi_entry "Void Linux (systemd-boot)" "\\EFI\\systemd\\systemd-boot$a.efi" "\\EFI\\BOOT\\BOOT${a^^}.EFI"
	in_target /usr/local/bin/update-boot-menu
}

install_refind() {
	local a src d e="$TARGET$ESP_MOUNT"
	a=$(efi_arch)
	src="$TARGET/usr/share/refind/refind_$a.efi"
	if [[ ! -f $src ]]; then
		echo "refind_$a.efi is missing from the refind package." >&2
		return 1
	fi
	write_boot_tools "$TARGET"
	for d in refind BOOT; do
		mkdir -p "$e/EFI/$d"
		if [[ -d $TARGET/usr/share/refind/icons ]]; then
			rm -rf "$e/EFI/$d/icons"
			cp -r "$TARGET/usr/share/refind/icons" "$e/EFI/$d/icons"
		fi
		cat >"$e/EFI/$d/refind.conf" <<'EOF'
# rEFInd configuration - written by void-install.sh.
# Void's kernels are listed in void-entries.conf, which update-boot-menu
# rewrites on every kernel change (normal kernel first, LTS second).
# Add "internal" to scanfor to also find other systems on this disk (Void's
# kernels then show up twice). Options: /usr/share/refind/refind.conf-sample
timeout 5
scanfor manual,external,optical
default_selection 1
include void-entries.conf
EOF
	done
	cp "$src" "$e/EFI/refind/refind_$a.efi"
	cp "$src" "$e/EFI/BOOT/BOOT${a^^}.EFI"   # firmware fallback path
	efi_entry "Void Linux (rEFInd)" "\\EFI\\refind\\refind_$a.efi" "\\EFI\\BOOT\\BOOT${a^^}.EFI"
	in_target /usr/local/bin/update-boot-menu
}

install_efistub() {
	write_boot_tools "$TARGET"
	echo "Creating one UEFI boot entry per kernel ..."
	in_target /usr/local/bin/update-boot-menu
}

install_uki() {
	write_boot_tools "$TARGET"
	# dracut-uefi offers its own kernel hook as an alternative to the normal
	# initramfs hook. Keep the normal one: update-boot-menu builds the images.
	in_target xbps-alternatives -g initramfs -s dracut || true
	mkdir -p "$TARGET$ESP_MOUNT/EFI/Linux"
	# The images are built in the last step, after the initramfs is regenerated.
	echo "Unified kernel images will be written to $ESP_MOUNT/EFI/Linux in the last step."
}

syslinux_dir() { # directory holding the BIOS files of the syslinux package
	local d
	for d in "$TARGET/usr/lib/syslinux/bios" "$TARGET/usr/lib/syslinux" "$TARGET/usr/share/syslinux"; do
		if [[ -f $d/gptmbr.bin ]]; then
			printf '%s\n' "$d"
			return 0
		fi
	done
	return 1
}

install_syslinux() {
	local d m
	if ! d=$(syslinux_dir); then
		echo "gptmbr.bin was not found in the syslinux package." >&2
		return 1
	fi
	write_boot_tools "$TARGET"
	mkdir -p "$TARGET/boot/syslinux"
	in_target extlinux --install /boot/syslinux
	for m in menu.c32 libutil.c32 libcom32.c32; do
		if [[ -f $d/$m ]]; then cp "$d/$m" "$TARGET/boot/syslinux/$m"; fi
	done
	echo "Writing SYSLINUX's GPT boot code (gptmbr.bin) to $DISK ..."
	dd bs=440 count=1 conv=notrunc if="$d/gptmbr.bin" of="$DISK" status=none
	in_target /usr/local/bin/update-boot-menu
}

install_limine() {
	local efi
	write_limine_tools "$TARGET"
	mkdir -p "$TARGET/boot/limine"
	if [[ $FIRMWARE == uefi ]]; then
		efi=BOOTX64.EFI
		if [[ $EFI_BITS == 32 ]]; then efi=BOOTIA32.EFI; fi
		if [[ ! -f $TARGET/usr/share/limine/$efi ]]; then
			echo "$efi is missing from the limine package." >&2
			return 1
		fi
		mkdir -p "$TARGET/boot/EFI/limine" "$TARGET/boot/EFI/BOOT"
		cp "$TARGET/usr/share/limine/$efi" "$TARGET/boot/EFI/limine/$efi"
		cp "$TARGET/usr/share/limine/$efi" "$TARGET/boot/EFI/BOOT/$efi"   # firmware fallback path
		efi_entry "Void Linux (Limine)" "\\EFI\\limine\\$efi" "\\EFI\\BOOT\\$efi"
	else
		cp "$TARGET/usr/share/limine/limine-bios.sys" "$TARGET/boot/limine/limine-bios.sys"
		in_target limine bios-install "$DISK" "$BIOSBOOT_NUM"
	fi
	in_target /usr/local/bin/update-limine
}

step_bootloader() {
	case $BOOTLOADER in
		grub) install_grub ;;
		limine) install_limine ;;
		systemd-boot) install_systemd_boot ;;
		refind) install_refind ;;
		uki) install_uki ;;
		efistub) install_efistub ;;
		syslinux) install_syslinux ;;
	esac
}

# ---- finish -------------------------------------------------------------------
installed_kernel_series() {
	in_target xbps-query -l | awk '{ print $2 }' |
		sed -nE 's/^(linux[0-9]+\.[0-9]+)-[0-9].*/\1/p' | sort -u
}

verify_boot_menu() {
	local e="$TARGET${ESP_MOUNT:-/boot}" f
	case $BOOTLOADER in
		systemd-boot)
			if ! compgen -G "$e/loader/entries/void-boot-*.conf" >/dev/null; then
				echo "systemd-boot: no loader entries were written" >&2
				return 1
			fi
			f=$(sed -n 's/^default //p' "$e/loader/loader.conf")
			if [[ ! -f $e/loader/entries/$f ]]; then
				echo "systemd-boot: default entry '$f' does not exist" >&2
				return 1
			fi
			[[ -f $e/EFI/BOOT/BOOT$(efi_arch | tr '[:lower:]' '[:upper:]').EFI ]] || warn "systemd-boot: no fallback EFI/BOOT loader"
			echo "OK: systemd-boot, default entry $f"
			;;
		refind)
			if ! grep -q '^menuentry' "$e/EFI/refind/void-entries.conf" 2>/dev/null; then
				echo "rEFInd: void-entries.conf has no entries" >&2
				return 1
			fi
			echo "OK: rEFInd, $(grep -c '^menuentry' "$e/EFI/refind/void-entries.conf") entries"
			;;
		uki)
			if ! compgen -G "$e/EFI/Linux/void-*.efi" >/dev/null; then
				echo "UKI: no unified kernel image in $ESP_MOUNT/EFI/Linux" >&2
				return 1
			fi
			if [[ ! -s $e/EFI/BOOT/BOOT$(efi_arch | tr '[:lower:]' '[:upper:]').EFI ]]; then
				echo "UKI: the fallback EFI/BOOT image is missing" >&2
				return 1
			fi
			echo "OK: unified kernel images: $(cd "$e/EFI/Linux" && echo void-*.efi)"
			;;
		efistub)
			if ! in_target efibootmgr | grep -q 'Void Linux ([0-9]'; then
				echo "EFISTUB: no 'Void Linux (<version>)' UEFI boot entry exists" >&2
				return 1
			fi
			echo "OK: EFISTUB boot entries"
			;;
		syslinux)
			if ! grep -q '^ *LINUX /vmlinuz-' "$TARGET/boot/syslinux/syslinux.cfg" 2>/dev/null; then
				echo "SYSLINUX: syslinux.cfg has no entries" >&2
				return 1
			fi
			if [[ ! -f $TARGET/boot/syslinux/ldlinux.sys ]]; then
				echo "SYSLINUX: extlinux did not install ldlinux.sys" >&2
				return 1
			fi
			echo "OK: /boot/syslinux/syslinux.cfg"
			;;
	esac
}

verify_install() {
	local k ver img listing found=0
	for k in "$TARGET"/boot/vmlinuz-*; do
		[[ -e $k ]] || continue
		found=1
		ver=${k##*/vmlinuz-}
		img="$TARGET/boot/initramfs-$ver.img"
		if [[ ! -s $img ]]; then
			echo "Missing initramfs for kernel $ver" >&2
			return 1
		fi
		if encrypted; then
			listing=$(in_target lsinitrd "/boot/initramfs-$ver.img")
			if ! grep -q 'cryptsetup' <<<"$listing"; then
				echo "initramfs-$ver.img does not contain cryptsetup" >&2
				return 1
			fi
			if grub_unlocks && ! grep -q 'boot/volume.key' <<<"$listing"; then
				echo "initramfs-$ver.img does not contain the LUKS key file" >&2
				return 1
			fi
		fi
		echo "OK: kernel $ver with initramfs"
	done
	if ((found == 0)); then
		echo "No kernel found in /boot" >&2
		return 1
	fi
	case $BOOTLOADER in
		grub)
			if ! grep -q 'vmlinuz' "$TARGET/boot/grub/grub.cfg"; then
				echo "grub.cfg contains no kernel entries" >&2
				return 1
			fi
			if grub_unlocks && ! grep -q 'cryptomount' "$TARGET/boot/grub/grub.cfg"; then
				echo "grub.cfg does not unlock the encrypted disk (cryptomount missing)" >&2
				return 1
			fi
			local def
			def=$(sed -n 's/^  set default="\(gnulinux-[^"]*\)"$/\1/p' "$TARGET/boot/grub/grub.cfg" | head -n 1)
			if [[ -z $def ]]; then
				warn "GRUB: the normal-kernel-first boot order was not written; GRUB boots the newest kernel by default."
			elif ! grep -qF "'$def'" "$TARGET/boot/grub/grub.cfg"; then
				warn "GRUB: default entry $def not found in grub.cfg; GRUB boots the first entry instead."
			fi
			echo "OK: /boot/grub/grub.cfg"
			;;
		limine)
			if ! grep -q 'protocol: linux' "$TARGET/boot/limine/limine.conf"; then
				echo "limine.conf contains no entries" >&2
				return 1
			fi
			echo "OK: /boot/limine/limine.conf"
			;;
		*) verify_boot_menu ;;
	esac
}

step_finalize() {
	local -a kp=()
	local p
	mapfile -t kp < <(installed_kernel_series)
	if ((${#kp[@]} == 0)); then
		echo "No kernel package is installed!" >&2
		return 1
	fi
	echo "Generating initramfs images and boot menu entries for: ${kp[*]}"
	for p in "${kp[@]}"; do
		in_target stdbuf -oL xbps-reconfigure -f "$p"
	done
	case $BOOTLOADER in
		grub) in_target grub-mkconfig -o /boot/grub/grub.cfg ;;
		limine) in_target /usr/local/bin/update-limine ;;
		*) in_target /usr/local/bin/update-boot-menu ;;
	esac
	verify_install
	echo "Boot order (first = default):"
	in_target /usr/local/bin/void-kernel-order | awk '{ printf "    %d. %s%s\n", NR, $1, (NR == 1 ? "  <- default" : ($2 == "lts" ? "  (LTS)" : "")) }' || true
	cp "$LOG" "$TARGET/var/log/void-install.log" 2>/dev/null || true
	# The settings of this install as a preset, to install the same system again.
	if [[ -d $TARGET/root ]]; then
		preset_write "$TARGET/root/void-install.preset" "${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}" 2>/dev/null || true
	fi
	chmod 600 "$TARGET/var/log/void-install.log" 2>/dev/null || true
	sync
}

# =============================================================================
#  Installation driver
# =============================================================================
cleanup_target() {
	sync
	if mountpoint -q "$TARGET" 2>/dev/null; then
		umount -R "$TARGET" 2>/dev/null || umount -Rl "$TARGET" 2>/dev/null || true
	fi
	if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
		local i
		for i in 1 2 3 4 5; do
			cryptsetup close "$CRYPT_NAME" 2>/dev/null && break
			sleep 1
		done
	fi
	INSTALL_STARTED=0
}

# Run one installation step in a subshell with strict error handling, showing
# its output live in a dialog progress box and appending it to $LOG.
# Must be called as a plain command (never inside if/while/&&/||), or bash
# disables "set -e" inside the step.
run_step() { # run_step "title" function
	local title=$1 fn=$2 rows=24 cols=80 size
	size=$(stty size </dev/tty 2>/dev/null) || size=""
	if [[ $size =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
		rows=${BASH_REMATCH[1]}
		cols=${BASH_REMATCH[2]}
	fi
	((rows >= 12)) || rows=24
	((cols >= 50)) || cols=80
	printf '\n===== %s =====\n' "$title" >>"$LOG"
	(
		set -Eeuo pipefail
		shopt -s inherit_errexit
		trap 'echo "ERROR: \"$BASH_COMMAND\" failed with exit status $? (line $LINENO)" >&2' ERR
		"$fn"
	) </dev/null 2>&1 | mask_secrets | tee -a "$LOG" |
		{
			dialog --backtitle "$BACKTITLE" --title " $title " --progressbox $((rows - 4)) $((cols - 4)) >/dev/tty 2>&1
			cat >/dev/null
		}
	return "${PIPESTATUS[0]}"
}

log_settings() {
	{
		echo "void-install.sh $SCRIPT_VERSION - $(date)"
		echo "firmware=$FIRMWARE efi_bits=$EFI_BITS disk=$DISK fs=$FS enc=$ENC bootloader=$BOOTLOADER grub_boot=$GRUB_BOOT"
		echo "swap=$SWAP swap_size=$SWAP_SIZE kernels=${KERNELS// /,} libc=$LIBC mirror=$MIRROR"
		echo "hostname=$HOST_NAME keymap=$KEYMAP locale=$LOCALE timezone=$TIMEZONE user=$USER_NAME"
		echo "net=$NET desktop=$DESKTOP dm=$(desktop_dm) dotfiles=$DOTS extras=$EXTRA_PKGS"
		echo "gpu=$GPU (effective: $(gpu_list)) apps=$APPS gaming=$GAMING peripherals=$PERIPH xsrc=$XSRC_PKGS xsrc_setup=$XSRC_SETUP"
		local u
		for u in "${USERS[@]}"; do echo "user=$u sudo=${U_SUDO[$u]}"; done
		echo "bootstrap: progs=$BS_PROGS dotfiles=$BS_DOTFILES branch=$BS_BRANCH shell=$BS_SHELL power=$BS_POWER"
		echo "partitions: ${ALL_PARTS[*]} (esp=$ESP_PART#$ESP_NUM biosboot=$BIOSBOOT_PART#$BIOSBOOT_NUM boot=$BOOT_PART#$BOOT_NUM root=$ROOT_PART#$ROOT_NUM)"
	} | mask_secrets >>"$LOG"
}

install_failed() {
	local title=$1 tailf c
	tailf=$(mktemp)
	tail -n 80 "$LOG" >"$tailf"
	dialog --backtitle "$BACKTITLE" --title " Failed: $title " --exit-label "Continue" \
		--textbox "$tailf" 0 0 >/dev/tty 2>&1 || true
	rm -f "$tailf"
	while true; do
		c=$(ui --title " Installation failed " --cancel-label "Exit" --menu \
			"The installation stopped during:\n  $title\n\nFull log: $LOG" 15 74 3 \
			shell "Open a shell to investigate ('exit' comes back)" \
			menu "Unmount, back to the main menu (settings are kept)" \
			exit "Unmount everything and exit") || c="exit"
		case $c in
			shell)
				clear
				echo "The new system is mounted at $TARGET. Log: $LOG. Type 'exit' when done."
				run_shell bash -i
				;;
			menu)
				cleanup_target
				return 0
				;;
			*)
				cleanup_target
				clear
				echo "Installation failed during: $title"
				echo "See $LOG for details."
				exit 1
				;;
		esac
	done
}

install_done() {
	local c warnings=""
	if [[ -s $WARN_FILE ]]; then
		warnings="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"
	fi
	while true; do
		c=$(ui --title " Installation complete " --cancel-label "Exit" --menu \
			"Void Linux is installed on $DISK.\nRemove the installation medium before booting the new system.${warnings}" 0 0 4 \
			reboot "Unmount and reboot" \
			poweroff "Unmount and power off" \
			chroot "Open a shell inside the new system" \
			exit "Unmount and return to the live system") || c="exit"
		case $c in
			chroot)
				clear
				echo "You are inside the new system. Type 'exit' to return to the installer."
				run_shell chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
					PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash -l
				;;
			reboot) cleanup_target; clear; reboot; exit 0 ;;
			poweroff) cleanup_target; clear; poweroff; exit 0 ;;
			*)
				cleanup_target
				clear
				echo "Done. The installation log was saved to /var/log/void-install.log on the new system,"
				echo "and these settings as a preset to /root/void-install.preset (load it with --preset)."
				exit 0
				;;
		esac
	done
}

do_install() {
	local -a titles=() funcs=()
	local i n rc

	titles+=("Preparing the live system") funcs+=(step_prepare_live)
	titles+=("Partitioning $DISK") funcs+=(step_partition)
	if encrypted; then titles+=("Setting up $(enc_desc) encryption") funcs+=(step_encrypt); fi
	titles+=("Creating filesystems") funcs+=(step_filesystems)
	titles+=("Installing the base system") funcs+=(step_bootstrap)
	titles+=("Configuring the system") funcs+=(step_configure)
	titles+=("Installing packages") funcs+=(step_packages)
	if [[ -n $XSRC_PKGS || $XSRC_SETUP == 1 ]]; then titles+=("Building packages with xbps-src") funcs+=(step_xbps_src); fi
	if bootstrap_wanted; then titles+=("Bootstrap: programs, dotfiles, shell") funcs+=(step_bootstrap_user); fi
	titles+=("Installing the boot loader ($BOOTLOADER)") funcs+=(step_bootloader)
	titles+=("Generating initramfs and boot menu") funcs+=(step_finalize)

	: >"$WARN_FILE"
	log_settings
	INSTALL_STARTED=1
	n=${#funcs[@]}
	for ((i = 0; i < n; i++)); do
		# Do NOT call run_step inside "if"/"||": bash would then silently disable
		# "set -e" inside the step and a failing command would go unnoticed.
		run_step "[$((i + 1))/$n] ${titles[i]}" "${funcs[i]}"
		rc=$?
		if ((rc != 0)); then
			install_failed "${titles[i]}"
			return 1
		fi
	done
	install_done
}

# =============================================================================
#  Presets: every setting except the disk, passwords and users
# =============================================================================
# A preset is a text file:
#     # void-install preset v1
#     # name: my-desktop
#     FS=btrfs
#     DESKTOP=xfce sway
# It is never run or sourced. Only the keys in PRESET_KEYS are accepted, each
# value must pass preset_check, and anything else rejects the whole file.
# Its ID is <name>@<first 16 hex digits of the SHA-256 of its settings>; loading
# "<file, link or name>@<ID digits>" refuses a preset whose settings differ.
PRESET_KEYS=(FS ENC GRUB_BOOT BOOTLOADER SWAP SWAP_SIZE KERNELS LIBC MIRROR HOST_NAME KEYMAP
	LOCALE TIMEZONE NET DESKTOP DM DOTS GPU APPS GAMING PERIPH EXTRA_PKGS XSRC_PKGS XSRC_SETUP
	BS_PROGS BS_DOTFILES BS_BRANCH BS_SHELL BS_POWER)
PRESET_REPO=${VOID_INSTALL_PRESETS:-https://raw.githubusercontent.com/aranmi-git/void-install/main/presets}
PRESET_MAX_BYTES=65536
PRESET_ID=""      # ID of the loaded preset (shown in the main menu)
PRESET_LABEL=""   # its name
PRESET_ERR=""     # why the last load failed
PRESET_SKIPPED="" # keys left out by preset_write
MENU_JUMP=""      # main menu item to highlight next
declare -A PRESET_NEW=() PRESET_OLD=()

one_of() { # one_of <value> <option>...
	local v=$1 o
	shift
	for o in "$@"; do [[ $v == "$o" ]] && return 0; done
	return 1
}

all_of() { # all_of "<words>" <option>... : every word is an option, none twice
	local w seen=" "
	[[ $1 =~ ^[A-Za-z0-9._+\ -]*$ ]] || return 1 # no glob characters before splitting
	for w in $1; do
		one_of "$w" "${@:2}" || return 1
		[[ $seen != *" $w "* ]] || return 1
		seen+="$w "
	done
}

pkg_words_ok() { # package names: each starts with a letter or digit (no options)
	local w
	[[ $1 =~ ^[A-Za-z0-9._+\ -]*$ ]] || return 1
	for w in $1; do [[ $w =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 1; done
}

# Is <value> allowed for <key> in a preset?
preset_check() { # preset_check <key> <value>
	local k=$1 v=$2 w seen=" "
	local re_host='[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?'
	local re_path='(/[A-Za-z0-9._~%+=-]*)*'
	case $k in
		FS) one_of "$v" ext4 btrfs ;;
		ENC) one_of "$v" none luks1 luks2 ;;
		GRUB_BOOT) one_of "$v" encrypted separate ;;
		BOOTLOADER) one_of "$v" grub limine systemd-boot refind uki efistub syslinux ;;
		SWAP) one_of "$v" none zram file ;;
		SWAP_SIZE) [[ $v =~ ^[1-9][0-9]{0,2}$ ]] && ((v <= 128)) ;;
		KERNELS)
			[[ -n $v && $v =~ ^[a-z0-9.\ -]+$ ]] || return 1
			for w in $v; do
				[[ $w =~ ^linux([0-9]+\.[0-9]+|-lts|-mainline)?$ && $seen != *" $w "* ]] || return 1
				seen+="$w "
			done
			;;
		LIBC) one_of "$v" glibc musl ;;
		MIRROR) [[ $v =~ ^https?://${re_host}${re_path}$ && $v != */current && $v != */current/ ]] ;;
		HOST_NAME) [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] ;;
		KEYMAP) [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$ ]] ;;
		LOCALE) [[ $v =~ ^[A-Za-z_]+\.UTF-8(@[A-Za-z]+)?$ ]] ;;
		TIMEZONE)
			[[ $v == UTC ]] && return 0
			[[ $v =~ ^[A-Z][A-Za-z_]+(/[A-Za-z0-9_+-]+){1,2}$ ]] || return 1
			[[ ! -d /usr/share/zoneinfo || -f /usr/share/zoneinfo/$v ]]
			;;
		NET) one_of "$v" nm dhcpcd none ;;
		DESKTOP)
			[[ $v == none ]] && return 0
			[[ -n $v ]] || return 1
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(desktop_table | cut -d'|' -f1)
			;;
		DM) one_of "$v" auto lightdm sddm gdm greetd none ;;
		DOTS)
			# shellcheck disable=SC2046
			all_of "$v" $(dots_table | cut -d'|' -f1)
			;;
		GPU)
			one_of "$v" auto none && return 0
			[[ -n $v ]] && all_of "$v" intel amd nouveau nvidia nvidia580 nvidia470 nvidia390 vm
			;;
		APPS)
			all_of "$v" firefox chromium thunderbird vlc mpv libreoffice gimp obs keepassxc \
				telegram-desktop discord flatpak git htop neovim
			;;
		GAMING) all_of "$v" multilib steam wine winetricks lutris gamemode ;;
		PERIPH)
			# shellcheck disable=SC2046  # ids are single words
			all_of "$v" $(periph_ids) && ! { has "$v" openlinkhub && has "$v" ckb-next; }
			;;
		EXTRA_PKGS | XSRC_PKGS) pkg_words_ok "$v" ;;
		XSRC_SETUP | BS_POWER) one_of "$v" 0 1 ;;
		BS_PROGS) [[ -z $v || $v =~ ^https://${re_host}${re_path}$ ]] ;;
		BS_DOTFILES)
			[[ -z $v || $v =~ ^https://${re_host}${re_path}$ ||
				$v =~ ^git@[A-Za-z0-9.-]+:[A-Za-z0-9._~-]+(/[A-Za-z0-9._~-]+)*$ ]]
			;;
		BS_BRANCH) [[ -z $v || $v =~ ^[A-Za-z0-9._][A-Za-z0-9._/-]{0,99}$ ]] ;;
		BS_SHELL) one_of "$v" bash zsh fish ;;
		*) return 1 ;;
	esac
}

preset_norm() { # one value with runs of blanks collapsed
	local -a w=()
	read -r -a w <<<"$1" || true
	printf '%s' "${w[*]}"
}

# The settings in a fixed order; the ID is computed from exactly this text.
preset_canon() {
	local k
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf '%s=%s\n' "$k" "${PRESET_NEW[$k]}"; fi
	done
}

preset_hash() { preset_canon | sha256sum | cut -c1-16; }
preset_hash_full() { preset_canon | sha256sum | cut -d' ' -f1; }

valid_preset_name() { [[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,39}$ ]]; }

# Read a preset file into PRESET_NEW. Nothing is applied. 1 + PRESET_ERR on error.
preset_parse() { # preset_parse <file>
	local f=$1 line t k v n=0 bytes
	PRESET_NEW=() PRESET_ERR="" PRESET_LABEL=""
	bytes=$(wc -c <"$f" 2>/dev/null) || bytes=-1
	if ((bytes < 0 || bytes > PRESET_MAX_BYTES)); then
		PRESET_ERR="The file is missing or larger than $((PRESET_MAX_BYTES / 1024)) KiB."
		return 1
	fi
	if LC_ALL=C grep -q $'[\x01-\x08\x0b\x0e-\x1f\x7f]' "$f" || [[ $(tr -d '\000' <"$f" | wc -c) != "$bytes" ]]; then
		PRESET_ERR="The file contains control characters; it is not a preset."
		return 1
	fi
	# A preset never holds secrets. Refuse a file that looks like it does (in a
	# setting or a comment), so a password is not shared by accident.
	t=$(grep -niE '(^|[^a-z])(pass(word|wd|phrase)?|pw|secret|token|api[_-]?key|private[_-]?key|luks[_-]?key)[a-z_]*[[:space:]]*[=:]' "$f" | head -n 1 | cut -d: -f1)
	if [[ -n $t ]]; then
		PRESET_ERR="Line $t looks like a password or other secret. A preset never holds passwords (root, users, encryption) or keys; remove that line."
		return 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		if ((n == 1)); then
			if [[ ! $line =~ ^#\ void-install\ preset\ v1[[:space:]]*$ ]]; then
				PRESET_ERR="The first line must be: # void-install preset v1"
				return 1
			fi
			continue
		fi
		t=$(trim "$line")
		[[ -z $t ]] && continue
		if [[ $t == \#* ]]; then
			if [[ $t =~ ^#\ *name:\ *([a-z0-9][a-z0-9._-]{0,39})$ ]]; then PRESET_LABEL=${BASH_REMATCH[1]}; fi
			continue
		fi
		if [[ ! $t =~ ^([A-Z_]+)=(.*)$ ]]; then
			PRESET_ERR="Line $n is not KEY=value."
			return 1
		fi
		k=${BASH_REMATCH[1]}
		v=$(preset_norm "${BASH_REMATCH[2]}")
		if ! one_of "$k" "${PRESET_KEYS[@]}"; then
			case $k in
				DISK | ROOT_PASS | LUKS_PASS | USER_NAME | USERS | U_*) PRESET_ERR="Line $n: $k must not be in a preset; the installer always asks for it." ;;
				*) PRESET_ERR="Line $n: unknown setting $k." ;;
			esac
			return 1
		fi
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then
			PRESET_ERR="Line $n: $k is set twice."
			return 1
		fi
		if ! preset_check "$k" "$v"; then
			v=${v//\\/}
			PRESET_ERR="Line $n: invalid value for $k: ${v:0:60}"
			return 1
		fi
		PRESET_NEW[$k]=$v
	done <"$f"
	if ((n == 0)); then
		PRESET_ERR="The file is empty."
		return 1
	fi
	if ((${#PRESET_NEW[@]} == 0)); then
		PRESET_ERR="The file holds no settings."
		return 1
	fi
	return 0
}

# Get a preset to <dest>: a local file, an https:// link, or a name from PRESET_REPO.
preset_fetch() { # preset_fetch <spec> <dest>; sets PRESET_SRC
	local spec=$1 dest=$2 url
	PRESET_SRC=""
	if [[ $spec == https://* ]]; then
		url=$spec
	elif [[ $spec =~ ^[a-z][a-z0-9+.-]*:// ]]; then
		PRESET_ERR="Only https:// links are accepted for presets."
		return 1
	elif [[ -e $spec || $spec == */* ]]; then
		if [[ ! -f $spec || ! -r $spec ]]; then
			PRESET_ERR="File not found: $spec"
			return 1
		fi
		cp -- "$spec" "$dest" || { PRESET_ERR="Cannot read $spec"; return 1; }
		PRESET_SRC=$(readlink -f -- "$spec")
		return 0
	elif valid_preset_name "$spec"; then
		if [[ $PRESET_REPO != https://* ]]; then
			PRESET_ERR="VOID_INSTALL_PRESETS must be an https:// address."
			return 1
		fi
		url="${PRESET_REPO%/}/$spec.preset"
	else
		PRESET_ERR="Not a file, an https:// link or a preset name: $spec"
		return 1
	fi
	if [[ $url =~ ^https://[^/]*@ || $url =~ [[:space:]] ]]; then
		PRESET_ERR="Links with a user name, token or spaces are not accepted."
		return 1
	fi
	PRESET_SRC=$url
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --proto '=https' --proto-redir '=https' --max-time 60 \
			--max-filesize "$PRESET_MAX_BYTES" -o "$dest" -- "$url" >/dev/null 2>&1 ||
			{ PRESET_ERR="Could not download $url"; return 1; }
	elif command -v xbps-fetch >/dev/null 2>&1; then
		timeout 60 xbps-fetch -o "$dest" "$url" >/dev/null 2>&1 ||
			{ PRESET_ERR="Could not download $url"; return 1; }
	else
		PRESET_ERR="Neither curl nor xbps-fetch is available to download $url"
		return 1
	fi
	return 0
}

preset_backup() {
	local k
	PRESET_OLD=()
	for k in "${PRESET_KEYS[@]}"; do PRESET_OLD[$k]=${!k}; done
}

preset_restore() {
	local k
	for k in "${PRESET_KEYS[@]}"; do printf -v "$k" '%s' "${PRESET_OLD[$k]}"; done
}

# Apply PRESET_NEW; settings it does not name are reset to the defaults.
preset_apply() {
	local k
	FS=ext4 ENC=luks2 BOOTLOADER=grub GRUB_BOOT=encrypted SWAP=zram SWAP_SIZE=4
	KERNELS="linux linux-lts" LIBC=glibc MIRROR=$DEFAULT_MIRROR HOST_NAME=void KEYMAP=us
	LOCALE=en_US.UTF-8 TIMEZONE=UTC NET=nm DESKTOP=none DM=auto DOTS="" GPU=auto APPS=""
	GAMING="" PERIPH="" EXTRA_PKGS="" XSRC_PKGS="" XSRC_SETUP=0 BS_PROGS="" BS_DOTFILES="" BS_BRANCH=""
	BS_SHELL=bash BS_POWER=0
	for k in "${PRESET_KEYS[@]}"; do
		if [[ -n ${PRESET_NEW[$k]+x} ]]; then printf -v "$k" '%s' "${PRESET_NEW[$k]}"; fi
	done
	prune_dots
}

# Problems of the applied preset on this computer (empty: none).
preset_notes() {
	if uefi_only && [[ $FIRMWARE != uefi || $EFI_BITS != 64 ]]; then
		printf '\\Z1%s needs 64-bit UEFI; this computer started with %s. Choose another boot loader.\\Zn\\n' "$(lbl_boot)" "${FIRMWARE^^}"
	fi
	if bios_only && [[ $FIRMWARE != bios ]]; then
		printf '\\Z1%s is for BIOS computers; this one uses UEFI. Choose another boot loader.\\Zn\\n' "$(lbl_boot)"
	fi
	if [[ -n $PRUNED ]]; then
		printf 'Dotfile presets dropped (their desktop is not in the preset): %s\\n' "$PRUNED"
	fi
}

preset_summary() { # preset_summary <id> <verified: 0/1/2> -> dialog text
	local id=$1 ver=$2 ext=""
	case $ver in
		1) printf 'Preset   \\Zb%s\\Zn  \\Z2(fingerprint verified)\\Zn\\n' "$id" ;;
		*) printf 'Preset   \\Zb%s\\Zn\\n         \\Z3Not verified: load it as %s to check it next time.\\Zn\\n' "$id" "$id" ;;
	esac
	printf 'From     %s\n\n' "$(printf '%s' "$PRESET_SRC" | mask_secrets)"
	printf 'Disk     %s, encryption: %s\n' "$FS" "$(enc_desc)"
	printf 'Boot     %s; swap: %s\n' "$(lbl_boot)" "$(lbl_swap)"
	printf 'Kernels  %s\n' "$(lbl_kernels)"
	printf 'System   %s, %s\n' "$LIBC" "$MIRROR"
	printf 'Host     %s, keymap %s, %s, %s\n' "$HOST_NAME" "$KEYMAP" "$(lbl_locale)" "$TIMEZONE"
	printf 'Network  %s\n' "$(lbl_net)"
	printf 'Desktop  %s; login: %s\n' "$(lbl_desktop)" "$(lbl_dm)"
	printf 'Dotfiles %s\n' "$(lbl_dots)"
	printf 'GPU      %s\n' "$(lbl_gpu)"
	printf 'Apps     %s\n' "$(lbl_list "$APPS")"
	printf 'Gaming   %s\n' "$(lbl_list "$GAMING")"
	printf 'Devices  %s\n' "$(lbl_periph)"
	printf 'Packages %s; xbps-src: %s\n' "${EXTRA_PKGS:-(none)}" "$(lbl_xsrc)"
	if [[ -n $BS_PROGS ]]; then ext+="  programs list: $BS_PROGS\\n"; fi
	if has "$PERIPH" openlogi; then ext+="  OpenLogi (Logitech): github.com/AprilNEA/OpenLogi, pinned release\\n"; fi
	if has "$PERIPH" openlinkhub; then ext+="  OpenLinkHub (Corsair): github.com/jurkovic-nikola/OpenLinkHub, pinned release\\n"; fi

	if [[ -n $BS_DOTFILES ]]; then ext+="  dotfiles: $BS_DOTFILES${BS_BRANCH:+ ($BS_BRANCH)}\\n"; fi
	if [[ -n $ext ]]; then
		printf '\n\\Z3\\ZbThis preset installs programs and files from outside Void:\\Zn\n%s\\Z3Load it only if you trust these sources.\\Zn\n' "$ext"
	fi
	printf '\nNot in a preset (asked next): disk, root password, users%s.\n' "$(encrypted && printf ', encryption passphrase')"
}

# Fetch, check, show and (if confirmed) apply a preset. 0 = applied.
preset_load() { # preset_load <file | https link | name>[@ID]
	local spec expect="" tmp full id ver=0 notes
	spec=$(trim "$1")
	if [[ $spec =~ ^(.+)@([0-9A-Fa-f]{16,64})$ ]]; then
		spec=${BASH_REMATCH[1]}
		expect=${BASH_REMATCH[2],,}
	fi
	tmp=$(mktemp /tmp/void-preset.XXXXXX) || return 1
	if ! preset_fetch "$spec" "$tmp" || ! preset_parse "$tmp"; then
		rm -f -- "$tmp"
		msg "This preset was not loaded:\n\n$(printf '%s' "$PRESET_ERR" | mask_secrets)\n\nNo setting was changed." "Preset" 12 74
		return 1
	fi
	rm -f -- "$tmp"
	full=$(preset_hash_full)
	if [[ -n $expect ]]; then
		if [[ ${full:0:${#expect}} != "$expect" ]]; then
			msg "\Z1\ZbThe preset does not match its ID.\Zn\n\nExpected: $expect\nFound:    ${full:0:${#expect}}\n\nIt was changed after the ID was made, or it is a different preset. It was not loaded and no setting was changed." "Preset: wrong fingerprint" 13 74
			return 1
		fi
		ver=1
	fi
	if [[ -z $PRESET_LABEL ]]; then
		PRESET_LABEL=$(basename -- "$spec" .preset)
		valid_preset_name "$PRESET_LABEL" || PRESET_LABEL=preset
	fi
	id="$PRESET_LABEL@${full:0:16}"
	preset_backup
	preset_apply
	notes=$(preset_notes)
	if ! dialog --backtitle "$BACKTITLE" --colors --cr-wrap --no-collapse --title " Load this preset? " --scrollbar \
		--yes-label "Load" --no-label "Cancel" --yesno "$(preset_summary "$id" "$ver")${notes:+\n\n$notes}" 0 0 >/dev/tty 2>&1; then
		preset_restore
		prune_dots
		return 1
	fi
	PRESET_ID=$id
	printf 'Loaded preset %s from %s (verified: %s)\n' "$id" "$PRESET_SRC" "$ver" | mask_secrets >>"$LOG" 2>/dev/null || true
	if [[ -n $notes && $notes == *Z1* ]]; then MENU_JUMP=Bootloader; else MENU_JUMP=Install; fi
	return 0
}

# Write the current settings as a preset. Values a preset cannot hold
# (a local programs list, a link with credentials) are left out: PRESET_SKIPPED.
preset_write() { # preset_write <file> <name>
	local f=$1 name=$2 k v
	PRESET_NEW=() PRESET_SKIPPED=""
	for k in "${PRESET_KEYS[@]}"; do
		v=$(preset_norm "${!k}")
		if preset_check "$k" "$v"; then PRESET_NEW[$k]=$v; else PRESET_SKIPPED+="${PRESET_SKIPPED:+ }$k"; fi
	done
	(
		umask 022
		{
			echo "# void-install preset v1"
			echo "# name: $name"
			echo "# id: $name@$(preset_hash)"
			echo "# Made by void-install.sh $SCRIPT_VERSION on $(date +%F)."
			echo "# Load it with:  bash void-install.sh --preset <this file, an https link or a name>"
			echo "# Disk, passwords and users are never stored here; the installer asks for them."
			preset_canon
		} >"$f"
	)
}

# Ask for what a preset never contains, then show the main menu.
preset_quick() {
	msg "Preset loaded: \Zb$PRESET_ID\Zn\n\nNow the parts a preset never contains: the disk, the root password, the users$(encrypted && printf ' and the encryption passphrase').\n\nAfterwards the main menu opens with \ZbInstall\Zn selected. Every setting can still be changed there." "Preset" 13 70
	menu_disk || true
	if [[ -z $ROOT_PASS ]]; then menu_rootpass || true; fi
	if ((${#USERS[@]} == 0)); then user_dialog || true; fi
	if encrypted && [[ -z $LUKS_PASS ]]; then ask_luks_pass || true; fi
	return 0
}

lbl_preset() {
	if [[ -n $PRESET_ID ]]; then printf '%s' "$PRESET_ID"; else printf '(none) - load or save all settings'; fi
}

menu_preset() {
	local c v name f def
	c=$(ui --title " Preset " --menu \
		"A preset holds every setting except the disk, the passwords and the users, so the same system can be installed again with a few answers. Its ID ends in a fingerprint of the settings." \
		13 78 3 \
		load "Load a preset: file, https:// link or name" \
		save "Save the current settings as a preset" \
		id "Show the ID of the current settings") || return 1
	case $c in
		load)
			v=$(ui --title " Load a preset " --inputbox \
				"Enter one of:\n  a file:   /mnt/usb/desktop.preset\n  a link:   https://example.org/desktop.preset\n  a name:   xfce-desktop  (from the presets folder of the repository)\n\nAdd @ and the ID's digits to verify it:  xfce-desktop@1a2b3c4d5e6f7a8b" \
				15 78) || return 1
			[[ -n $(trim "$v") ]] || return 1
			preset_load "$v" || return 1
			preset_quick
			;;
		save)
			def=${PRESET_LABEL:-$(printf '%s' "${HOST_NAME,,}" | tr -c 'a-z0-9._-' '-')}
			valid_preset_name "$def" || def=my-preset
			name=$(ui --title " Save a preset " --inputbox "Name (lowercase letters, digits, '.', '_', '-'):" 9 64 "$def") || return 1
			if ! valid_preset_name "$name"; then
				msg "Use 1-40 lowercase letters, digits, '.', '_' or '-', starting with a letter or digit." "Preset"
				return 1
			fi
			f=$(ui --title " Save a preset " --inputbox "Save to (a USB stick keeps it; /root is lost when the live system shuts down):" 9 78 "/root/$name.preset") || return 1
			f=$(trim "$f")
			if [[ -z $f || -d $f ]]; then msg "Enter a file name, not a folder." "Preset"; return 1; fi
			if [[ -e $f ]] && ! yesno "$f exists.\n\nReplace it?" "Preset" 1; then return 1; fi
			if ! preset_write "$f" "$name" 2>/dev/null; then
				msg "Cannot write $f" "Preset"
				return 1
			fi
			PRESET_LABEL=$name PRESET_ID="$name@$(preset_hash)"
			msg "Saved: $f\n\nID: \Zb$PRESET_ID\Zn\n\nInstall the same system elsewhere with:\n  bash void-install.sh --preset $f@${PRESET_ID#*@}\n\nOr add the file to the presets/ folder of the repository as $name.preset and use:\n  bash void-install.sh --preset $PRESET_ID${PRESET_SKIPPED:+\n\n\Z3Left out (a preset cannot hold them): $PRESET_SKIPPED\Zn}" "Preset saved" 19 78
			;;
		id)
			preset_write /dev/null "${PRESET_LABEL:-preset}"
			msg "ID of the current settings:\n\n  \Zb${PRESET_LABEL:-preset}@$(preset_hash)\Zn\n\nIt changes whenever a setting changes. The disk, passwords and users are not part of it.${PRESET_SKIPPED:+\n\n\Z3Not part of a preset: $PRESET_SKIPPED\Zn}" "Preset ID" 13 74
			;;
	esac
	return 0
}

# =============================================================================
#  Main menu
# =============================================================================
MENU_ORDER=(Preset Disk Filesystem Encryption Bootloader Swap Kernel C-library Mirror Hostname
	Keyboard Locale Timezone Root-password Users Network Desktop Login Dotfiles GPU Apps Gaming Peripherals Packages xbps-src Bootstrap Install)

next_item() {
	local i
	for i in "${!MENU_ORDER[@]}"; do
		if [[ ${MENU_ORDER[i]} == "$1" ]]; then
			echo "${MENU_ORDER[i + 1]:-Install}"
			return 0
		fi
	done
	echo Install
}

main_menu() {
	local choice next=${1:-Disk} fw ok
	fw=${FIRMWARE^^}
	[[ $FIRMWARE == uefi ]] && fw+=" ${EFI_BITS}-bit"
	while true; do
		choice=$(ui --title " Void Linux installation " --default-item "$next" --cancel-label "Exit" \
			--menu "Set the options, then choose \ZbInstall\Zn. Firmware: \Zb$fw\Zn" 0 0 0 \
			Preset "$(lbl_preset)" \
			Disk "$(lbl_disk)" \
			Filesystem "$FS" \
			Encryption "$(lbl_enc)" \
			Bootloader "$(lbl_boot)" \
			Swap "$(lbl_swap)" \
			Kernel "$(lbl_kernels)" \
			C-library "$LIBC" \
			Mirror "$MIRROR" \
			Hostname "$HOST_NAME" \
			Keyboard "$KEYMAP" \
			Locale "$(lbl_locale)" \
			Timezone "$TIMEZONE" \
			Root-password "$(lbl_set "$ROOT_PASS")" \
			Users "$(lbl_user)" \
			Network "$(lbl_net)" \
			Desktop "$(lbl_desktop)" \
			Login "$(lbl_dm)" \
			Dotfiles "$(lbl_dots)" \
			GPU "$(lbl_gpu)" \
			Apps "$(lbl_list "$APPS")" \
			Gaming "$(lbl_list "$GAMING")" \
			Peripherals "$(lbl_periph)" \
			Packages "${EXTRA_PKGS:-(none)}" \
			xbps-src "$(lbl_xsrc)" \
			Bootstrap "$(lbl_bootstrap)" \
			Install "\Zb>>> Start the installation\Zn")
		ok=$?
		if ((ok != 0)); then
			if yesno "Exit the installer? Nothing has been written to disk." "Exit" 1; then
				clear
				exit 0
			fi
			continue
		fi
		ok=0
		case $choice in
			Preset) menu_preset || ok=1 ;;
			Disk) menu_disk || ok=1 ;;
			Filesystem) menu_fs || ok=1 ;;
			Encryption) menu_enc || ok=1 ;;
			Bootloader) menu_bootloader || ok=1 ;;
			Swap) menu_swap || ok=1 ;;
			Kernel) menu_kernel || ok=1 ;;
			C-library) menu_libc || ok=1 ;;
			Mirror) menu_mirror || ok=1 ;;
			Hostname) menu_hostname || ok=1 ;;
			Keyboard) menu_keymap || ok=1 ;;
			Locale) menu_locale || ok=1 ;;
			Timezone) menu_timezone || ok=1 ;;
			Root-password) menu_rootpass || ok=1 ;;
			Users) menu_user || ok=1 ;;
			Network) menu_network || ok=1 ;;
			Desktop) menu_desktop || ok=1 ;;
			Login) menu_dm || ok=1 ;;
			Dotfiles) menu_dotfiles || ok=1 ;;
			GPU) menu_gpu || ok=1 ;;
			Apps) menu_apps || ok=1 ;;
			Gaming) menu_gaming || ok=1 ;;
			Peripherals) menu_periph || ok=1 ;;
			Packages) menu_extras || ok=1 ;;
			xbps-src) menu_xsrc || ok=1 ;;
			Bootstrap) menu_bootstrap || ok=1 ;;
			Install)
				if validate && confirm_install; then
					do_install
				fi
				ok=1
				;;
		esac
		if ((ok == 0)); then next=$(next_item "$choice"); else next=$choice; fi
		if [[ -n $MENU_JUMP ]]; then
			next=$MENU_JUMP
			MENU_JUMP=""
		fi
	done
}

usage() {
	cat <<EOF
void-install.sh $SCRIPT_VERSION - menu-driven Void Linux installer

Run as root from an official Void Linux live ISO (x86_64) with internet access:
    bash void-install.sh

Install from a preset (asks only for the disk, passwords and users):
    bash void-install.sh --preset xfce-desktop
    bash void-install.sh --preset /mnt/usb/my.preset@1a2b3c4d5e6f7a8b

LARBS-style post-install on an ALREADY INSTALLED Void system (no disk changes):
    bash void-install.sh --bootstrap

Options:
    -p, --preset P   load a preset: a file, an https:// link, or a name from
                     $PRESET_REPO
                     Add @ID (16+ hex digits) to refuse a changed preset.
    -b, --bootstrap  only create/update a user and run the bootstrap
    -h, --help       show this help
    -V, --version    show the version
EOF
}

# ---- --bootstrap: LARBS-like flow on a running system --------------------------------
bootstrap_main() {
	local u n p lvl c rc
	[[ $EUID -eq 0 ]] || die "Run this as root."
	command -v xbps-install >/dev/null 2>&1 || die "This mode needs Void Linux (xbps-install not found)."
	[[ -t 0 && -t 1 ]] || die "Run this from an interactive terminal."
	if [[ -d /run/initramfs/live ]]; then
		die "This looks like the live ISO. --bootstrap is for an installed system; run the installer without options instead."
	fi
	: >"$LOG" || die "Cannot write $LOG"
	: >"$WARN_FILE"
	STANDALONE=1
	TARGET=/
	BACKTITLE="Void Linux bootstrap ${SCRIPT_VERSION}"
	ensure_dialog
	ensure_network
	MIRROR=$(sed -n 's/^repository=\(.*\)\/current.*/\1/p' /etc/xbps.d/*.conf /usr/share/xbps.d/00-repository-main.conf 2>/dev/null | head -n1)
	MIRROR=${MIRROR:-https://repo-default.voidlinux.org}

	msg "Welcome!\n\nThis sets up a user and installs your programs list and dotfiles, LARBS-style, on this Void system. The disk is not changed.\n\nLog: $LOG" "Welcome" 14 70
	while true; do
		u=$(ui --title " User " --inputbox "Login name of the user to create or update:" 9 64 "${USERS[0]:-}") || { clear; exit 0; }
		valid_login "$u" 1 && break
	done
	if id "$u" >/dev/null 2>&1; then
		yesno "The user '$u' already exists. Its files stay; its password will be changed, it is added to the groups below, and the dotfiles may overwrite files in its home.\n\nContinue?" "Existing user" 1 || { clear; exit 0; }
	fi
	n=$(ui --title " User $u " --inputbox "Full name (optional):" 9 64) || { clear; exit 0; }
	[[ $n != *:* ]] || die "The full name must not contain ':'."
	p=$(ask_password "Password for $u" "the password for $u") || { clear; exit 0; }
	U_SUDO[$u]=sudo
	lvl=$(menu_sudo_level "$u") || { clear; exit 0; }
	USERS=("$u")
	U_FULL[$u]=$n U_PASS[$u]=$p U_SUDO[$u]=$lvl
	sync_primary
	menu_bootstrap

	c="User:       $u ($(sudo_word "$u"))\nPrograms:   ${BS_PROGS:-(none)}\nPresets:    ${DOTS:-(none)}\nDotfiles:   ${BS_DOTFILES:-(none)}${BS_BRANCH:+ ($BS_BRANCH)}\nShell:      $BS_SHELL\nPower cmds: $([[ $BS_POWER == 1 ]] && echo 'without password' || echo 'normal')"
	yesno "$c\n\nStart?" "Let's go" 0 15 70 || { clear; exit 0; }

	run_step "[1/2] Setting up user $u" setup_users
	rc=$?
	if ((rc == 0)); then
		run_step "[2/2] Bootstrap: programs, dotfiles, shell" step_bootstrap_user
		rc=$?
	fi
	if ((rc != 0)); then
		dialog --backtitle "$BACKTITLE" --title " Failed " --textbox "$LOG" 0 0 >/dev/tty 2>&1 || true
		clear
		echo "The bootstrap stopped with an error. See $LOG"
		exit 1
	fi
	c="All done. Log out and log in as $u."
	if [[ -s $WARN_FILE ]]; then c+="\n\n\Z3Warnings:\Zn\n$(sed 's/$/\\n/' "$WARN_FILE" | tr -d '\n')"; fi
	msg "$c" "All done!" 18 74
	clear
	exit 0
}

main() {
	local preset="" start=Disk
	case ${1:-} in
		-h | --help) usage; exit 0 ;;
		-V | --version) echo "$SCRIPT_VERSION"; exit 0 ;;
		-b | --bootstrap) bootstrap_main ;;
		-p | --preset)
			[[ -n ${2:-} && $# -eq 2 ]] || { usage >&2; exit 2; }
			preset=$2
			;;
		--preset=?*)
			[[ $# -eq 1 ]] || { usage >&2; exit 2; }
			preset=${1#--preset=}
			;;
		"") ;;
		*) usage >&2; exit 2 ;;
	esac
	preflight
	trap '[[ $INSTALL_STARTED == 1 ]] && cleanup_target' EXIT
	trap 'exit 130' INT TERM
	ensure_dialog
	ensure_network
	msg "This installer puts Void Linux on a whole disk.\n\n  * UEFI or BIOS, GPT partitioning\n  * ext4 or btrfs\n  * no encryption, LUKS1 or LUKS2\n  * GRUB, Limine, systemd-boot, rEFInd,\n    UKI, EFISTUB or SYSLINUX\n  * glibc or musl; desktops and window managers\n    (pick several) with dotfile presets\n  * GPU drivers, apps, gaming (32-bit), xbps-src\n  * several users with sudo levels, LARBS-style bootstrap\n\nNothing is written until you confirm the summary and type the disk name.\nLog file: $LOG" \
		"Welcome" 19 74
	if [[ -n $preset ]] && preset_load "$preset"; then
		preset_quick
		start=$MENU_JUMP
		MENU_JUMP=""
	fi
	main_menu "$start"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
	main "$@"
fi
