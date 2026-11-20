# qemu

QEMU 11.1.3, static-pie with musl, for a Linux host (amd64, arm64). It is
the emulator of podvm's guests: QEMU 11.1.0 and later can migrate an NVMe
disk (upstream commit `9d378cab537d`, "hw/nvme: add basic live migration
support"), which a warm start of a guest with its root disk on NVMe needs.

## Assets

For each host ARCH (`amd64`, `arm64`) and release RELEASE (`11.1.3`, or
`11.1.3.N` for a rebuild):

| Asset | Member |
| --- | --- |
| `qemu-system-x86_64-RELEASE-linux-ARCH.tar.gz` | `./bin/qemu-system-x86_64` |
| `qemu-system-aarch64-RELEASE-linux-ARCH.tar.gz` | `./bin/qemu-system-aarch64` |
| `qemu-img-RELEASE-linux-ARCH.tar.gz` | `./bin/qemu-img` |
| `qemu-data-RELEASE-linux-ARCH.tar.gz` | `./share/qemu/...` (SeaBIOS, edk2, the option ROMs, the keymaps) |
| `qemu-RELEASE-linux-ARCH.components.txt` | each package of Alpine in the build, its version and licence |
| `qemu-RELEASE-linux-ARCH.linked.txt` | each input file of the static link of the three binaries, its owner, its licence and its source asset |

Unpack the binary archives and the data archive into one directory: each
emulator finds its data at `bin/../share/qemu` with no `-L`.

The source, one copy for all hosts:

| Asset | Contents |
| --- | --- |
| `qemu-11.1.3.tar.xz`, `qemu-11.1.3.tar.xz.sig` | the release tarball of upstream with its signature: QEMU, the source of the firmware (`roms/`) and of the subprojects |
| `qemu-11.1.3-subprojects.tar.xz` | the subprojects that configure fetched at the revision of their wrap file (`dtc`) |
| `libslirp-4.9.7.tar.xz` | `git archive` of the pinned commit of libslirp (BSD-3-Clause) |
| `glib-2.88.4.tar.xz` | the release tarball of glib (LGPL-2.1-or-later) |
| `libaio-0.3.113.tar.xz` | `git archive` of the pinned commit of libaio (LGPL-2.1-or-later) |

## Build

`build.sh` runs in `alpine:3.24.4` (pinned by digest in `pkg.toml`):

1. It installs the build packages, with the `-static` packages of the
   libraries.
2. It downloads the release tarball, and checks its SHA-256 and its
   signature by `CEACC9E15534EBABB82D3FA03353C9CEF108B584` (the release
   key of QEMU, `keys/`).
3. It fetches the tag `v11.1.3`, checks that it is the commit
   `005c61c0ef6f6ae615283440b4bb7be51b2c6ddd`, and checks that each file
   of the commit is in the tarball with the same bytes.
4. It builds the static libraries of `[[dep]]` from their pinned sources,
   and makes their source assets: libslirp v4.9.7 (commit
   `ce12dcddf710a71dc0de6450ec95edbadf8e9f66`), glib 2.88.4 (the tarball
   by its SHA-256, with no libmount) and libaio 0.3.113 (commit
   `1b18bfafc6a2f7b9fa2c6be77a95afed8b7be448`). meson downloads nothing
   (`--wrap-mode=nodownload`).
5. It configures QEMU with `--static`, the targets `x86_64-softmmu` and
   `aarch64-softmmu`, KVM, curses, linux-aio, io_uring, slirp and the
   tools, and with no GUI, audio, VNC, SPICE, docs or guest agent.
6. It strips each binary, checks that it is static and that it reports
   the version 11.1.3, and writes the archives.
7. It reads the map that GNU ld writes for the link of each binary
   (`-Wl,-Map=DIR/`), and writes `linked.txt`: each object file and
   archive that ld loads, with its owner (QEMU, a `[[dep]]` or a package of
   Alpine), its licence and its source asset. A file with no owner stops
   the build.

`PYTHONHASHSEED=0` keeps the C that the generators of QEMU write the same
on each run.

`check.sh` runs on the runner after the build: the member of each
archive, `check-static.sh` of podcrates on each binary, `--version`, KVM
in `-accel help` of the emulator of the host, a boot of each emulator
with the firmware of the data archive (SeaBIOS on `q35`, edk2 on `virt`),
and `scripts/pkg.py linked` on `linked.txt` (below).

## The source of the copyleft libraries

The binaries link glib and libaio, which are LGPL-2.1-or-later. The build
compiles both from pinned upstream sources (`[[dep]]` of `pkg.toml`), and
each release carries each source as an asset. The reason: the repository
of Alpine keeps only the newest build of a package, so a pin of the
version of an Alpine package breaks at its next update, and the source of
an earlier build is not always available. A pinned upstream source gives
the same input on each run and the exact source of the link. glib builds
with no libmount, so no library of util-linux (libmount, libblkid) is in
the link.

`scripts/pkg.py linked` reads `linked.txt` and fails when a file of the
link has a copyleft licence (GPL, LGPL, MPL and the like; an `OR` with a
licence that is not copyleft passes) and no source asset. The workflow
runs it on each host and again on the assets of the release. The files of
Alpine that stay in the link have licences with no condition on the
source: musl (MIT), zlib, pcre2 (BSD-3-Clause), libffi (MIT), pixman
(MIT), ncurses (X11), bzip2, liburing (LGPL-2.1-or-later OR MIT: the MIT
choice). The one exception is GCC (`libgcc.a`, `libgcc_eh.a`,
`libatomic.a`, the crt objects): the GCC Runtime Library Exception 3.1
allows a static link with no condition on the source (`[[exception]]` of
`pkg.toml`).

## Licence

QEMU is GPL-2.0-only as a whole; some parts are GPL-2.0-or-later,
LGPL-2.1-or-later, BSD or MIT (`LICENSE` and `COPYING` in the source).
libslirp is BSD-3-Clause; glib and libaio are LGPL-2.1-or-later. The
binaries also link static libraries of Alpine with no condition on the
source (above); `linked.txt` of each release gives each file of the link
and its licence.

The recipe comes from
[hermeticbuild/qemu-prebuilt](https://github.com/hermeticbuild/qemu-prebuilt)
at commit `7305686b06baead290ea0f1a22735fb5c0944da9` (MIT): its
`Dockerfile`, `build` and `tools/package-qemu-artifacts.sh`. The changes:
POSIX `sh` in one container run, the pins of `pkg.toml`, the checks of the
source, only the targets and binaries above, and the source assets.
`LICENSE.hermeticbuild` keeps its notice, as its licence asks.
