#!/usr/bin/env python3
"""Extract official Debian amd64 packages locally; never run maintainer scripts.

Usage: python3 prepare-sysroot.py base|wine|replay|media
The captured Packages index and lock.json pin package URLs and SHA-256 hashes. replay extracts every lock*.json into
rootfs, which then holds the published debian-root. media adds to such a root the GStreamer plugins winegstreamer
plays games' videos with, resolved from lock.json's index beyond the other locks, and pins them in lock-media.json.
This is a dependency-closure extractor, not a general Debian package manager.
"""
import concurrent.futures
import functools
import hashlib
import json
import lzma
import os
from pathlib import Path
import re
import subprocess
import sys

BASE = Path(__file__).resolve().parent
ROOT = BASE / "rootfs"
CACHE = BASE / "packages"
INDEX = BASE / "Packages-amd64.xz"
ORIGIN = "https://deb.debian.org/debian/"
INDEX_URL = ORIGIN + "dists/trixie/main/binary-amd64/Packages.xz"
# GStreamer's demuxers, converters and decodebin (base, good), its ASF demuxer (ugly) and gst-libav, which decodes
# H.264, AAC, WMV, WMA and the like with FFmpeg: the elements winegstreamer builds games' videos from.
MEDIA_SEEDS = ["gstreamer1.0-plugins-base", "gstreamer1.0-plugins-good", "gstreamer1.0-plugins-ugly",
               "gstreamer1.0-libav", "libgstreamer-plugins-bad1.0-0"]
# Packages media takes only these files of (and their copyright), without what they depend on: plugins-bad's video
# parsers, whose h264parse winegstreamer puts before avdec_h264 to cut what a game sends into whole frames. Their
# library comes with libgstreamer-plugins-bad1.0-0; the whole of plugins-bad would bring 114 more packages.
MEDIA_FILES = {"gstreamer1.0-plugins-bad": ["usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgstvideoparsersbad.so"]}
# Left out with what only it brings in: libsoup, for plugins-good's HTTP sources, which Media Foundation never uses,
# pulls in systemd, dbus, PAM and base-files, whose /etc/os-release EAC and steamclient would read.
MEDIA_EXCLUDED = {"libsoup-3.0-0"}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download(url, path, expected=None):
    if path.is_file() and (not expected or digest(path) == expected):
        return
    temporary = path.with_suffix(path.suffix + ".part")
    subprocess.run(["curl", "-fL", "--retry", "3", "--silent", "--show-error",
                    url, "-o", str(temporary)], check=True)
    if expected and digest(temporary) != expected:
        raise RuntimeError("SHA-256 mismatch: " + url)
    temporary.replace(path)


@functools.lru_cache(maxsize=None)
def package_index():
    download(INDEX_URL, INDEX)
    packages = {}
    providers = {}
    for paragraph in lzma.decompress(INDEX.read_bytes()).decode().split("\n\n"):
        fields = {}
        current = None
        for line in paragraph.splitlines():
            if line.startswith(" ") and current:
                fields[current] += " " + line.strip()
            elif ": " in line:
                current, value = line.split(": ", 1)
                fields[current] = value
        if "Package" not in fields:
            continue
        name = fields["Package"]
        packages[name] = fields
        for supplied in fields.get("Provides", "").split(","):
            supplied = supplied.strip().split(" ", 1)[0]
            if supplied:
                providers.setdefault(supplied, []).append(name)
    return packages, providers


def pin(record):
    return {"name": record["Package"], "version": record["Version"],
            "url": ORIGIN + record["Filename"], "sha256": record["SHA256"],
            "size": int(record["Size"]),
            "installed_kib": int(record.get("Installed-Size", 0)),
            "architecture": record["Architecture"]}


def closure(seeds, present=frozenset(), excluded=frozenset()):
    """The seeds and what they depend on, but for the packages in present, which the root already holds, and those in
    excluded, left out with what only they would bring in."""
    packages, providers = package_index()
    selected = {}
    pending = list(seeds)
    while pending:
        name = pending.pop()
        if name in selected or name in present or name in excluded:
            continue
        record = packages[name]
        selected[name] = record
        for field in ("Pre-Depends", "Depends"):
            for dependency in record.get(field, "").split(","):
                if not dependency.strip():
                    continue
                candidates = []
                for alternative in dependency.split("|"):
                    candidate = re.split(r"[\s:(]", alternative.strip(), 1)[0]
                    if candidate in packages:
                        candidates.append(candidate)
                    else:
                        candidates.extend(providers.get(candidate, []))
                if not candidates:
                    raise RuntimeError(f"Unresolved {name}: {dependency}")
                pending.append(next((c for c in candidates if c in selected or c in present), candidates[0]))
    return [pin(record) for name, record in sorted(selected.items())]


def locked(skipped=()):
    """The packages of every lock*.json but those named in skipped, lock.json's first."""
    records = {}
    for lock in sorted(BASE.glob("lock*.json"), key=lambda path: (path.name != "lock.json", path.name)):
        if lock.name not in skipped:
            for record in json.loads(lock.read_text())["packages"]:
                records.setdefault(record["url"], record)
    return list(records.values())


def extract(record):
    """Extract a package, or only the files its record lists."""
    archive = CACHE / record["url"].rsplit("/", 1)[1]
    listing = subprocess.check_output(["ar", "t", str(archive)], text=True).splitlines()
    payload = next(name for name in listing if name.startswith("data.tar"))
    members = ["./" + name for name in record.get("files", [])]
    source = subprocess.Popen(["ar", "p", str(archive), payload], stdout=subprocess.PIPE)
    subprocess.run(["bsdtar", "-xf", "-", "--no-same-owner", "--no-same-permissions",
                    "-C", str(ROOT), *members], stdin=source.stdout, check=True)
    source.stdout.close()
    if source.wait():
        raise RuntimeError("ar failed: " + str(archive))
    # Keep absolute package symlinks within this sysroot when macOS resolves them.
    for directory, directories, files in os.walk(ROOT, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            if path.is_symlink():
                target = os.readlink(path)
                if target.startswith("/"):
                    replacement = os.path.relpath(ROOT / target.lstrip("/"), path.parent)
                    path.unlink()
                    path.symlink_to(replacement)


def prepare_wine_zlib():
    """Reproduce libwine's postinst DLL preparation without executing scripts."""
    changes = []
    for mingw_arch, wine_arch in [('x86_64', 'x86_64'), ('i686', 'i386')]:
        source = ROOT / f'usr/{mingw_arch}-w64-mingw32/lib/zlib1.dll'
        destination_dir = ROOT / f'usr/lib/x86_64-linux-gnu/wine/{wine_arch}-windows'
        if not source.is_file() or not destination_dir.is_dir():
            continue
        data = source.read_bytes()
        if data[:2] != b'MZ' or len(data) < 96 or int.from_bytes(data[60:64], 'little') < 96:
            raise RuntimeError(f'Unexpected zlib PE layout: {source}')
        destination = destination_dir / 'zlib1.dll'
        destination.write_bytes(data[:64] + b'Wine builtin DLL' + bytes(16) + data[96:])
        changes.append(dict(source=str(source), source_sha256=digest(source),
                            destination=str(destination), destination_sha256=digest(destination)))
    if changes:
        (BASE / 'wine-zlib-preparation.json').write_text(json.dumps(changes, indent=2) + '\n')


def prepare_ca_bundle():
    """Make the bundle of ca-certificates' postinst (update-ca-certificates), which Wine's crypt32 takes its root
    certificates from: Mozilla's certificates in name order, a blank line between them."""
    certificates = sorted((ROOT / "usr/share/ca-certificates/mozilla").glob("*.crt"))
    if certificates:
        (ROOT / "etc/ssl/certs").mkdir(parents=True, exist_ok=True)
        (ROOT / "etc/ssl/certs/ca-certificates.crt").write_text(
            "\n".join(certificate.read_text() for certificate in certificates))


def prepare_alternatives():
    """Make the links update-alternatives would in libblas3's and liblapack3's postinst, which media pulls in for
    libavfilter: without them, libavfilter and gst-libav do not load."""
    folder = ROOT / "usr/lib/x86_64-linux-gnu"
    for link, target in (("libblas.so.3", "blas/libblas.so.3"), ("liblapack.so.3", "lapack/liblapack.so.3")):
        if (folder / target).exists() and not os.path.lexists(folder / link):
            (folder / link).symlink_to(target)


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else "base"
    if mode not in {"base", "wine", "replay", "media"}:
        raise SystemExit("Usage: prepare-sysroot.py base|wine|replay|media")
    ROOT.mkdir(exist_ok=True)
    CACHE.mkdir(exist_ok=True)
    # The lock a resolving mode writes once its packages are extracted.
    lock_path = lock = None
    if mode == "replay":
        records = locked()
    elif mode == "media":
        if not (ROOT / "usr/lib/x86_64-linux-gnu").is_dir():
            raise SystemExit("Put the published debian-root's root/ in rootfs, or replay, first: media adds to it")
        # The root's packages are left out by name: resolved from another index, the plugins could need other
        # versions of them.
        index_sha256 = json.loads((BASE / "lock.json").read_text())["index_sha256"]
        packages, _ = package_index()
        if digest(INDEX) != index_sha256:
            raise SystemExit(f"{INDEX.name} is not the index lock.json was resolved from (SHA-256 {index_sha256}). "
                             "Delete it if it is an older download; if Debian's current index differs too, a trixie "
                             "point release replaced lock.json's, and lock.json must be resolved again first.")
        present = {record["name"] for record in locked(skipped={"lock-media.json"})}
        # A MEDIA_FILES package stays its files alone, even when a seed depends on it.
        records = closure(MEDIA_SEEDS, present, MEDIA_EXCLUDED | MEDIA_FILES.keys())
        for name, files in MEDIA_FILES.items():
            records.append(dict(pin(packages[name]), files=files + [f"usr/share/doc/{name}/copyright"]))
        records.sort(key=lambda record: record["name"])
        lock_path = BASE / "lock-media.json"
        lock = {"suite": "trixie", "architecture": "amd64", "index_url": INDEX_URL, "index_sha256": index_sha256,
                "seeds": MEDIA_SEEDS, "excluded": sorted(MEDIA_EXCLUDED), "packages": records}
    else:
        seeds = ["libc6", "coreutils", "dash"]
        if mode == "wine":
            seeds += ["wine64", "wine64-preloader", "wine", "fonts-wine",
                      "libgnutls30t64", "libvulkan1", "libgl1", "libegl1",
                      "libxcomposite1", "libxcursor1", "libxfixes3", "libxi6",
                      "libxinerama1", "libxrandr2", "libxrender1", "libxxf86vm1"]
        records = closure(seeds)
        lock_path = BASE / ("lock-base.json" if mode == "base" else "lock.json")
        lock = {"suite": "trixie", "architecture": "amd64", "index_url": INDEX_URL,
                "index_sha256": digest(INDEX), "seeds": seeds, "packages": records}
    print(f"{len(records)} packages; download {sum(r['size'] for r in records)/1e6:.1f} MB; "
          f"installed {sum(r['installed_kib'] for r in records)/1024:.1f} MiB", flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        jobs = [pool.submit(download, record["url"],
                            CACHE / record["url"].rsplit("/", 1)[1], record["sha256"])
                for record in records]
        for job in jobs:
            job.result()
    # Debian merged-/usr directories, created before extracting any packages.
    for name in ("bin", "sbin", "lib", "lib64"):
        (ROOT / "usr" / name).mkdir(parents=True, exist_ok=True)
        if not os.path.lexists(ROOT / name):
            (ROOT / name).symlink_to("usr/" + name)
    for record in records:
        extract(record)
    prepare_wine_zlib()
    prepare_ca_bundle()
    prepare_alternatives()
    for name in ("tmp", "proc", "sys", "dev", "run", "home/experiment"):
        (ROOT / name).mkdir(parents=True, exist_ok=True)
    (ROOT / "etc").mkdir(exist_ok=True)
    (ROOT / "etc/passwd").write_text("root:x:0:0:root:/root:/bin/sh\nexperiment:x:501:20:experiment:/home/experiment:/bin/sh\n")
    (ROOT / "etc/group").write_text("root:x:0:\nstaff:x:20:\n")
    (ROOT / "etc/nsswitch.conf").write_text("passwd: files\ngroup: files\nhosts: files dns\n")
    (ROOT / "etc/hosts").write_text("127.0.0.1 localhost hl\n::1 localhost hl\n")
    # The guest has no resolver of its own: glibc sends its queries to these servers through the host's network.
    (ROOT / "etc/resolv.conf").write_text("nameserver 1.1.1.1\nnameserver 1.0.0.1\nnameserver 2606:4700:4700::1111\n")
    if lock_path:
        lock_path.write_text(json.dumps(lock, indent=2) + "\n")
    print("Prepared:", ROOT, flush=True)


if __name__ == "__main__":
    main()
