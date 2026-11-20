#!/bin/sh
# Put the outputs of each host of a build into the assets of one release.
#
#   sh scripts/assemble.sh NAME RELEASE INDIR OUTDIR NOTES
#
# INDIR holds one directory out-ARCH for each host of pkgs/NAME/pkg.toml,
# each with dist/ and source/ (scripts/build.sh). OUTDIR gets each file of
# each dist/, the files of source/ (the same bytes on each host, else exit
# 1), and SHA256SUMS of them all. NOTES gets the body of the release.
# COMMIT (the commit of this repository) and REPO (OWNER/NAME) go into the
# notes; GITHUB_SHA and GITHUB_REPOSITORY are their defaults.
set -eu
[ "$#" -eq 5 ] || { echo "usage: assemble.sh NAME RELEASE INDIR OUTDIR NOTES" >&2; exit 2; }
name=$1 release=$2 in=$3 out=$4 notes=$5
root=$(cd "$(dirname "$0")/.." && pwd)
pkgdir=$root/pkgs/$name
commit=${COMMIT:-${GITHUB_SHA:-}}
repo=${REPO:-${GITHUB_REPOSITORY:-PodUtils/static-pkgs}}
[ -n "$commit" ] || commit=$(git -C "$root" rev-parse HEAD)
pkg() { python3 -I "$root/scripts/pkg.py" "$@"; }
die() { echo "assemble: $*" >&2; exit 1; }

tag=$(pkg release "$pkgdir" "$release")
hosts=$(pkg get "$pkgdir" hosts)
mkdir -p "$out"
[ -z "$(find "$out" -mindepth 1 -maxdepth 1)" ] || die "$out is not empty"
first=
for h in $hosts; do
    d=$in/out-$h
    if [ ! -d "$d/dist" ] || [ ! -d "$d/source" ]; then die "no build of $h in $d"; fi
    for f in "$d"/dist/*; do
        b=$(basename "$f")
        case $b in *-linux-"$h".*) ;; *) die "$f does not name the host $h" ;; esac
        [ ! -e "$out/$b" ] || die "two files $b"
        cp "$f" "$out/$b"
    done
    if [ -z "$first" ]; then
        first=$h
        cp "$d"/source/* "$out/"
    else
        a=$(cd "$in/out-$first/source" && sha256sum -- *)
        b=$(cd "$d/source" && sha256sum -- *)
        [ "$a" = "$b" ] || die "the source of $h is not the source of $first: $(echo; echo "$a"; echo "$b")"
    fi
done
(cd "$out" && sha256sum -- * > "$out/SHA256SUMS.new" && mv "$out/SHA256SUMS.new" "$out/SHA256SUMS")
cat "$out/SHA256SUMS"

summary=$(pkg get "$pkgdir" summary)
licence=$(pkg get "$pkgdir" licence)
note=$(pkg get "$pkgdir" licence-note 2>/dev/null || true)
{
    echo "$summary."
    echo
    echo "- Upstream: $(pkg get "$pkgdir" source.repo) $(pkg get "$pkgdir" source.ref), commit \`$(pkg get "$pkgdir" source.commit)\`."
    if pkg get "$pkgdir" source.tarball > /dev/null 2>&1; then
        echo "- Release tarball: $(pkg get "$pkgdir" source.tarball), SHA-256 \`$(pkg get "$pkgdir" source.tarball-sha256)\`, signed by \`$(pkg get "$pkgdir" source.signer)\`."
    fi
    python3 -I - "$pkgdir/pkg.toml" <<'EOF'
import sys
import tomllib

with open(sys.argv[1], "rb") as f:
    p = tomllib.load(f)
for d in p.get("dep", []):
    print(f"- Part: {d['name']} {d['version']} ({d['licence']}), {d['repo']} {d['ref']}, commit `{d['commit']}`.")
EOF
    echo "- Build image: \`$(pkg get "$pkgdir" build.image)\`."
    echo "- Recipe: https://github.com/$repo/tree/$commit/pkgs/$name"
    echo "- Licence: $licence. ${note}"
    echo
    echo "Each file and its SHA-256:"
    echo
    echo '```'
    cat "$out/SHA256SUMS"
    echo '```'
    echo
    echo "Check a file: \`sha256sum -c --ignore-missing SHA256SUMS\` and \`gh attestation verify FILE --repo $repo\`."
    echo "The files \`*.tar.xz\` and \`*.sig\` are the source of each part of the binaries. Release: \`$tag\`."
} > "$notes"
