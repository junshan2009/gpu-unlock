#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Install gpu-unlock on this machine from the bundle fetch_bundle.sh made for
# it. Nothing here touches the network. Run as root from inside the unpacked
# bundle directory:
#
#	sudo sh install_offline.sh [option...]
#
#	--targets=SPEC  value for gpu_unlock.targets=, "all" by default, or a
#	                comma separated list of PCI addresses as lspci -D prints
#	--no-cmdline    install the packages, leave the bootloader alone
#	--dry-run       report what would happen, change nothing
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$here"
version=$(sed -n 's/^BUNDLE_VERSION=//p' BUNDLE.txt)
prebuilt=$(sed -n 's/^PREBUILT=//p' BUNDLE.txt)
nvidia=$(sed -n 's/^NVIDIA_PINNED=//p' BUNDLE.txt)
target_kernel=$(sed -n 's/^TARGET_KERNEL=//p' BUNDLE.txt)
target_arch=$(sed -n 's/^TARGET_ARCH=//p' BUNDLE.txt)
target_codename=$(sed -n 's/^TARGET_CODENAME=//p' BUNDLE.txt)

targets=all
cmdline=1
dry=0
for arg in "$@"; do
	case "$arg" in
		--targets=*) targets=${arg#--targets=} ;;
		--no-cmdline) cmdline=0 ;;
		--dry-run) dry=1 ;;
		-h|--help) sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "unknown option: $arg" >&2; exit 2 ;;
	esac
done

run() {
	echo "+ $*"
	if [ "$dry" -eq 0 ]; then "$@"; fi
}
fail() {
	echo "install_offline: $*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || fail "run as root: sudo sh install_offline.sh"
[ -n "$version" ] || fail "no BUNDLE.txt here; run this from inside the unpacked bundle"

# --- is this the machine the bundle was made for? -------------------------
# The bundle carries linux-headers for one exact kernel. On any other kernel
# dkms has nothing to build against, so this is fatal rather than a warning.
kernel=$(uname -r)
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
codename=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null || echo unknown)
[ "$kernel" = "$target_kernel" ] ||
	fail "this is kernel $kernel, the bundle carries headers for $target_kernel.
Rerun check_env.sh and fetch_bundle.sh, or put linux-headers-$kernel in debs/ first."
[ "$arch" = "$target_arch" ] || fail "this is $arch, the bundle is for $target_arch"
[ "$codename" = "$target_codename" ] ||
	echo "WARNING: this is $codename, the bundle was made for $target_codename" >&2

# --- is there a card to unlock? -------------------------------------------
# check_env.sh holds the supported device IDs, so rerun it instead of
# repeating them here.
if [ -f check_env.sh ]; then
	report=/tmp/gpu-unlock-preinstall.txt
	run sh check_env.sh "$report"
	if [ -r "$report" ]; then
		grep '^GPU_' "$report" || true
		count=$(sed -n 's/^SUPPORTED_GPU_COUNT=//p' "$report")
		[ "${count:-0}" -gt 0 ] ||
			fail "no GPU from recipes.c cards[] is present, nothing to unlock"
		# An unsigned out-of-tree module is refused under Secure Boot, and
		# the failure is silent: the machine boots, nvidia loads, and the
		# card simply stays at half speed.
		case "$(sed -n 's/^SECURE_BOOT=//p' "$report")" in
			*[Ee]nabled*)
				echo "WARNING: Secure Boot is on. The dkms module is unsigned, so the" >&2
				echo "kernel will refuse to load it and the unlock will silently not" >&2
				echo "happen. Turn Secure Boot off in the firmware setup, or enrol a" >&2
				echo "MOK and sign the module before rebooting." >&2
				;;
		esac
	fi
fi

# --- the distribution's own packages --------------------------------------
# dpkg unpacks the whole batch before configuring any of it, so the order of
# the glob does not matter; a second pass covers Pre-Depends cycles.
if ls debs/*.deb >/dev/null 2>&1; then
	set -- debs/*.deb
	echo "==> installing $# distribution packages"
	run sh -c 'dpkg -i debs/*.deb || dpkg -i debs/*.deb' ||
		fail "dpkg refused some packages. The messages above name what is
missing or conflicting; a package already installed in a newer version than
the archive has is the usual cause. Fix that one by hand and rerun."
	set --
else
	echo "==> no debs/ in the bundle, using what is already installed"
fi
if [ "$dry" -eq 0 ]; then
	for tool in dkms make gcc; do
		command -v "$tool" >/dev/null || fail "$tool is still missing, the bundle is incomplete"
	done
	if [ ! -e "/lib/modules/$kernel/build" ]; then
		fail "no headers for $kernel, dkms cannot build the module"
	fi
fi

# --- gpu-unlock itself ----------------------------------------------------
if [ "$prebuilt" = 1 ] && ls prebuilt/*.deb >/dev/null 2>&1; then
	echo "==> installing the prebuilt packages"
	run dpkg -i "prebuilt/gpu-unlock-firmware_${version}_all.deb" \
		"prebuilt/gpu-unlock-dkms_${version}_all.deb"
elif [ "$prebuilt" = 1 ]; then
	fail "BUNDLE.txt says prebuilt but there is no prebuilt/ directory"
else
	echo "==> building the packages here, this unpacks the NVIDIA inputs"
	[ -d inputs ] || fail "neither prebuilt/ nor inputs/ is in the bundle"
	build=$here/build-tree
	run rm -rf "$build"
	run mkdir -p "$build"
	run tar -xf "src/gpu-unlock-$version.tar.xz" -C "$build"
	if [ "$dry" -eq 0 ]; then
		(
			cd "$build/gpu-unlock-$version"
			GPU_UNLOCK_INPUTS="$here/inputs" dpkg-buildpackage -us -uc
		)
		run dpkg -i "$build/gpu-unlock-firmware_${version}_all.deb" \
			"$build/gpu-unlock-dkms_${version}_all.deb"
	fi
fi
if [ "$dry" -eq 0 ]; then
	[ -f "/usr/src/gpu-unlock-$version/dkms.conf" ] ||
		fail "/usr/src/gpu-unlock-$version/dkms.conf is not there, the dkms package did not install"
	[ -f "/usr/lib/firmware/gpu-unlock/$nvidia/gsp_ga10x.bin" ] ||
		fail "/usr/lib/firmware/gpu-unlock/$nvidia/gsp_ga10x.bin is not there, the firmware package did not install"
	echo "==> dkms status:"
	dkms status gpu-unlock 2>/dev/null || true
fi

# --- opt in on the kernel command line ------------------------------------
# The module is inert without gpu_unlock.targets=, so setting it is part of
# installing, not a step to remember later.
if [ "$cmdline" -eq 1 ]; then
	case " $(cat /proc/cmdline) " in
		*" gpu_unlock.targets="*)
			echo "==> gpu_unlock.targets= is already on the kernel command line"
			;;
		*)
			if [ -f /etc/default/grub ]; then
				run cp /etc/default/grub /etc/default/grub.bak-gpu-unlock
				echo "==> adding gpu_unlock.targets=$targets to /etc/default/grub"
				echo "    the original stays in /etc/default/grub.bak-gpu-unlock"
				if [ "$dry" -eq 0 ]; then
					sed -i '/^GRUB_CMDLINE_LINUX_DEFAULT=/{/gpu_unlock\.targets=/!s|"$| gpu_unlock.targets='"$targets"'"|}' \
						/etc/default/grub
					grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub
					grep -q "gpu_unlock.targets=$targets" /etc/default/grub ||
						fail "could not edit GRUB_CMDLINE_LINUX_DEFAULT; add
gpu_unlock.targets=$targets inside its quotes by hand"
				fi
				if command -v update-grub >/dev/null; then
					run update-grub
				elif command -v grub-mkconfig >/dev/null; then
					run grub-mkconfig -o /boot/grub/grub.cfg
				else
					echo "WARNING: no update-grub, regenerate the boot config yourself" >&2
				fi
			elif [ -f /etc/kernel/cmdline ]; then
				run cp /etc/kernel/cmdline /etc/kernel/cmdline.bak-gpu-unlock
				run sh -c "echo 'gpu_unlock.targets=$targets' >>/etc/kernel/cmdline"
				echo "==> appended to /etc/kernel/cmdline"
				echo "    regenerate your UKI or boot entries for it to take effect"
			elif command -v grubby >/dev/null; then
				run grubby --update-kernel=ALL --args="gpu_unlock.targets=$targets"
			else
				echo "WARNING: no GRUB, systemd-boot or grubby config found. Add" >&2
				echo "gpu_unlock.targets=$targets to the kernel command line yourself," >&2
				echo "or the module stays inert." >&2
			fi
			;;
	esac
fi

# --- initramfs ------------------------------------------------------------
# The package postinst rebuilt it already; do it again so a command line
# edited above is in the image that boots next.
if command -v update-initramfs >/dev/null; then
	run update-initramfs -u -k all
elif command -v dracut >/dev/null; then
	run dracut --force --regenerate-all
elif command -v mkinitcpio >/dev/null; then
	run mkinitcpio -P
else
	echo "WARNING: no initramfs generator found. gpu_unlock must be in the" >&2
	echo "initramfs to run before nvidia binds the card." >&2
fi

cat <<EOF

done. Reboot, then check that it took:

  journalctl -k -b | grep gpu_unlock
  lspci -nnk -s <a GPU slot from the report above>

To stop unlocking, drop gpu_unlock.targets= from the kernel command line
(the pre-edit /etc/default/grub is kept as grub.bak-gpu-unlock) and reboot.
"apt-get purge gpu-unlock-dkms gpu-unlock-firmware" removes it completely.

A working unlock with benchmark numbers belongs in a comment on
https://github.com/Zagitta/gpu-unlock/discussions/238 - please post it there.
EOF
