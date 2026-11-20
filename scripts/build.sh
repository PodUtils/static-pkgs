#!/bin/sh
# Build the package NAME for the host ARCH in its pinned container.
#
#   sh scripts/build.sh NAME RELEASE ARCH OUTDIR
#
# RELEASE is the version of pkgs/NAME/pkg.toml, or VERSION.N for a
# rebuild. The container (build.image, pinned by digest) runs
# pkgs/NAME/<build.script> with pkgs/NAME read-only at /recipe and OUTDIR
# at /out, and the values of `scripts/pkg.py env`. The assets go to
# OUTDIR/dist, the source archives to OUTDIR/source.
#
# STATIC_PKGS_DOCKER_ARGS: more words for `docker run`, split at blanks
# (for example the proxy of a local build). Do not put a credential in it:
# docker shows its arguments to each user of the host.
#
# Exit 2 for a usage error; else the exit code of the failed step.
set -eu
[ "$#" -eq 4 ] || { echo "usage: build.sh NAME RELEASE ARCH OUTDIR" >&2; exit 2; }
name=$1 release=$2 arch=$3 out=$4
root=$(cd "$(dirname "$0")/.." && pwd)
pkgdir=$root/pkgs/$name
[ -f "$pkgdir/pkg.toml" ] || { echo "build: no package $name ($pkgdir/pkg.toml)" >&2; exit 2; }
pkg() { python3 -I "$root/scripts/pkg.py" "$@"; }

image=$(pkg get "$pkgdir" build.image)
script=$(pkg get "$pkgdir" build.script)
mkdir -p "$out"
out=$(cd "$out" && pwd)
[ -z "$(find "$out" -mindepth 1 -maxdepth 1)" ] || { echo "build: $out is not empty" >&2; exit 2; }
envfile=$out/.env
pkg env "$pkgdir" "$release" "$arch" > "$envfile"
echo "PKG_OUT_OWNER=$(id -u):$(id -g)" >> "$envfile"
echo "build: $name $release for linux/$arch in $image"
sed 's/^/build: /' "$envfile"

# shellcheck disable=SC2086 # STATIC_PKGS_DOCKER_ARGS is a list of words.
docker run --rm --platform "linux/$arch" --env-file "$envfile" \
    -v "$pkgdir:/recipe:ro" -v "$out:/out" ${STATIC_PKGS_DOCKER_ARGS:-} \
    "$image" /bin/sh "/recipe/$script"
rm -f "$envfile"
ls -l "$out/dist" "$out/source"
