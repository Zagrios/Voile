# The Debian root of the Linux engine

The x86-64 Linux userland the guest runs on: glibc 2.41, coreutils and dash, and the libraries voile-wine's Linux
build and Rocket League load (GnuTLS, FreeType, fonts, CA certificates for HTTPS...). Debian trixie amd64 packages,
extracted without running any maintainer script, merged `/usr`, relative symlinks. The engine mounts it read-only.

- `lock.json`: the closure of Debian's Wine 10 packages (235 packages), the base of the root. Debian's own Wine is in
  it but unused: the engine binds voile-wine at `/opt/wine`.
- `lock-network.json`: `curl` and `ca-certificates` (`/etc/ssl/certs/ca-certificates.crt`).
- `lock-graphics-probes.json`: Mesa and Vulkan tools used by the graphics probes.
- `prepare-sysroot.py`: the extractor (`replay` extracts `lock.json` from pinned URLs and SHA-256 values).

Each entry names the Debian package, version, URL and SHA-256, which also locate its source package for the GPL.
The root that v1 ran with is published as the `debian-root` archive of `sources.json` (`scripts/import-debian-root.sh`).
