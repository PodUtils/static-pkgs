#!/bin/sh
# Check the assets of a build of qemu on the host that built them.
#
#   CHECK_STATIC=PATH sh pkgs/qemu/check.sh DIST RELEASE ARCH
#
# CHECK_STATIC is scripts/check-static.sh of PodUtils/podcrates (no
# PT_INTERP, no DT_NEEDED). For each binary archive: the one member
# ./bin/NAME, a static ELF, the version of pkg.toml in --version. The
# emulator of the host advertises KVM. The firmware of the data archive
# boots: each emulator runs with bin/../share/qemu and no -L until the time
# limit, and a missing firmware stops it at once. Each file of the static
# link with a copyleft licence has its source asset in DIST/../source
# (scripts/pkg.py linked).
set -eu
[ "$#" -eq 3 ] || { echo "usage: check.sh DIST RELEASE ARCH" >&2; exit 2; }
dist=$1 release=$2 arch=$3
: "${CHECK_STATIC:?the path of check-static.sh of podcrates}"
here=$(cd "$(dirname "$0")" && pwd)
version=$(python3 -I "$here/../../scripts/pkg.py" get "$here" version)
version_re=$(echo "$version" | sed 's/\./\\./g')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
die() { echo "check: $*" >&2; exit 1; }

for name in qemu-system-x86_64 qemu-system-aarch64 qemu-img; do
    a=$dist/$name-$release-linux-$arch.tar.gz
    [ -f "$a" ] || die "no asset $a"
    members=$(tar -tzf "$a" | grep -v '/$')
    [ "$members" = "./bin/$name" ] || die "$a holds $members, not ./bin/$name"
    tar -xzf "$a" -C "$work"
    sh "$CHECK_STATIC" "$work/bin/$name"
    line=$("$work/bin/$name" --version | head -1)
    echo "$line" | grep -Eq "version $version_re([^0-9.]|\$)" || die "$name reports '$line', not $version"
    echo "check: $name: $line"
done

data=$dist/qemu-data-$release-linux-$arch.tar.gz
[ -f "$data" ] || die "no asset $data"
tar -xzf "$data" -C "$work"
for f in bios-256k.bin edk2-x86_64-code.fd edk2-aarch64-code.fd kvmvapic.bin efi-e1000e.rom; do
    [ -s "$work/share/qemu/$f" ] || die "$data has no share/qemu/$f"
done
tar -tzf "$data" | grep -v '^\./share/qemu' | grep -v '^\./$' | grep -v '^\./share/$' &&
    die "$data holds files out of ./share/qemu"

case $arch in
    amd64) native=qemu-system-x86_64 ;;
    arm64) native=qemu-system-aarch64 ;;
    *) die "no host $arch" ;;
esac
"$work/bin/$native" -accel help | grep -qx kvm || die "$native does not advertise kvm"

# Run until the time limit: exit 124 is the pass.
boots() {
    rc=0
    timeout 10 "$@" -display none -nodefaults -serial none -monitor none -m 128 \
        -accel tcg > "$work/boot.log" 2>&1 || rc=$?
    [ "$rc" = 124 ] || { cat "$work/boot.log" >&2; die "$* stopped with exit $rc before the time limit"; }
}
boots "$work/bin/qemu-system-x86_64" -machine q35
boots "$work/bin/qemu-system-aarch64" -machine virt -cpu max -bios edk2-aarch64-code.fd
python3 -I "$here/../../scripts/pkg.py" linked "$here" "$dist/qemu-$release-linux-$arch.linked.txt" "$dist/../source"
echo "check: qemu $release linux-$arch: the assets pass"
