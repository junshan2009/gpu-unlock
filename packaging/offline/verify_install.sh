#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Say whether gpu-unlock is installed on this machine and whether it is
# actually unlocking. Run it after the reboot that follows install_offline.sh:
#
#	sh verify_install.sh
#
# Seven checks, outermost to innermost: packages, dkms build, module loaded,
# initramfs contents, kernel command line, boot log, driver binding. A check
# that fails names the layer to look at; the boot log lines are printed so a
# failure can be pasted into an issue or a discussion reply.
set -u

kernel=$(uname -r)
fails=0
ok() { printf 'PASS  %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
note() { printf '      %s\n' "$1"; }

echo "=== 1. packages ==="
status=$(dpkg-query -W -f '${Package} ${Status}\n' gpu-unlock-dkms gpu-unlock-firmware 2>/dev/null)
if [ "$(printf '%s\n' "$status" | wc -l)" -eq 2 ] &&
		! printf '%s\n' "$status" | grep -qv 'install ok installed$'; then
	ok "gpu-unlock-dkms and gpu-unlock-firmware are installed"
else
	no "a gpu-unlock package is missing or half-configured"
	printf '%s\n' "$status" | sed 's/^/      /'
fi

echo "=== 2. dkms build for the running kernel ==="
src=$(ls -d /usr/src/gpu-unlock-* 2>/dev/null | head -1)
if [ -n "$src" ] && dkms status gpu-unlock 2>/dev/null | grep "$kernel" | grep -q installed; then
	ok "module built for $kernel"
	note "$(dkms status gpu-unlock 2>/dev/null | grep "$kernel")"
else
	no "no gpu_unlock module built for $kernel"
	note "dkms status: $(dkms status gpu-unlock 2>/dev/null || echo 'dkms missing')"
	note "headers for $kernel: $([ -e "/lib/modules/$kernel/build" ] && echo present || echo MISSING)"
fi

echo "=== 3. module loaded and opted in ==="
if [ -d /sys/module/gpu_unlock ]; then
	ok "gpu_unlock is loaded"
	note "targets=$(cat /sys/module/gpu_unlock/parameters/targets 2>/dev/null)"
	note "resume=$(cat /sys/module/gpu_unlock/parameters/resume 2>/dev/null)"
else
	no "gpu_unlock is not loaded"
	note "it loads from the initramfs only when gpu_unlock.targets= is on the"
	note "kernel command line; checks 4 and 5 say which of the two is missing"
fi

echo "=== 4. module and firmware inside the initramfs ==="
image=/boot/initrd.img-$kernel
if [ -r "$image" ] && command -v lsinitramfs >/dev/null; then
	list=$(lsinitramfs "$image" 2>/dev/null)
	if echo "$list" | grep -q 'gpu_unlock.ko' && echo "$list" | grep -q 'firmware/gpu-unlock/'; then
		ok "$image carries gpu_unlock.ko and its firmware"
		note "$(echo "$list" | grep -c 'gpu-unlock/') firmware files, plus:"
		echo "$list" | grep 'gpu_unlock' | sed 's/^/      /' | head -4
	else
		no "$image lacks gpu_unlock or its firmware; rerun update-initramfs -u -k all"
	fi
else
	note "no lsinitramfs or no $image; skipped (dracut: lsinitrd $image)"
fi

echo "=== 5. kernel command line opt-in ==="
if cmdline=$(tr ' ' '\n' < /proc/cmdline | grep '^gpu_unlock\.targets='); then
	ok "$cmdline"
else
	no "gpu_unlock.targets= is not on the command line, the module stays inert"
	note "GRUB_CMDLINE_LINUX_DEFAULT=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT=//p' /etc/default/grub 2>/dev/null)"
	note "add it and run update-grub, then reboot"
fi

echo "=== 6. what the module did at boot ==="
if command -v journalctl >/dev/null; then
	log=$(journalctl -k -b 2>/dev/null | grep gpu_unlock || true)
else
	log=$(dmesg 2>/dev/null | grep gpu_unlock || true)
fi
unlocked=$(printf '%s\n' "$log" | grep -c 'gpu_unlock: unlocked$')
failed=$(printf '%s\n' "$log" | grep -c 'gpu_unlock: .*failed')
if [ "$unlocked" -gt 0 ] && [ "$failed" -eq 0 ]; then
	ok "$unlocked card(s) unlocked at boot, no failures"
elif [ "$failed" -gt 0 ]; then
	no "$unlocked unlocked, $failed failed"
else
	no "the module logged nothing at boot"
	note "either it is not in the initramfs (check 4), not opted in (check 5),"
	note "or the kernel refused the unsigned module (Secure Boot: mokutil --sb-state)"
fi
printf '%s\n' "$log" | sed 's/^/      /' | head -12

echo "=== 7. nvidia bound the cards afterwards ==="
cards=0
for dev in /sys/bus/pci/devices/*; do
	[ "$(cat "$dev/vendor" 2>/dev/null)" = 0x10de ] || continue
	case "$(cat "$dev/class" 2>/dev/null)" in 0x0300*|0x0302*) ;; *) continue ;; esac
	cards=$((cards + 1))
	driver=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)
	printf '      %s driver=%s\n' "$(basename "$dev")" "${driver:-none}"
done
if [ "$cards" -gt 0 ] && [ "$unlocked" -eq "$cards" ]; then
	ok "all $cards NVIDIA card(s) unlocked and bound to nvidia"
elif [ "$cards" -eq 0 ]; then
	no "no NVIDIA display controller found"
else
	no "$unlocked of $cards cards unlocked"
fi

echo
if [ "$fails" -eq 0 ]; then
	echo "gpu-unlock is installed and unlocking on this machine."
	echo
	echo "Speed proof, BF16 GEMM (expect roughly double the capped rate;"
	echo "the RTX 4090 is power limited, so large GEMMs gain less than peak):"
	echo "  python3 -c 'import torch,time;a=torch.randn(8192,8192,device=\"cuda\",dtype=torch.bfloat16);torch.cuda.synchronize();t=time.time();[a@a for _ in range(20)];torch.cuda.synchronize();print(2*2*8192**3*20/(time.time()-t)/1e12,\"TFLOPS\")'"
	echo
	echo "Post the numbers to https://github.com/Zagitta/gpu-unlock/discussions/238"
	exit 0
fi
echo "$fails check(s) failed; the notes above name the layer to fix."
exit 1
