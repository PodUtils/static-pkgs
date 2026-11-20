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
#   libslirp-VERSION.tar.xz            git archive of the pinned commit
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
fetch() {
    repo=$1 ref=$2 commit=$3 dir=$4
    git init -q "$dir"
    git -C "$dir" remote add origin "$repo"
    retry git -C "$dir" fetch -q --depth=1 origin "refs/tags/$ref:refs/tags/$ref"
    got=$(git -C "$dir" rev-parse "refs/tags/$ref^{commit}")
    [ "$got" = "$commit" ] || die "$ref of $repo is the commit $got, not the pin $commit"
    git -C "$dir" -c advice.detachedHead=false checkout -q "$commit"
    say "$repo $ref is $commit"
}

# The same bytes on each host: sorted names, owner 0, the time of the
# commit, one thread of xz.
TAR_SAME='--sort=name --owner=0 --group=0 --numeric-owner --mode=u+rwX,go+rX,go-w'

# A tar.gz of the directory STAGE (members ./bin/NAME or ./share/qemu/...).
archive() {
    stage=$1 out=$2
    # shellcheck disable=SC2086 # TAR_SAME is a list of options.
    tar -C "$stage" $TAR_SAME --mtime="@$SOURCE_DATE_EPOCH" -cf - . | gzip -n -9 > "$out"
    gzip -t "$out"
    say "asset $out ($(wc -c < "$out") bytes)"
}

# The checks of a static ELF: no program interpreter, no NEEDED entry.
static_elf() {
    readelf -lW "$1" | grep -q 'Requesting program interpreter' && die "$1 asks for a program interpreter"
    readelf -dW "$1" | grep -q '(NEEDED)' && die "$1 has a NEEDED entry"
    return 0
}

: "${PKG_VERSION:?}" "${PKG_RELEASE:?}" "${PKG_ARCH:?}" "${PKG_TARGETS:?}"
: "${PKG_SOURCE_REPO:?}" "${PKG_SOURCE_REF:?}" "${PKG_SOURCE_COMMIT:?}"
: "${PKG_SOURCE_TARBALL:?}" "${PKG_SOURCE_TARBALL_SHA256:?}" "${PKG_SOURCE_SIGNATURE:?}" "${PKG_SOURCE_SIGNER:?}"
: "${DEP_LIBSLIRP_VERSION:?}" "${DEP_LIBSLIRP_REPO:?}" "${DEP_LIBSLIRP_REF:?}" "${DEP_LIBSLIRP_COMMIT:?}"
case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) die "no host $(uname -m)" ;;
esac
[ "$arch" = "$PKG_ARCH" ] || die "the container runs on $arch, not on $PKG_ARCH"

retry apk update
retry apk upgrade
# The build of QEMU; the -static packages give the archives that the
# static link takes. The make files of QEMU run bash.
retry apk add bash make meson samurai perl python3 gcc libc-dev pkgconf \
    linux-headers glib-dev glib-static zlib-dev zlib-static ncurses-dev \
    ncurses-static pcre2-dev pcre2-static pixman-dev pixman-static libaio-dev \
    liburing-dev bzip2-dev bzip2-static util-linux-static flex bison
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
rm -rf /work/git
say "each file of $PKG_SOURCE_COMMIT is in the tarball with the same bytes"

fetch "$DEP_LIBSLIRP_REPO" "$DEP_LIBSLIRP_REF" "$DEP_LIBSLIRP_COMMIT" "$src/libslirp"
git -C "$src/libslirp" archive --prefix="libslirp-$DEP_LIBSLIRP_VERSION/" "$DEP_LIBSLIRP_COMMIT" |
    xz -T1 -9 > "/out/source/libslirp-$DEP_LIBSLIRP_VERSION.tar.xz"
meson setup /work/out/libslirp "$src/libslirp" --prefix=/work/deps/libslirp \
    --libdir=lib --default-library=static --buildtype=release
meson compile -C /work/out/libslirp
meson install -C /work/out/libslirp
[ -f /work/deps/libslirp/lib/libslirp.a ] || die "no static libslirp.a"
export PKG_CONFIG_PATH=/work/deps/libslirp/lib/pkgconfig

find "$tree/subprojects" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > /work/subprojects.before
mkdir -p /work/out/qemu
cd /work/out/qemu
"$tree/configure" --prefix="$dst" --target-list="$PKG_TARGETS" --static \
    --disable-debug-info --disable-werror --disable-guest-agent --disable-docs \
    --disable-gtk --disable-sdl --disable-vnc --disable-opengl --enable-curses \
    --disable-spice --disable-pa --disable-jack --disable-oss --disable-alsa \
    --disable-brlapi --disable-dbus-display --enable-linux-aio \
    --enable-linux-io-uring --enable-system --enable-kvm --disable-linux-user \
    --enable-tools --enable-slirp
make -j"$(nproc)"
make -j"$(nproc)" install
cd /

# configure fetches a subproject that the tarball does not hold (dtc:
# Alpine has no static libfdt), at the revision of its wrap file.
find "$tree/subprojects" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > /work/subprojects.after
# A name with a leading dot (.wraplock) is a lock of meson, not a source.
added=$(comm -13 /work/subprojects.before /work/subprojects.after | grep -v '^\.' || true)
if [ -n "$added" ]; then
    say "configure fetched the subprojects: $(echo "$added" | tr '\n' ' ')"
    # shellcheck disable=SC2086 # TAR_SAME is a list of options; added is a list of names.
    (cd "$src" && tar $TAR_SAME --mtime="@$SOURCE_DATE_EPOCH" --exclude=.git -cf - \
        $(echo "$added" | sed "s|^|qemu-$PKG_VERSION/subprojects/|")) |
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

# Each package of the build, with its version and its licence.
{
    echo "# The packages of Alpine in the build of qemu $PKG_RELEASE on linux-$PKG_ARCH."
    echo "# QEMU $PKG_SOURCE_REF $PKG_SOURCE_COMMIT; libslirp $DEP_LIBSLIRP_REF $DEP_LIBSLIRP_COMMIT."
    echo "# Each line: package-version arch {origin} (licence) [installed]."
    apk list --installed | sort
} > "/out/dist/qemu-$suffix.components.txt"

[ -z "${PKG_OUT_OWNER:-}" ] || chown -R "$PKG_OUT_OWNER" /out
ls -l /out/dist /out/source
