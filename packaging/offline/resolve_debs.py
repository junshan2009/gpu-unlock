#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Download the .deb closure a target machine needs, without touching it.

apt can only resolve dependencies for the machine it runs on, and the bundle
is fetched elsewhere: a different release, a different architecture, or a
laptop that is not Debian at all. So this walks the distribution's own
Packages indexes, honours the versions the target already has (from
check_env.sh's INSTALLED: lines) and downloads exactly what is missing.

    python3 resolve_debs.py --report gpu-unlock-env.txt --out debs \\
        --want dkms linux-headers-6.8.0-45-generic

Stdlib only. The indexes are cached, so a rerun is cheap.
"""
from __future__ import annotations

import argparse
from functools import cmp_to_key
import gzip
import hashlib
import lzma
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

# Mirrors per distribution family. Ubuntu serves amd64 and i386 from the main
# archive and everything else from ports; security lives on its own host.
# Ubuntu folds Architecture: all into each binary-<arch> index and has no
# contrib or non-free, Debian keeps binary-all separate and has no restricted
# or multiverse, so the component and index lists differ.
MIRRORS = {
    "ubuntu": {
        "archive": {
            "amd64": "http://archive.ubuntu.com/ubuntu",
            "i386": "http://archive.ubuntu.com/ubuntu",
            "*": "http://ports.ubuntu.com/ubuntu-ports",
        },
        "security": {"*": "http://security.ubuntu.com/ubuntu"},
        "suites": ["{c}", "{c}-updates", "{c}-security", "{c}-backports"],
        "components": ("main", "restricted", "universe", "multiverse"),
        "binaries": ("binary-{a}",),
    },
    "debian": {
        "archive": {"*": "http://deb.debian.org/debian"},
        "security": {"*": "http://deb.debian.org/debian-security"},
        "suites": ["{c}", "{c}-updates", "{c}-security"],
        "components": ("main", "contrib", "non-free", "non-free-firmware"),
        "binaries": ("binary-{a}", "binary-all"),
    },
}
# Fields worth keeping out of a Packages file; the rest is bulk. Breaks and
# Conflicts matter because a newer package can refuse to be installed next to
# an older one the target already has, which dpkg then reports as a breakage
# only on the offline machine.
FIELDS = ("Package", "Version", "Architecture", "Depends", "Pre-Depends",
          "Provides", "Breaks", "Conflicts", "Filename", "Size", "SHA256",
          "Multi-Arch")
UA = "gpu-unlock-offline/1.0"


def die(message: str) -> "NoReturn":  # noqa: F821
    raise SystemExit(f"resolve_debs: {message}")


# --- Debian version ordering, as dpkg's verrevcmp -------------------------
def _order(char: str) -> int:
    if not char or char == "\0":
        return 0
    if char == "~":
        return -1
    if char.isdigit():
        return 0
    if char.isalpha():
        return ord(char)
    return ord(char) + 256


def _verrevcmp(a: str, b: str) -> int:
    i = j = 0
    while i < len(a) or j < len(b):
        while (i < len(a) and not a[i].isdigit()) or (j < len(b) and not b[j].isdigit()):
            ac = _order(a[i] if i < len(a) else "")
            bc = _order(b[j] if j < len(b) else "")
            if ac != bc:
                return -1 if ac < bc else 1
            i += 1
            j += 1
        while i < len(a) and a[i] == "0":
            i += 1
        while j < len(b) and b[j] == "0":
            j += 1
        start_a, start_b = i, j
        while i < len(a) and a[i].isdigit():
            i += 1
        while j < len(b) and b[j].isdigit():
            j += 1
        na = int(a[start_a:i]) if i > start_a else 0
        nb = int(b[start_b:j]) if j > start_b else 0
        if na != nb:
            return -1 if na < nb else 1
    return 0


def split_version(version: str) -> tuple[int, str, str]:
    epoch = 0
    if ":" in version:
        epoch_text, _, version = version.partition(":")
        epoch = int(epoch_text)
    if "-" in version:
        upstream, _, revision = version.rpartition("-")
    else:
        upstream, revision = version, "0"
    return epoch, upstream, revision


def version_compare(left: str, right: str) -> int:
    le, lu, lr = split_version(left)
    re_, ru, rr = split_version(right)
    for a, b in ((le, re_), (lu, ru), (lr, rr)):
        if isinstance(a, int):
            if a != b:
                return -1 if a < b else 1
            continue
        result = _verrevcmp(a, b)
        if result:
            return result
    return 0


RELATIONS = {"<<": lambda c: c < 0, "<=": lambda c: c <= 0, "=": lambda c: c == 0,
             ">=": lambda c: c >= 0, ">>": lambda c: c > 0}


def satisfies(have: str, relation: str, want: str) -> bool:
    return RELATIONS[relation](version_compare(have, want))


# --- the report -----------------------------------------------------------
def read_report(path: Path) -> dict:
    keys: dict[str, str] = {}
    installed: dict[str, str] = {}
    verdict = False
    for line in path.read_text(errors="replace").splitlines():
        if line.strip() == "=== verdict ===":
            verdict = True
        if line.startswith("INSTALLED: "):
            fields = line.split()
            if len(fields) >= 3:
                installed[fields[1]] = fields[2]
        elif "=" in line and not line.startswith((" ", "\t")) and " " not in line.split("=", 1)[0]:
            key, _, value = line.partition("=")
            keys.setdefault(key.strip(), value.strip())
    for key in ("DISTRO_ID", "DISTRO_CODENAME", "DPKG_ARCH", "KERNEL"):
        if not keys.get(key) or keys[key] == "unknown":
            die(f"{path.name} has no usable {key}; rerun check_env.sh on the target")
    keys["INSTALLED"] = installed
    # check_env.sh writes the verdict section last, after the INSTALLED list.
    # Without it the list is truncated, and treating a truncated list as the
    # truth would ship core packages (libc6, systemd, udev) the target already
    # has, as upgrades it never asked for.
    keys["TRUNCATED"] = "0" if verdict else "1"
    return keys


# --- Packages indexes -----------------------------------------------------
class Package(dict):
    """One stanza of a Packages file."""


def fetch(url: str, cache: Path) -> bytes:
    cache.mkdir(parents=True, exist_ok=True)
    name = hashlib.sha256(url.encode()).hexdigest()[:32]
    for extension in (".xz", ".gz", ""):
        stored = cache / f"{name}{extension or '.raw'}"
        if stored.exists():
            return stored.read_bytes()
    for extension in (".xz", ".gz", ""):
        try:
            request = urllib.request.Request(url + extension, headers={"User-Agent": UA})
            with urllib.request.urlopen(request, timeout=120) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            if error.code == 404:
                continue
            raise
        (cache / f"{name}{extension or '.raw'}").write_bytes(data)
        return data
    raise FileNotFoundError(url)


def decompress(url: str, data: bytes) -> bytes:
    if url.endswith(".gz") or data[:2] == b"\x1f\x8b":
        return gzip.decompress(data)
    if data[:6] == b"\xfd7zXZ\x00":
        return lzma.decompress(data)
    return data


def parse_packages(text: bytes) -> list[Package]:
    packages = []
    stanza: dict[str, str] = {}
    key = None
    for raw in text.decode("utf-8", "replace").splitlines():
        if not raw.strip():
            if stanza.get("Package"):
                packages.append(Package(stanza))
            stanza, key = {}, None
        elif raw[0] in " \t" and key:
            stanza[key] += "\n" + raw.strip()
        elif ":" in raw:
            key, _, value = raw.partition(":")
            if key in FIELDS:
                stanza[key] = value.strip()
            else:
                key = None
    if stanza.get("Package"):
        packages.append(Package(stanza))
    return packages


def load_index(distro: str, codename: str, arch: str, cache: Path) -> tuple[dict, dict]:
    family = MIRRORS.get(distro)
    if family is None:
        die(f"{distro} has no mirror table here; fetch the .debs by hand")
    archive = family["archive"].get(arch, family["archive"]["*"])
    security = family["security"]["*"]
    by_name: dict[str, list[Package]] = {}
    provides: dict[str, list[str]] = {}
    seen = 0
    for suite in family["suites"]:
        suite = suite.format(c=codename)
        mirror = security if suite.endswith("-security") else archive
        for component in family["components"]:
            for binary in (b.format(a=arch) for b in family["binaries"]):
                url = f"{mirror}/dists/{suite}/{component}/{binary}/Packages"
                try:
                    data = decompress(url, fetch(url, cache))
                except FileNotFoundError:
                    continue  # that suite/component/arch does not exist
                except (urllib.error.URLError, OSError) as error:
                    print(f"  skip {url}: {error}", file=sys.stderr)
                    continue
                packages = parse_packages(data)
                seen += len(packages)
                for package in packages:
                    package["Suite"] = suite
                    package["Component"] = component
                    package["Mirror"] = mirror
                    by_name.setdefault(package["Package"], []).append(package)
                    for virtual in package.get("Provides", "").split(","):
                        fields = virtual.strip().split()
                        if not fields:
                            continue
                        name = fields[0].split(":")[0]
                        if name:
                            provides.setdefault(name, []).append(package["Package"])
                print(f"  {suite}/{component}/{binary}: {len(packages)} packages",
                      file=sys.stderr)
    if not by_name:
        die("no Packages index could be downloaded; is this machine online?")
    print(f"index: {seen} stanzas, {len(by_name)} names, "
          f"{len(provides)} virtual", file=sys.stderr)
    return by_name, provides


# --- closure --------------------------------------------------------------
DEP_RE = re.compile(r"^\s*([^()<|]+?)\s*(?:\(([<>=]+)\s*([^)]+)\))?\s*$")


def parse_dep_list(text: str) -> list[list[tuple[str, str, str]]]:
    """'a (>= 1), b | c' -> [[(a,'>=','1')], [(b,'',''), (c,'','')]]"""
    groups = []
    for group in text.split(","):
        alternatives = []
        for choice in group.split("|"):
            choice = choice.strip()
            if not choice or choice.startswith("<"):
                continue
            match = DEP_RE.match(choice)
            if not match:
                continue
            name = match.group(1).strip().split(":")[0]
            alternatives.append((name, match.group(2) or "", match.group(3) or ""))
        if alternatives:
            groups.append(alternatives)
    return groups


class Resolver:
    def __init__(self, by_name, provides, installed, arch, keep_installed=False):
        self.by_name = by_name
        self.provides = provides
        self.installed = installed
        self.arch = arch
        self.keep_installed = keep_installed
        self.selected: dict[str, Package] = {}
        self.missing: list[str] = []
        self.blocked: list[str] = []

    def effective(self, name: str) -> str | None:
        """The version the target ends up with once this bundle is in."""
        if name in self.selected:
            return self.selected[name]["Version"]
        return self.installed.get(name)

    def victim(self, package: Package) -> str | None:
        """Name the first package on the target this candidate would break."""
        for field in ("Breaks", "Conflicts"):
            for group in parse_dep_list(package.get(field, "")):
                for name, relation, version in group:
                    have = self.effective(name)
                    if have and (not relation or satisfies(have, relation, version)):
                        return f"{name} {have}"
        return None

    def candidate(self, name: str, relation: str = "", version: str = "") -> Package | None:
        """Newest stanza for name that satisfies relation and is installable.

        The newest is not always the right one: udev 255.4-1ubuntu8.18 Breaks
        systemd (<< 255.4-1ubuntu8.18), so a target still on systemd .17 needs
        the older udev, which in turn pins libudev1 (= 255.4-1ubuntu8). Walking
        the candidates newest first and taking the first that both fits the
        relation and breaks nothing keeps the bundle installable, where apt
        would instead upgrade half the system.
        """
        stanzas = self.by_name.get(name)
        if not stanzas:
            return None
        ordered = sorted(stanzas, key=cmp_to_key(
            lambda a, b: version_compare(b["Version"], a["Version"]) or
            (a["Architecture"] != self.arch) - (b["Architecture"] != self.arch)))
        blocked = []
        for package in ordered:
            if relation and not satisfies(package["Version"], relation, version):
                continue
            hit = self.victim(package)
            if hit is None:
                return package
            blocked.append(f"{name} {package['Version']} breaks {hit}")
        if blocked:
            self.blocked.extend(blocked)
            print(f"  warn: no installable {name}"
                  f"{' ' + relation + ' ' + version if relation else ''} "
                  f"({blocked[-1]})", file=sys.stderr)
        return None

    def _pick(self, alternatives: list[tuple[str, str, str]]) -> tuple[str, str, str] | None:
        """Choose an alternative the target does not already satisfy."""
        fallback = None
        for name, relation, version in alternatives:
            have = self.effective(name)
            if not self.keep_installed and have and \
                    (not relation or satisfies(have, relation, version)):
                return None  # already fine on the target, nothing to ship
            if self.candidate(name, relation, version) is not None:
                return name, relation, version
            for provider in self.provides.get(name, []):
                if self.candidate(provider) is not None and fallback is None:
                    # A versioned dependency on a virtual package cannot be
                    # checked here; ship the provider and let dpkg confirm.
                    fallback = (provider, "", "")
        return fallback

    def resolve(self, names: list[str]) -> None:
        queue = [(name, "", "") for name in names]
        replaced: dict[str, int] = {}
        while queue:
            name, relation, version = queue.pop(0)
            chosen = self.selected.get(name)
            if chosen is not None and \
                    (not relation or satisfies(chosen["Version"], relation, version)):
                continue
            package = self.candidate(name, relation, version)
            if package is None:
                # A virtual name, dh-sequence-dkms for instance: take a provider.
                for provider in self.provides.get(name, []):
                    package = self.candidate(provider)
                    if package is not None:
                        name = provider
                        break
            if package is None:
                self.missing.append(name)
                continue
            if chosen is not None:
                # An earlier, looser dependency picked a version this exact
                # one contradicts: udev 255.4-1ubuntu8 needs libudev1
                # (= 255.4-1ubuntu8) after .18 was already chosen for a >=.
                replaced[name] = replaced.get(name, 0) + 1
                if replaced[name] > 2:
                    self.blocked.append(f"{name}: {relation} {version} and "
                                        f"{chosen['Version']} cannot both hold")
                    continue
                print(f"  note: taking {name} {package['Version']} instead of "
                      f"{chosen['Version']} for {relation} {version}", file=sys.stderr)
            self.selected[name] = package
            for field in ("Pre-Depends", "Depends"):
                for alternatives in parse_dep_list(package.get(field, "")):
                    choice = self._pick(alternatives)
                    if choice:
                        queue.append(choice)

    def verify(self) -> list[str]:
        """Re-check the result the way dpkg will, before it is too late.

        The target is offline: a dependency this got wrong cannot be fixed
        there. A dependency on a virtual name is taken as satisfied, since the
        report lists installed package names but not what they provide.
        """
        problems = []
        for name, package in sorted(self.selected.items()):
            for field in ("Pre-Depends", "Depends"):
                for alternatives in parse_dep_list(package.get(field, "")):
                    if not self._satisfied(alternatives):
                        problems.append(
                            f"{name} {package['Version']} needs " +
                            " | ".join(f"{n} {r} {v}".strip()
                                       for n, r, v in alternatives))
            for field in ("Breaks", "Conflicts"):
                for alternatives in parse_dep_list(package.get(field, "")):
                    for other, relation, version in alternatives:
                        have = self.effective(other)
                        if have and (not relation or satisfies(have, relation, version)):
                            problems.append(f"{name} {package['Version']} {field} "
                                            f"{other} {have}")
        return problems

    def _satisfied(self, alternatives: list[tuple[str, str, str]]) -> bool:
        for name, relation, version in alternatives:
            have = self.effective(name)
            if have and (not relation or satisfies(have, relation, version)):
                return True
            if name in self.provides:
                return True  # unverifiable from here, assumed present
        return False


def download(package: Package, out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    target = out / Path(package["Filename"]).name
    if target.exists() and target.stat().st_size == int(package.get("Size", -1)):
        return target
    url = f"{package['Mirror']}/{package['Filename']}"
    temporary = target.with_suffix(".part")
    print(f"  get {Path(package['Filename']).name} "
          f"({int(package.get('Size', 0)) // 1024} KiB)", file=sys.stderr)
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=300) as response, \
            temporary.open("wb") as stream:
        while block := response.read(1024 * 512):
            stream.write(block)
    digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
    expected = package.get("SHA256")
    if expected and digest != expected:
        temporary.unlink(missing_ok=True)
        die(f"{target.name}: sha256 {digest} != {expected}")
    temporary.replace(target)
    return target


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--report", type=Path, required=True,
                        help="check_env.sh output from the target machine")
    parser.add_argument("--out", type=Path, required=True, help="where to put the .debs")
    parser.add_argument("--want", nargs="*", default=[], help="packages to resolve")
    parser.add_argument("--want-file", type=Path, help="one package per line, # comments ok")
    parser.add_argument("--cache", type=Path,
                        default=Path(os.environ.get("GPU_UNLOCK_APT_CACHE",
                                                    "~/.cache/gpu-unlock/apt-index")).expanduser(),
                        help="Packages index cache")
    parser.add_argument("--dry-run", action="store_true", help="resolve, do not download")
    parser.add_argument("--keep-installed", action="store_true",
                        help="also ship packages the target already has")
    args = parser.parse_args()

    report = read_report(args.report)
    if report["TRUNCATED"] == "1":
        die(f"{args.report.name} has no '=== verdict ===' section, so its "
            f"INSTALLED list is incomplete. Copy the whole check_env.sh "
            f"output, or complete the list, before resolving: with a "
            f"truncated list this would ship core packages the target "
            f"already has.")
    distro = report["DISTRO_ID"]
    if distro not in MIRRORS:
        for alias in report.get("DISTRO_ID_LIKE", "").split():
            if alias in MIRRORS:
                distro = alias
                break
    print(f"target: {report.get('DISTRO_NAME', distro)} {report['DISTRO_CODENAME']} "
          f"{report['DPKG_ARCH']} kernel {report['KERNEL']}", file=sys.stderr)

    want = list(args.want)
    if args.want_file:
        want += [line.split("#")[0].strip() for line in
                 args.want_file.read_text().splitlines()]
        want = [w for w in want if w]
    if not want:
        parser.exit(1, "nothing to resolve: pass --want or --want-file\n")

    by_name, provides = load_index(distro, report["DISTRO_CODENAME"],
                                   report["DPKG_ARCH"], args.cache)
    resolver = Resolver(by_name, provides, report["INSTALLED"], report["DPKG_ARCH"],
                        args.keep_installed)
    resolver.resolve(want)

    if resolver.missing:
        print(f"ERROR: unresolved: {' '.join(sorted(set(resolver.missing)))}",
              file=sys.stderr)
        for reason in dict.fromkeys(resolver.blocked):
            print(f"  {reason}", file=sys.stderr)
        print("A kernel package usually means the target runs a kernel the "
              "archive has superseded; download that .deb by hand from "
              "https://launchpad.net/ubuntu (or the Debian snapshot archive) "
              "and drop it next to the others.", file=sys.stderr)
    problems = resolver.verify()
    if problems:
        print("ERROR: this closure would not install on the target:", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
    selected = sorted(resolver.selected.values(),
                      key=lambda p: Path(p["Filename"]).name)
    total = sum(int(p.get("Size", 0)) for p in selected)
    print(f"closure: {len(selected)} packages, {total // 1024 // 1024} MiB "
          f"({len(resolver.missing)} unresolved, {len(problems)} inconsistent)",
          file=sys.stderr)
    if args.dry_run:
        for package in selected:
            print(f"{package['Package']} {package['Version']} {package['Architecture']}")
        if resolver.missing or problems:
            raise SystemExit(2)
        return
    if problems:
        # Downloading anyway would hand over a bundle that cannot install.
        raise SystemExit(2)

    args.out.mkdir(parents=True, exist_ok=True)
    lines = []
    for package in selected:
        path = download(package, args.out)
        lines.append(f"{package['Package']}\t{package['Version']}\t"
                     f"{package['Architecture']}\t{path.name}\t{package.get('SHA256', '')}")
    (args.out / "manifest.tsv").write_text("\n".join(lines) + "\n")
    print(f"wrote {len(selected)} .deb files and manifest.tsv to {args.out}",
          file=sys.stderr)
    if resolver.missing:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
