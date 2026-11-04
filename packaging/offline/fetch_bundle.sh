#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
# Build the offline bundle for one target machine, from the report its own
# check_env.sh wrote. Run on a networked machine, from the repository root:
#
#	sh packaging/offline/fetch_bundle.sh gpu-unlock-env.txt [outdir]
#
# The bundle carries the source, the pinned NVIDIA inputs or the packages
# already built from them, and every .deb the target is missing. Copy it
# over and run its install_offline.sh as root there.
set -eu

cd "$(dirname "$0")/../.."
version=$(cat VERSION)
report=${1:?usage: fetch_bundle.sh <check_env.sh report> [outdir]}
outdir=${2:-build/offline}
bundle=$outdir/gpu-unlock-offline-bundle
cache=${CACHE:-$HOME/.cache/gpu-unlock}
inputs=$cache/inputs

[ -r "$report" ] || { echo "no such report: $report" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }

# --- what the target is ---------------------------------------------------
key() { sed -n "s/^$1=//p" "$report" | head -1; }
distro=$(key DISTRO_ID)
codename=$(key DISTRO_CODENAME)
arch=$(key DPKG_ARCH)
kernel=$(key KERNEL)
abi=$(key KERNEL_ABI)
gpus=$(key SUPPORTED_GPU_COUNT)

case "$distro" in
	debian|ubuntu) ;;
	*) echo "target is $distro; only .deb bundles are supported" >&2; exit 1 ;;
esac
case "$arch" in
	amd64) ;;
	*) echo "WARNING: target is $arch, the pinned NVIDIA installer is x86_64 only" >&2 ;;
esac
if [ "${gpus:-0}" -eq 0 ]; then
	echo "WARNING: the target reports no supported GPU; building anyway" >&2
fi
echo "target: $distro $codename $arch, kernel $kernel, $gpus supported GPU(s)"

rm -rf "$bundle"
mkdir -p "$bundle/src" "$bundle/debs"

# --- the source -----------------------------------------------------------
# make dist snapshots the working tree through git; without a checkout, tar
# the tree as it stands. Both unpack to gpu-unlock-<version>/, which is what
# install_offline.sh expects.
if make dist DISTDIR="$outdir" >/dev/null 2>&1 && [ -f "$outdir/gpu-unlock-$version.tar.xz" ]; then
	cp "$outdir/gpu-unlock-$version.tar.xz" "$bundle/src/"
else
	echo "git archive unavailable, tarring the working tree" >&2
	stage=$outdir/src-stage/gpu-unlock-$version
	rm -rf "$outdir/src-stage"
	mkdir -p "$stage"
	tar --exclude=./build --exclude=./.git --exclude=./src-stage -cf - . | tar -xf - -C "$stage"
	tar -cJf "$bundle/src/gpu-unlock-$version.tar.xz" -C "$outdir/src-stage" "gpu-unlock-$version"
	rm -rf "$outdir/src-stage"
fi

# --- the NVIDIA inputs, and the packages built from them ------------------
# Prebuilding here is worth it: the two packages are Architecture: all, so
# they fit any dpkg target, and the offline machine then needs no debhelper.
prebuilt=0
if command -v dpkg-buildpackage >/dev/null && command -v dh >/dev/null; then
	make inputs INPUTS="$inputs"
	echo "==> building gpu-unlock-dkms and gpu-unlock-firmware"
	if make deb INPUTS="$(realpath "$inputs")" DISTDIR="$outdir" >&2; then
		mkdir -p "$bundle/prebuilt"
		cp "$outdir"/deb/gpu-unlock-*_"$version"_all.deb "$bundle/prebuilt/"
		prebuilt=1
	else
		echo "build failed, the target will build the packages itself" >&2
	fi
else
	echo "no dpkg-buildpackage here, the target will build the packages itself" >&2
fi
if [ "$prebuilt" -eq 0 ]; then
	make inputs INPUTS="$inputs"
	mkdir -p "$bundle/inputs"
	cp "$inputs"/NVIDIA-* "$bundle/inputs/"
fi

# --- the target's missing .debs -------------------------------------------
# dkms compiles the module on the target, so the headers for its running
# kernel and a toolchain are not optional. gcc, make and libc6-dev are only a
# Recommends of dkms, which this resolver does not follow, so they are asked
# for explicitly. Without prebuilt packages the target also has to run
# dpkg-buildpackage.
want="dkms kmod pciutils initramfs-tools gcc make libc6-dev linux-headers-$kernel"
[ "$abi" = "$kernel" ] || want="$want linux-headers-$abi"
[ "$prebuilt" -eq 1 ] ||
	want="$want debhelper dh-sequence-dkms dpkg-dev python3 zstd xz-utils git"

echo "==> resolving .debs"
missing=0
python3 packaging/offline/resolve_debs.py --report "$report" \
	--out "$bundle/debs" --want $want || missing=1

cp "$report" "$bundle/env-report.txt"
# install_offline.sh reruns the check on the target, so it holds the
# supported device IDs rather than a second copy of them.
cp packaging/offline/check_env.sh packaging/offline/install_offline.sh "$bundle/"
chmod +x "$bundle"/*.sh
{
	echo "BUNDLE_VERSION=$version"
	echo "BUILT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
	echo "BUILT_ON=$(uname -sr) $(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null || echo unknown)"
	echo "TARGET_DISTRO=$distro"
	echo "TARGET_CODENAME=$codename"
	echo "TARGET_ARCH=$arch"
	echo "TARGET_KERNEL=$kernel"
	echo "TARGET_SUPPORTED_GPUS=$gpus"
	echo "PREBUILT=$prebuilt"
	echo "NVIDIA_PINNED=610.43.03"
} >"$bundle/BUNDLE.txt"

archive=$outdir/gpu-unlock-offline-bundle.tar.gz
tar -czf "$archive" -C "$outdir" "$(basename "$bundle")"
sha256sum "$archive" >"$archive.sha256"
du -sh "$archive" "$bundle/debs" >&2

cat >&2 <<EOF

bundle: $archive ($(du -m "$archive" | cut -f1) MiB)
  $(cat "$archive.sha256")
  prebuilt packages: $prebuilt (0 means the target builds them, needing debhelper)

copy $archive to the target, then there:
  tar -xzf $(basename "$archive")
  cd $(basename "$bundle")
  sudo sh install_offline.sh
EOF
[ "$missing" -eq 0 ] || {
	echo "WARNING: some packages were not found in the $codename index," >&2
	echo "see the ERROR lines above and add those .debs to $bundle/debs by hand." >&2
	exit 2
}
