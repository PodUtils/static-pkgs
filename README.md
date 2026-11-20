# static-pkgs

Static binaries and packages for the projects of PodUtils. Each package
has a recipe in `pkgs/NAME/`. A workflow builds it in a container that is
pinned by digest, checks that each binary is static, and publishes a
GitHub release with the binaries, the exact source of each part, the
SHA-256 of each file and the build provenance.

## Packages

| Package | Version | Hosts | Contents | Licence |
| --- | --- | --- | --- | --- |
| [qemu](pkgs/qemu/README.md) | 11.1.3 | linux-amd64, linux-arm64 | `qemu-system-x86_64`, `qemu-system-aarch64`, `qemu-img`, `share/qemu` | GPL-2.0-only (recipe: MIT) |

## Releases

A release is the tag `NAME-VERSION`, or `NAME-VERSION.N` (N >= 1) for a
rebuild of the same version. A release never changes. Its files:

* `PART-RELEASE-linux-ARCH.tar.gz`: one archive for each part and host,
  with the installed layout (`./bin/NAME`, `./share/...`).
* `NAME-RELEASE-linux-ARCH.components.txt`: each package of the build
  container, with its version and its licence.
* `*.tar.xz` and `*.sig`: the source of each part of the binaries.
* `SHA256SUMS`: the SHA-256 of each file above.
* `NAME-RELEASE.attestation.jsonl`: the build provenance (SLSA) of each
  file of `SHA256SUMS`, signed for `release.yml` of this repository.

## Pin an asset

A consumer pins the URL and the SHA-256 of each asset, and checks the
SHA-256 before it uses a byte:

```sh
url=https://github.com/PodUtils/static-pkgs/releases/download/qemu-11.1.3/qemu-img-11.1.3-linux-amd64.tar.gz
sum=SHA256_FROM_SHA256SUMS
curl -qfsSL -o qemu-img.tar.gz "$url"
echo "$sum  qemu-img.tar.gz" | sha256sum -c -
tar -xzf qemu-img.tar.gz ./bin/qemu-img
```

Read the SHA-256 from `SHA256SUMS` of the release once, check the
provenance once, and write the value into the pin of the consumer:

```sh
gh release download qemu-11.1.3 -R PodUtils/static-pkgs -p SHA256SUMS -p 'qemu-img-*'
sha256sum -c --ignore-missing SHA256SUMS
gh attestation verify qemu-img-11.1.3-linux-amd64.tar.gz -R PodUtils/static-pkgs
```

## Layout

```text
pkgs/NAME/pkg.toml     the pins: upstream (repo, ref, commit, tarball,
                       SHA-256, signer), the parts, the image by digest,
                       the hosts, the licences
pkgs/NAME/build.sh     the build in the container (build.script)
pkgs/NAME/check.sh     the checks of the assets on the host (build.check)
pkgs/NAME/README.md    the notes of the package
pkgs/NAME/keys/        the public keys of the signers of upstream
scripts/pkg.py         reads and checks each pkg.toml
scripts/build.sh       runs build.script in the pinned container
scripts/assemble.sh    the assets of each host, SHA256SUMS, the notes
.github/workflows/     release.yml (build and publish), lint.yml
```

The container gets `pkgs/NAME/` read-only at `/recipe`, an empty `/out`,
and the values of `python3 -I scripts/pkg.py env pkgs/NAME RELEASE ARCH`.
It writes the assets of its host to `/out/dist` and the source to
`/out/source`.

## Build and publish

Build and check, publish nothing (a dry run):

```sh
gh workflow run release.yml -R PodUtils/static-pkgs -f package=qemu -f release=11.1.3 -f dry_run=true
```

Publish the release `qemu-11.1.3` (from `main` only):

```sh
gh workflow run release.yml -R PodUtils/static-pkgs -f package=qemu -f release=11.1.3 -f dry_run=false
```

Build locally (Docker on a host of the package):

```sh
sh scripts/build.sh qemu 11.1.3 amd64 out/qemu-amd64
CHECK_STATIC=PATH/TO/podcrates/scripts/check-static.sh \
  sh pkgs/qemu/check.sh out/qemu-amd64/dist 11.1.3 amd64
```

## Licence

The files of this repository are 0BSD (`LICENSE`). Each package keeps its
own licence, and a recipe from another project keeps its notice
(`pkgs/NAME/README.md`).
