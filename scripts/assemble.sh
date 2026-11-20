#!/bin/sh
# Put the outputs of each host of a build into the assets of one release.
#
#   sh scripts/assemble.sh NAME RELEASE INDIR OUTDIR NOTES
#
# INDIR holds one directory out-ARCH for each host of pkgs/NAME/pkg.toml,
# each with dist/ and source/ (scripts/build.sh). OUTDIR gets each file of
# each dist/, the files of source/ (the same bytes on each host, else exit
# 1), and SHA256SUMS of them all. NOTES gets the body of the release.
# It fails when a source asset of `scripts/pkg.py sources` is missing, when
# a source file is not one of them, and when a file of a static link
# (NAME-RELEASE-linux-ARCH.linked.txt) has a copyleft licence and no source
# asset (`scripts/pkg.py linked`).
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
pkg sources "$pkgdir" > "$out/.sources"
while IFS="$(printf '\t')" read -r part asset; do
    [ -f "$out/$asset" ] || die "no source asset $asset of $part"
done < "$out/.sources"
for f in "$in/out-$first"/source/*; do
    b=$(basename "$f")
    cut -f 2 "$out/.sources" | grep -qxF "$b" || die "the source file $b is not a source asset of pkg.toml"
done
n=0
for f in "$out"/*.linked.txt; do
    [ -f "$f" ] || continue
    pkg linked "$pkgdir" "$f" "$out"
    n=$((n + 1))
done
[ "$n" -gt 0 ] || die "no list of the static link (*.linked.txt)"
mv "$out/.sources" "$out.sources"
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
    if "tarball" in d:
        where = f"{d['tarball']}, SHA-256 `{d['tarball-sha256']}`"
    else:
        where = f"{d['repo']} {d['ref']}, commit `{d['commit']}`"
    print(f"- Part: {d['name']} {d['version']} ({d['licence']}), {where}.")
EOF
    echo "- Build image: \`$(pkg get "$pkgdir" build.image)\`."
    echo "- Recipe: https://github.com/$repo/tree/$commit/pkgs/$name"
    echo "- Licence: $licence. ${note}"
    echo
    echo "The source of each part (the files \`*.tar.*\` and \`*.sig\` of this release):"
    echo
    while IFS="$(printf '\t')" read -r part asset; do
        echo "- $part: \`$asset\`"
    done < "$out.sources"
    echo
    echo "The files \`*.linked.txt\` give each input file of the static link, its owner, its licence and its source asset."
    echo
    echo "Each file and its SHA-256:"
    echo
    echo '```'
    cat "$out/SHA256SUMS"
    echo '```'
    echo
    echo "Check a file: \`sha256sum -c --ignore-missing SHA256SUMS\` and \`gh attestation verify FILE --repo $repo\`."
    echo "Release: \`$tag\`."
} > "$notes"
rm -f "$out.sources"
