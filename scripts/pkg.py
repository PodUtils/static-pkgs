#!/usr/bin/env python3
"""Read and check the file pkgs/NAME/pkg.toml of a package.

  python3 -I scripts/pkg.py check [PKGDIR...]
  python3 -I scripts/pkg.py get PKGDIR KEY
  python3 -I scripts/pkg.py release PKGDIR RELEASE
  python3 -I scripts/pkg.py matrix PKGDIR
  python3 -I scripts/pkg.py env PKGDIR RELEASE ARCH

check: the rules of each pkg.toml (all of pkgs/ when no PKGDIR is given).
get: one value; KEY is a dotted path (build.image). A list gives one line
for each item.
release: RELEASE is VERSION or VERSION.N (a rebuild, N >= 1) of the
package; print the tag NAME-RELEASE.
matrix: the JSON of the hosts for a matrix of GitHub Actions.
env: the lines KEY=VALUE (a file of `docker run --env-file`, and shell
words: each value has only safe characters) that scripts/build.sh gives to
the container: PKG_NAME, PKG_VERSION, PKG_RELEASE, PKG_ARCH, PKG_TARGETS,
PKG_SOURCE_REPO, PKG_SOURCE_REF, PKG_SOURCE_COMMIT, PKG_SOURCE_TARBALL,
PKG_SOURCE_TARBALL_SHA256, PKG_SOURCE_SIGNATURE and PKG_SOURCE_SIGNER when
[source] has them, and for each [[dep]] DEP_NAME_VERSION, DEP_NAME_REPO,
DEP_NAME_REF, DEP_NAME_COMMIT.

Exit 1 with one line for each fault, 2 for a usage error or a file that
cannot be read.
"""

import json
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOSTS = {"amd64", "arm64"}
NAME = re.compile(r"^[a-z0-9][a-z0-9-]*$")
VERSION = re.compile(r"^[0-9]+(\.[0-9]+)*$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
IMAGE = re.compile(r"^[a-z0-9.-]+(/[a-z0-9._-]+)+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$")
# The characters of a value that goes into a shell line or an asset name.
SAFE = re.compile(r"^[A-Za-z0-9._,:/@+-]*$")
# The optional keys of [source] for a release tarball of upstream.
SOURCE_EXTRA = ("tarball", "tarball-sha256", "signature", "signer")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
FPR = re.compile(r"^[0-9A-F]{40}$")


class Usage(Exception):
    pass


def load(pkgdir: Path) -> dict:
    try:
        with open(pkgdir / "pkg.toml", "rb") as f:
            return tomllib.load(f)
    except (OSError, tomllib.TOMLDecodeError) as e:
        raise Usage(f"{pkgdir / 'pkg.toml'}: {e}") from e


def faults(pkgdir: Path) -> list[str]:
    p = load(pkgdir)
    where = pkgdir / "pkg.toml"
    out = []

    def need(table: dict, key: str, rule: re.Pattern | None, label: str) -> None:
        value = table.get(key)
        if not isinstance(value, str) or not value:
            out.append(f"{where}: {label}{key} is missing")
        elif rule is not None and not rule.match(value):
            out.append(f"{where}: {label}{key} = {value!r} has not the form {rule.pattern}")

    need(p, "name", NAME, "")
    if p.get("name") != pkgdir.name:
        out.append(f"{where}: name {p.get('name')!r} is not the name of the directory {pkgdir.name!r}")
    need(p, "version", VERSION, "")
    need(p, "summary", None, "")
    need(p, "licence", None, "")
    hosts = p.get("hosts")
    if not isinstance(hosts, list) or not hosts or not set(hosts) <= HOSTS or len(set(hosts)) != len(hosts):
        out.append(f"{where}: hosts must be a list of distinct items of {sorted(HOSTS)}")
    targets = p.get("targets", [])
    if not isinstance(targets, list) or not all(isinstance(t, str) and SAFE.match(t) and "," not in t for t in targets):
        out.append(f"{where}: targets must be a list of plain words")
    source = p.get("source")
    if not isinstance(source, dict):
        out.append(f"{where}: [source] is missing")
    else:
        need(source, "repo", re.compile(r"^https://\S+$"), "source.")
        need(source, "ref", None, "source.")
        need(source, "commit", COMMIT, "source.")
        if "tarball" in source:
            need(source, "tarball", re.compile(r"^https://\S+$"), "source.")
            need(source, "tarball-sha256", SHA256, "source.")
        if "signature" in source:
            need(source, "signature", re.compile(r"^https://\S+$"), "source.")
            need(source, "signer", FPR, "source.")
            if FPR.match(str(source.get("signer", ""))) and not (pkgdir / "keys" / f"{source['signer']}.asc").is_file():
                out.append(f"{where}: no key keys/{source['signer']}.asc for source.signer")
    build = p.get("build")
    if not isinstance(build, dict):
        out.append(f"{where}: [build] is missing")
    else:
        need(build, "image", IMAGE, "build.")
        need(build, "script", None, "build.")
        need(build, "check", None, "build.")
        for key in ("script", "check"):
            if key in build and not (pkgdir / str(build[key])).is_file():
                out.append(f"{where}: build.{key} {build[key]!r} is not a file of {pkgdir}")
    seen = set()
    for i, dep in enumerate(p.get("dep", [])):
        label = f"dep[{i}]."
        need(dep, "name", NAME, label)
        need(dep, "version", VERSION, label)
        need(dep, "repo", re.compile(r"^https://\S+$"), label)
        need(dep, "ref", None, label)
        need(dep, "commit", COMMIT, label)
        need(dep, "licence", None, label)
        if dep.get("name") in seen:
            out.append(f"{where}: dep {dep.get('name')!r} is given twice")
        seen.add(dep.get("name"))
    # Each value that goes to the shell of the container.
    for key, value in flat(p):
        if not SAFE.match(value):
            out.append(f"{where}: the value of {key} has a character that is not safe in a shell word")
    return out


def flat(p: dict) -> list[tuple[str, str]]:
    """The values of the package that the container gets."""
    pairs = [("PKG_NAME", p.get("name", "")), ("PKG_VERSION", p.get("version", "")),
             ("PKG_TARGETS", ",".join(p.get("targets", [])))]
    source = p.get("source", {})
    for key in ("repo", "ref", "commit"):
        pairs.append((f"PKG_SOURCE_{key.upper()}", str(source.get(key, ""))))
    for key in SOURCE_EXTRA:
        if key in source:
            pairs.append((f"PKG_SOURCE_{key.upper().replace('-', '_')}", str(source[key])))
    for dep in p.get("dep", []):
        prefix = "DEP_" + str(dep.get("name", "")).upper().replace("-", "_")
        for key in ("version", "repo", "ref", "commit"):
            pairs.append((f"{prefix}_{key.upper()}", str(dep.get(key, ""))))
    return pairs


def release(p: dict, value: str) -> str:
    version = p["version"]
    if value != version:
        rest = value.removeprefix(version + ".")
        if rest == value or not re.fullmatch(r"[1-9][0-9]*", rest):
            raise Usage(f"release {value!r} is not {version} or {version}.N with N >= 1")
    return f"{p['name']}-{value}"


def get(p: dict, key: str) -> list[str]:
    value = p
    for part in key.split("."):
        if not isinstance(value, dict) or part not in value:
            raise Usage(f"no key {key}")
        value = value[part]
    if isinstance(value, list):
        return [str(v) for v in value]
    if isinstance(value, dict):
        raise Usage(f"{key} is a table")
    return [str(value)]


def main(argv: list[str]) -> int:
    if not argv:
        raise Usage(__doc__.strip().splitlines()[2])
    cmd, args = argv[0], argv[1:]
    if cmd == "check":
        pkgs = ROOT / "pkgs"
        dirs = [Path(a) for a in args] or sorted(d for d in pkgs.glob("*") if d.is_dir())
        found = []
        for d in dirs:
            found += faults(d)
        for fault in found:
            print(fault)
        print(f"pkg: {len(dirs)} packages, {len(found)} faults")
        return 1 if found else 0
    if not args:
        raise Usage(f"{cmd}: no PKGDIR")
    pkgdir = Path(args[0])
    bad = faults(pkgdir)
    if bad:
        for fault in bad:
            print(fault, file=sys.stderr)
        return 1
    p = load(pkgdir)
    if cmd == "get" and len(args) == 2:
        print("\n".join(get(p, args[1])))
    elif cmd == "release" and len(args) == 2:
        print(release(p, args[1]))
    elif cmd == "matrix" and len(args) == 1:
        runners = {"amd64": "ubuntu-24.04", "arm64": "ubuntu-24.04-arm"}
        print(json.dumps({"include": [{"arch": h, "runner": runners[h]} for h in p["hosts"]]}))
    elif cmd == "env" and len(args) == 3:
        release(p, args[1])
        if args[2] not in p["hosts"]:
            raise Usage(f"arch {args[2]!r} is not a host of {p['name']}: {p['hosts']}")
        pairs = flat(p) + [("PKG_RELEASE", args[1]), ("PKG_ARCH", args[2])]
        for key, value in pairs:
            if not SAFE.match(value):
                raise Usage(f"the value of {key} is not safe in a shell word")
            print(f"{key}={value}")
    else:
        raise Usage(f"unknown command or arguments: {' '.join(argv)}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Usage as e:
        print(f"pkg: {e}", file=sys.stderr)
        sys.exit(2)
