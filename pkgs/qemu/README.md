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

Unpack the binary archives and the data archive into one directory: each
emulator finds its data at `bin/../share/qemu` with no `-L`.

The source, one copy for all hosts:

| Asset | Contents |
| --- | --- |
| `qemu-11.1.3.tar.xz`, `qemu-11.1.3.tar.xz.sig` | the release tarball of upstream with its signature: QEMU, the source of the firmware (`roms/`) and of the subprojects |
| `qemu-11.1.3-subprojects.tar.xz` | the subprojects that configure fetched at the revision of their wrap file (`dtc`) |
| `libslirp-4.9.7.tar.xz` | `git archive` of the pinned commit of libslirp |

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
4. It builds libslirp v4.9.7 (commit
   `ce12dcddf710a71dc0de6450ec95edbadf8e9f66`) as a static library.
5. It configures QEMU with `--static`, the targets `x86_64-softmmu` and
   `aarch64-softmmu`, KVM, curses, linux-aio, io_uring, slirp and the
   tools, and with no GUI, audio, VNC, SPICE, docs or guest agent.
6. It strips each binary, checks that it is static and that it reports
   the version 11.1.3, and writes the archives.

`check.sh` runs on the runner after the build: the member of each
archive, `check-static.sh` of podcrates on each binary, `--version`, KVM
in `-accel help` of the emulator of the host, and a boot of each emulator
with the firmware of the data archive (SeaBIOS on `q35`, edk2 on `virt`).

## Licence

QEMU is GPL-2.0-only as a whole; some parts are GPL-2.0-or-later,
LGPL-2.1-or-later, BSD or MIT (`LICENSE` and `COPYING` in the source).
libslirp is BSD-3-Clause. The binaries also link the static libraries of
Alpine (glib, pixman, zlib, ncurses, pcre2, bzip2, libaio, liburing,
util-linux, musl); the components file of each release gives the licence
of each one.

The recipe comes from
[hermeticbuild/qemu-prebuilt](https://github.com/hermeticbuild/qemu-prebuilt)
at commit `7305686b06baead290ea0f1a22735fb5c0944da9` (MIT): its
`Dockerfile`, `build` and `tools/package-qemu-artifacts.sh`. The changes:
POSIX `sh` in one container run, the pins of `pkg.toml`, the checks of the
source, only the targets and binaries above, and the source assets.
`LICENSE.hermeticbuild` keeps its notice, as its licence asks.
