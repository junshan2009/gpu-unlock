#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Report what this machine has, so a networked machine can fetch the right
# offline bundle for it. Run on the target server as root; nothing here
# touches the network and nothing is modified.
#
#	sh packaging/offline/check_env.sh [report.txt]
#
# Copy the report to the networked machine and pass it to
# packaging/offline/fetch_bundle.sh. The KEY=value lines and the INSTALLED:
# list are what the fetcher reads; the rest is for a human, and for an issue
# report if the unlock later fails.
#
# The per-chip ID variables below are read through eval, which shellcheck
# cannot follow, hence the file-wide disable.
# shellcheck disable=SC2034,SC2154
set -eu

out=${1:-gpu-unlock-env.txt}
exec 3>&2
exec >"$out" 2>&1
say() { printf '%s\n' "$*" >&3; }
say "collecting into $out ..."

# The PCI device IDs kernel/gpu_unlock/recipes.c accepts, by chip family.
# Keep in sync with cards[] there.
TU102="1e03 1e04 1e07 1e2d 1e2e"
TU104="1e81 1e82 1e84 1e87 1e89 1ec2 1ec7"
TU106="1f02 1f03 1f06 1f07 1f08 1f42 1f47"
GA102="2200 2203 2204 2205 2206 2207 2208 220a 220d 2216 222b 222f"
GA103="2414"
GA104="2480 2482 2483 2484 2486 2487 2488 2489 248a 248c 248d 248e 249c 249d 249f 24a0 24a4 24ac 24ad 24af 24bf 24c0 24c7 24c8 24c9 24dc 24dd 24df 24e0"
GA106="2501 2503 2504 2505 2507 2508 2509 252f 2544"
AD102="2684 2685 2689"
AD103="2702 2704 2705 2709 2757"
AD104="2782 2783 2786"
AD106="2803 2805"
AD107="2882 28a0 28e0 28e1"
CHIPS="TU102 TU104 TU106 GA102 GA103 GA104 GA106 AD102 AD103 AD104 AD106 AD107"

have() { command -v "$1" >/dev/null 2>&1; }
# "tool: path first-line-of-version", or "tool: MISSING".
probe() {
	if have "$1"; then
		printf '%s: %s %s\n' "$1" "$(command -v "$1")" "$("$@" 2>&1 | head -1)"
	else
		printf '%s: MISSING\n' "$1"
	fi
}
read_sys() {
	if [ -r "$1" ]; then cat "$1"; else echo unknown; fi
}

echo "=== gpu-unlock offline environment report ==="
echo "GENERATED=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "REPORT_FORMAT=1"
echo

echo "=== distribution ==="
ID=unknown
ID_LIKE=''
VERSION_CODENAME=unknown
VERSION_ID=unknown
PRETTY_NAME=unknown
for f in /etc/os-release /usr/lib/os-release; do
	# shellcheck disable=SC1090
	if [ "$ID" = unknown ] && [ -r "$f" ]; then . "$f"; fi
done
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
kernel=$(uname -r)
echo "DISTRO_ID=$ID"
echo "DISTRO_ID_LIKE=$ID_LIKE"
echo "DISTRO_CODENAME=${VERSION_CODENAME:-unknown}"
echo "DISTRO_VERSION=${VERSION_ID:-unknown}"
echo "DISTRO_NAME=${PRETTY_NAME:-unknown}"
echo "DPKG_ARCH=$arch"
echo "KERNEL=$kernel"
# Ubuntu and Debian split headers into linux-headers-<abi> plus -<abi>-<flavour>.
abi=${kernel%-*}
echo "KERNEL_ABI=$abi"
echo "KERNEL_FLAVOUR=${kernel#"$abi"-}"
echo "MACHINE=$(uname -m)"
if [ -d /sys/firmware/efi ]; then echo "BOOT_FIRMWARE=uefi"; else echo "BOOT_FIRMWARE=bios"; fi
echo

echo "=== NVIDIA GPUs ==="
# sysfs is always present; lspci only adds the marketing name.
supported=0
unsupported=0
for dev in /sys/bus/pci/devices/*; do
	[ "$(read_sys "$dev/vendor")" = 0x10de ] || continue
	case "$(read_sys "$dev/class")" in
		0x0300*|0x0302*) ;;
		*) continue ;;
	esac
	device=$(read_sys "$dev/device")
	device=${device#0x}
	slot=$(basename "$dev")
	name=
	if have lspci; then
		name=$(lspci -s "$slot" 2>/dev/null | cut -d' ' -f2-)
	fi
	driver=$(readlink "$dev/driver" 2>/dev/null || true)
	driver=${driver##*/}
	[ -n "$driver" ] || driver=none
	family=
	for chip in $CHIPS; do
		eval "ids=\${$chip}"
		for id in $ids; do
			if [ "$id" = "$device" ]; then family=$chip; fi
		done
	done
	if [ -n "$family" ]; then
		supported=$((supported + 1))
		verdict="SUPPORTED ($family)"
	else
		unsupported=$((unsupported + 1))
		verdict="NOT-SUPPORTED"
	fi
	echo "GPU_PCI=$slot GPU_DEVICE=0x$device GPU_DRIVER=$driver GPU_STATUS=$verdict"
	echo "    ${name:-<name unavailable, lspci/pciutils not installed>}"
done
if [ $((supported + unsupported)) -eq 0 ]; then
	echo "GPU_PCI=none  no NVIDIA VGA or 3D controller found"
fi
echo "SUPPORTED_GPU_COUNT=$supported"
echo "UNSUPPORTED_GPU_COUNT=$unsupported"
echo

echo "=== NVIDIA driver ==="
probe nvidia-smi --version
if [ -r /proc/driver/nvidia/version ]; then
	cat /proc/driver/nvidia/version
else
	echo "/proc/driver/nvidia/version: absent, the driver is not loaded"
fi
echo "loaded: $(lsmod 2>/dev/null | awk '/^nvidia/ {printf "%s ", $1}')"
echo "A loaded driver is expected: gpu_unlock runs from the initramfs, before"
echo "nvidia binds the card."
echo

echo "=== build and install toolchain ==="
probe make --version
probe gcc --version
probe ld --version
probe dpkg --version
probe dpkg-deb --version
probe dpkg-buildpackage --version
probe dh --version
probe dkms --version
probe python3 --version
probe zstd --version
probe xz --version
probe tar --version
probe git --version
probe lspci --version
for t in update-initramfs update-grub grub-mkconfig dracut mkinitcpio mokutil; do
	if have "$t"; then
		echo "$t: $(command -v "$t")"
	else
		echo "$t: MISSING"
	fi
done
echo

echo "=== kernel headers, dkms needs them for the running kernel ==="
if [ -e "/lib/modules/$kernel/build" ]; then
	echo "/lib/modules/$kernel/build -> $(readlink -f "/lib/modules/$kernel/build")"
else
	echo "/lib/modules/$kernel/build: MISSING, the bundle must carry linux-headers-$kernel"
fi
for k in /lib/modules/*; do
	[ -d "$k" ] || continue
	if [ -e "$k/build" ]; then state=present; else state=missing; fi
	printf 'kernel %s: headers %s\n' "$(basename "$k")" "$state"
done
ls -d /usr/src/linux-headers-* 2>/dev/null || echo "/usr/src/linux-headers-*: none"
echo

echo "=== dkms ==="
if have dkms; then
	dkms status 2>&1 || true
else
	echo "dkms: not installed"
fi
echo

echo "=== boot configuration ==="
echo "CMDLINE=$(cat /proc/cmdline)"
echo "GRUB_CMDLINE_LINUX_DEFAULT=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=//p' /etc/default/grub 2>/dev/null)"
if have mokutil; then
	echo "SECURE_BOOT=$(mokutil --sb-state 2>&1 || echo unknown)"
else
	echo "SECURE_BOOT=unknown, mokutil missing"
fi
generators=
for pair in /usr/sbin/update-initramfs:initramfs-tools /usr/bin/dracut:dracut \
	/usr/bin/mkinitcpio:mkinitcpio; do
	if [ -x "${pair%%:*}" ]; then generators="$generators ${pair##*:}"; fi
done
echo "INITRAMFS_GENERATORS=${generators:-none}"
echo

echo "=== disk space ==="
df -h / /boot /var /usr/src 2>/dev/null | sort -u
echo

echo "=== gpu-unlock packages already installed ==="
dpkg-query -W -f '${Package} ${Version}\n' 'gpu-unlock*' 2>/dev/null || echo none
echo

echo "=== installed packages, read by fetch_bundle.sh to skip them ==="
dpkg-query -W -f 'INSTALLED: ${Package} ${Version} ${Architecture}\n' 2>/dev/null ||
	echo "INSTALLED: dpkg-query-unavailable 0 none"
echo

echo "=== verdict ==="
if [ "$supported" -gt 0 ]; then
	echo "OK: $supported supported GPU(s), worth building the bundle."
else
	echo "STOP: no card from recipes.c cards[] is present, there is nothing to unlock."
fi
case "$ID" in
	debian|ubuntu) echo "OK: $ID is a dpkg distribution." ;;
	*) echo "WARN: $ID is not Debian/Ubuntu, fetch_bundle.sh only makes .deb bundles." ;;
esac
if [ "$arch" = amd64 ]; then
	echo "OK: amd64, matches the pinned NVIDIA x86_64 installer."
else
	echo "WARN: $arch is not amd64, the pinned NVIDIA installer is x86_64 only."
fi
if [ -e "/lib/modules/$kernel/build" ]; then
	echo "OK: headers for the running kernel are present."
else
	echo "NOTE: headers for $kernel are missing, the bundle must carry them."
fi

say "wrote $out"
say "copy it to the networked machine and run:"
say "  sh packaging/offline/fetch_bundle.sh $out"
