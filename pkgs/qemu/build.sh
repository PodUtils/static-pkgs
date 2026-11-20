#!/bin/sh
# Build the static QEMU in the pinned Alpine container (scripts/build.sh
# starts it). The recipe comes from hermeticbuild/qemu-prebuilt (MIT,
# LICENSE.hermeticbuild): its Dockerfile, build and
# tools/package-qemu-artifacts.sh in one script of POSIX sh.
#
# In: /recipe (this directory, read-only), the PKG_* and DEP_* values of
# scripts/pkg.py env, PKG_OUT_OWNER (UID:GID of the files of /out).
# Out: /out/dist (the assets of this host) and /out/source (the source of
# each part that the binaries hold, the same bytes on each host):
#   qemu-VERSION.tar.xz and .sig       the release tarball of upstream
#   qemu-VERSION-subprojects.tar.xz    the subprojects that configure fetched
#   DEP_*_ASSET                        each [[dep]]: the tarball of upstream,
#                                      or git archive of the pinned commit
# and /out/dist/qemu-RELEASE-linux-ARCH.linked.txt: each input file of the
# static link of each binary, its owner, its licence and its source asset.
set -eu

say() { echo "qemu: $*"; }
die() { echo "qemu: $*" >&2; exit 1; }

# Run a command again after a failure of the network: 5 times at most.
retry() {
    n=1
    until "$@"; do
        [ "$n" -lt 5 ] || die "failed 5 times: $*"
        sleep $((n * 10))
        n=$((n + 1))
    done
}

# Fetch the tag REF of REPO into DIR and check that it is the commit COMMIT.
# DEPTH "full" fetches the history too (a server of dumb HTTP has no
# shallow fetch).
fetch() {
    repo=$1 ref=$2 commit=$3 dir=$4 depth=${5:-1}
    git init -q "$dir"
    git -C "$dir" remote add origin "$repo"
    if [ "$depth" = full ]; then
        retry git -C "$dir" fetch -q origin "refs/tags/$ref:refs/tags/$ref"
    else
        retry git -C "$dir" fetch -q --depth="$depth" origin "refs/tags/$ref:refs/tags/$ref"
    fi
    got=$(git -C "$dir" rev-parse "refs/tags/$ref^{commit}")
    [ "$got" = "$commit" ] || die "$ref of $repo is the commit $got, not the pin $commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q "$commit"
    say "$repo $ref is $commit"
}

# A tar with the same bytes on each host: sorted names, owner 0, the time
# of the commit of QEMU.
tar_same() {
    tar --sort=name --owner=0 --group=0 --numeric-owner --mode=u+rwX,go+rX,go-w \
        --mtime="@$SOURCE_DATE_EPOCH" "$@"
}

# Download URL to OUT and check its SHA-256.
download() {
    url=$1 sum=$2 out=$3
    retry curl -qfsSL --max-time 900 -o "$out" "$url"
    echo "$sum  $out" | sha256sum -c - > /dev/null || die "$url has another SHA-256 than $sum"
    say "$url: SHA-256 $sum"
}

# git archive of the commit COMMIT of DIR as NAME-VERSION/ in a tar.xz
# (one thread of xz: the same bytes on each host).
git_source() {
    git -C "$1" archive --prefix="$2/" "$3" | xz -T1 -9 > "$4"
}

# A tar.gz of the directory STAGE (members ./bin/NAME or ./share/qemu/...).
archive() {
    stage=$1 out=$2
    tar_same -C "$stage" -cf - . | gzip -n -9 > "$out"
    gzip -t "$out"
    say "asset $out ($(wc -c < "$out") bytes)"
}

# The checks of a static ELF: no program interpreter, no NEEDED entry.
static_elf() {
    readelf -lW "$1" | grep -q 'Requesting program interpreter' && die "$1 asks for a program interpreter"
    readelf -dW "$1" | grep -q '(NEEDED)' && die "$1 has a NEEDED entry"
    return 0
}

# The inputs of the static link of the binaries of QEMU: GNU ld writes a
# map of each link (-Wl,-Map=/work/maps/, an option of configure). Each
# input file gets its owner, version, licence and source asset
# (scripts/pkg.py linked checks the list):
#
#   FILE<TAB>OWNER<TAB>VERSION<TAB>LICENCE<TAB>SOURCE
#
# OWNER: qemu (the build directory of QEMU), dep:NAME (/work/deps/NAME),
# apk:NAME (a package of Alpine). LICENCE is "-" when pkg.toml gives it.
# A file with no owner stops the build. /work/subprojects.added holds the
# subprojects that configure fetched.

# The source asset of a dep.
dep_asset() {
    case $1 in
        libslirp) echo "$DEP_LIBSLIRP_ASSET" ;;
        glib) echo "$DEP_GLIB_ASSET" ;;
        libaio) echo "$DEP_LIBAIO_ASSET" ;;
        *) die "no source asset of the dep $1" ;;
    esac
}

# The input files of the link of the binary NAME, one in each line: each
# LOAD line of the map that GNU ld wrote (-Wl,-Map=/work/maps/). An archive
# counts when ld loads it, also when it takes no member from it.
link_inputs() {
    map=/work/maps/$1.map
    [ -f "$map" ] || die "no map of the link of $1"
    python3 -I - "$map" /work/out/qemu <<'EOF'
import os
import re
import sys

mapfile, base = sys.argv[1], sys.argv[2]
files = set()
for line in open(mapfile, encoding="utf-8", errors="replace"):
    if not line.startswith("LOAD "):
        continue
    name = line[5:].strip()
    # A temporary object of LTO at the link (ccXXXXXX.ltrans0.ltrans.o,
    # ccXXXXXX.debug.temp.o): it comes from the other LOAD files.
    if name == "linker stubs" or (re.fullmatch(r"/tmp/cc\w+\.[\w.]+\.o", name) and not os.path.exists(name)):
        continue
    path = os.path.realpath(os.path.join(base, name))
    if not os.path.isfile(path):
        sys.exit(f"linked: {mapfile}: LOAD {name} names no file")
    files.add(path)
if not files:
    sys.exit(f"linked: {mapfile} has no LOAD line")
print("\n".join(sorted(files)))
EOF
}

# The list of the inputs of the links of each target, with no repeat.
linked_list() {
    echo "# The input files of the static links of: $*."
    echo "# FILE<TAB>OWNER<TAB>VERSION<TAB>LICENCE<TAB>SOURCE"
    apk list --installed > /work/apk.list
    : > /work/inputs.txt
    for t in "$@"; do
        link_inputs "$t" >> /work/inputs.txt
    done
    sort -u /work/inputs.txt > /work/inputs.sorted
    while read -r f; do
        case $f in
            /work/out/qemu/subprojects/*)
                sp=${f#/work/out/qemu/subprojects/}
                sp=${sp%%/*}
                if grep -qx "$sp" /work/subprojects.added; then
                    src_asset=qemu-$PKG_VERSION-subprojects.tar.xz
                else
                    src_asset=qemu-$PKG_VERSION.tar.xz
                fi
                printf '%s\tqemu\t%s\t-\t%s\n' "$f" "$PKG_VERSION" "$src_asset"
                ;;
            /work/out/qemu/*)
                printf '%s\tqemu\t%s\t-\t%s\n' "$f" "$PKG_VERSION" "qemu-$PKG_VERSION.tar.xz"
                ;;
            /work/deps/*)
                d=${f#/work/deps/}
                d=${d%%/*}
                printf '%s\tdep:%s\t-\t-\t%s\n' "$f" "$d" "$(dep_asset "$d")"
                ;;
            *)
                pv=$(apk info -W "$f" 2> /dev/null | sed -n 's/.* is owned by //p')
                [ -n "$pv" ] || die "no owner of the input $f of the link"
                name=$(echo "$pv" | sed -E 's/-[0-9][^-]*-r[0-9]+$//')
                lic=$(awk -v p="$pv " 'index($0, p) == 1' /work/apk.list |
                    sed -n 's/^[^(]*(\(.*\)) \[installed\]$/\1/p')
                printf '%s\tapk:%s\t%s\t%s\t-\n' "$f" "$name" "${pv#"$name"-}" "${lic:-unknown}"
                ;;
        esac
    done < /work/inputs.sorted
}

: "${PKG_VERSION:?}" "${PKG_RELEASE:?}" "${PKG_ARCH:?}" "${PKG_TARGETS:?}"
: "${PKG_SOURCE_REPO:?}" "${PKG_SOURCE_REF:?}" "${PKG_SOURCE_COMMIT:?}"
: "${PKG_SOURCE_TARBALL:?}" "${PKG_SOURCE_TARBALL_SHA256:?}" "${PKG_SOURCE_SIGNATURE:?}" "${PKG_SOURCE_SIGNER:?}"
: "${DEP_LIBSLIRP_VERSION:?}" "${DEP_LIBSLIRP_REPO:?}" "${DEP_LIBSLIRP_REF:?}" "${DEP_LIBSLIRP_COMMIT:?}" "${DEP_LIBSLIRP_ASSET:?}"
: "${DEP_GLIB_VERSION:?}" "${DEP_GLIB_TARBALL:?}" "${DEP_GLIB_TARBALL_SHA256:?}" "${DEP_GLIB_ASSET:?}"
: "${DEP_LIBAIO_VERSION:?}" "${DEP_LIBAIO_REPO:?}" "${DEP_LIBAIO_REF:?}" "${DEP_LIBAIO_COMMIT:?}" "${DEP_LIBAIO_ASSET:?}"
case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "no host $(uname -m)" ;;
esac
[ "$arch" = "$PKG_ARCH" ] || die "the container runs on $arch, not on $PKG_ARCH"

retry apk update
retry apk upgrade
# The build of QEMU; the -static packages give the archives that the
# static link takes. Each of them has a licence with no condition on the
# source (pkg.py linked checks it); glib and libaio (LGPL) come from the
# pinned sources of [[dep]]. The make files of QEMU run bash; glib needs
# libffi, py3-packaging and libintl.h (musl-libintl: musl has the code).
retry apk add bash make meson samurai perl python3 py3-packaging gcc libc-dev \
    musl-libintl pkgconf linux-headers zlib-dev zlib-static ncurses-dev ncurses-static \
    pcre2-dev pcre2-static pixman-dev pixman-static libffi-dev liburing-dev \
    bzip2-dev bzip2-static flex bison
# The tools of this script.
retry apk add binutils curl diffutils file git gpg gpgv gzip tar xz

src=/work/src
dst=/work/dst
tree=$src/qemu-$PKG_VERSION
mkdir -p "$src" "$dst" /out/dist /out/source

# The release tarball: its SHA-256, its signature, and each file of the
# pinned commit in it with the same bytes.
tarball=/out/source/qemu-$PKG_VERSION.tar.xz
retry curl -qfsSL --max-time 900 -o "$tarball" "$PKG_SOURCE_TARBALL"
retry curl -qfsSL --max-time 60 -o "$tarball.sig" "$PKG_SOURCE_SIGNATURE"
echo "$PKG_SOURCE_TARBALL_SHA256  $tarball" | sha256sum -c - > /dev/null ||
    die "$PKG_SOURCE_TARBALL has another SHA-256 than $PKG_SOURCE_TARBALL_SHA256"
gpg --dearmor < "/recipe/keys/$PKG_SOURCE_SIGNER.asc" > /work/signer.gpg
gpgv --status-fd 1 --keyring /work/signer.gpg "$tarball.sig" "$tarball" > /work/gpgv.status ||
    die "the signature of $tarball does not verify"
grep -q "^\[GNUPG:\] VALIDSIG $PKG_SOURCE_SIGNER " /work/gpgv.status ||
    die "the signature of $tarball is not by $PKG_SOURCE_SIGNER"
say "$tarball: SHA-256 and signature of $PKG_SOURCE_SIGNER pass"
tar -xJf "$tarball" -C "$src"
[ -f "$tree/VERSION" ] || die "$tarball has no qemu-$PKG_VERSION/VERSION"
[ "$(cat "$tree/VERSION")" = "$PKG_VERSION" ] || die "$tarball holds the version $(cat "$tree/VERSION")"

fetch "$PKG_SOURCE_REPO" "$PKG_SOURCE_REF" "$PKG_SOURCE_COMMIT" /work/git/qemu
mkdir -p /work/git/tree
git -C /work/git/qemu archive "$PKG_SOURCE_COMMIT" | tar -x -C /work/git/tree
# A file of the tarball that is not in the commit is the source of a
# submodule or a subproject; each file of the commit must be the same.
rc=0
diff -rq --no-dereference /work/git/tree "$tree" > /work/tree.diff || rc=$?
[ "$rc" -le 1 ] || die "diff of the commit and the tarball failed with exit $rc"
if grep -Fv "Only in $tree" /work/tree.diff; then
    die "the tarball and the commit $PKG_SOURCE_COMMIT differ (above)"
fi
SOURCE_DATE_EPOCH=$(git -C /work/git/qemu log -1 --format=%ct)
export SOURCE_DATE_EPOCH
# The generators of QEMU (python) must write the same C on each run: a
# random hash seed changes the order of a set, and with it the code.
PYTHONHASHSEED=0
export PYTHONHASHSEED
rm -rf /work/git
say "each file of $PKG_SOURCE_COMMIT is in the tarball with the same bytes"

# The static libraries of [[dep]], each in /work/deps/NAME. meson fetches
# nothing (--wrap-mode=nodownload): the source asset is all the source.
download "$DEP_GLIB_TARBALL" "$DEP_GLIB_TARBALL_SHA256" "/out/source/$DEP_GLIB_ASSET"
tar -xJf "/out/source/$DEP_GLIB_ASSET" -C "$src"
[ -d "$src/glib-$DEP_GLIB_VERSION" ] || die "$DEP_GLIB_ASSET has no glib-$DEP_GLIB_VERSION/"
# No libmount: then no library of util-linux is in the link. minsize (-Os)
# as the glib of Alpine.
meson setup /work/out/glib "$src/glib-$DEP_GLIB_VERSION" --prefix=/work/deps/glib \
    --libdir=lib --default-library=static --buildtype=minsize --wrap-mode=nodownload \
    -Dtests=false -Dintrospection=disabled -Dlibmount=disabled -Dselinux=disabled \
    -Dxattr=false -Dnls=disabled -Dman-pages=disabled -Ddocumentation=false \
    -Dsysprof=disabled -Dlibelf=disabled
meson compile -C /work/out/glib
meson install -C /work/out/glib
[ -f /work/deps/glib/lib/libglib-2.0.a ] || die "no static libglib-2.0.a"
# libslirp needs glib.
export PKG_CONFIG_PATH=/work/deps/glib/lib/pkgconfig

fetch "$DEP_LIBSLIRP_REPO" "$DEP_LIBSLIRP_REF" "$DEP_LIBSLIRP_COMMIT" "$src/libslirp"
git_source "$src/libslirp" "libslirp-$DEP_LIBSLIRP_VERSION" "$DEP_LIBSLIRP_COMMIT" "/out/source/$DEP_LIBSLIRP_ASSET"
meson setup /work/out/libslirp "$src/libslirp" --prefix=/work/deps/libslirp \
    --libdir=lib --default-library=static --buildtype=release --wrap-mode=nodownload
meson compile -C /work/out/libslirp
meson install -C /work/out/libslirp
[ -f /work/deps/libslirp/lib/libslirp.a ] || die "no static libslirp.a"

fetch "$DEP_LIBAIO_REPO" "$DEP_LIBAIO_REF" "$DEP_LIBAIO_COMMIT" "$src/libaio" full
git_source "$src/libaio" "libaio-$DEP_LIBAIO_VERSION" "$DEP_LIBAIO_COMMIT" "/out/source/$DEP_LIBAIO_ASSET"
make -C "$src/libaio" prefix=/work/deps/libaio install
# Only the static archive: the link must not find a shared one.
rm -f /work/deps/libaio/lib/libaio.so*
[ -f /work/deps/libaio/lib/libaio.a ] || die "no static libaio.a"

export PKG_CONFIG_PATH=/work/deps/libslirp/lib/pkgconfig:/work/deps/glib/lib/pkgconfig
# libaio has no pkg-config file: gcc (and find_library of meson, which
# asks gcc for its search directories) finds it by these.
export C_INCLUDE_PATH=/work/deps/libaio/include LIBRARY_PATH=/work/deps/libaio/lib

find "$tree/subprojects" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > /work/subprojects.before
mkdir -p /work/out/qemu /work/maps
cd /work/out/qemu
"$tree/configure" --prefix="$dst" --target-list="$PKG_TARGETS" --static \
    --disable-debug-info --disable-werror --disable-guest-agent --disable-docs \
    --disable-gtk --disable-sdl --disable-vnc --disable-opengl --enable-curses \
    --disable-spice --disable-pa --disable-jack --disable-oss --disable-alsa \
    --disable-brlapi --disable-dbus-display --enable-linux-aio \
    --enable-linux-io-uring --enable-system --enable-kvm --disable-linux-user \
    --enable-tools --enable-slirp --extra-ldflags=-Wl,-Map=/work/maps/
make -j"$(nproc)"
make -j"$(nproc)" install
cd /

# configure fetches a subproject that the tarball does not hold (dtc:
# Alpine has no static libfdt), at the revision of its wrap file.
find "$tree/subprojects" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > /work/subprojects.after
# A name with a leading dot (.wraplock) is a lock of meson, not a source.
comm -13 /work/subprojects.before /work/subprojects.after | grep -v '^\.' > /work/subprojects.added || true
added=$(cat /work/subprojects.added)
if [ -n "$added" ]; then
    say "configure fetched the subprojects: $(echo "$added" | tr '\n' ' ')"
    set --
    for sp in $added; do
        set -- "$@" "qemu-$PKG_VERSION/subprojects/$sp"
    done
    (cd "$src" && tar_same --exclude=.git -cf - "$@") |
        xz -T1 -9 > "/out/source/qemu-$PKG_VERSION-subprojects.tar.xz"
fi

suffix=$PKG_RELEASE-linux-$PKG_ARCH
version_re=$(echo "$PKG_VERSION" | sed 's/\./\\./g')
for name in qemu-system-x86_64 qemu-system-aarch64 qemu-img; do
    stage=/work/stage/$name
    mkdir -p "$stage/bin"
    cp "$dst/bin/$name" "$stage/bin/$name"
    chmod 0755 "$stage/bin/$name"
    strip "$stage/bin/$name"
    static_elf "$stage/bin/$name"
    file "$stage/bin/$name"
    "$stage/bin/$name" --version | head -1 | grep -Eq "version $version_re([^0-9.]|\$)" ||
        die "$name does not report the version $PKG_VERSION"
    archive "$stage" "/out/dist/$name-$suffix.tar.gz"
done
[ -d "$dst/share/qemu" ] || die "no share/qemu"
mkdir -p /work/stage/data/share
cp -a "$dst/share/qemu" /work/stage/data/share/qemu
archive /work/stage/data "/out/dist/qemu-data-$suffix.tar.gz"

linked_list qemu-system-x86_64 qemu-system-aarch64 qemu-img > "/out/dist/qemu-$suffix.linked.txt"

# Each package of the build, with its version and its licence.
{
    echo "# The packages of Alpine in the build of qemu $PKG_RELEASE on linux-$PKG_ARCH."
    echo "# QEMU $PKG_SOURCE_REF $PKG_SOURCE_COMMIT. The libraries of the link: qemu-$suffix.linked.txt."
    echo "# Each line: package-version arch {origin} (licence) [installed]."
    apk list --installed | sort
} > "/out/dist/qemu-$suffix.components.txt"

[ -z "${PKG_OUT_OWNER:-}" ] || chown -R "$PKG_OUT_OWNER" /out
ls -l /out/dist /out/source
