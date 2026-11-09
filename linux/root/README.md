# The Debian root of the Linux engine

The x86-64 Linux userland the guest runs on: glibc 2.41, coreutils and dash, and the libraries voile-wine's Linux
build and Rocket League load (GnuTLS, FreeType, fonts, CA certificates for HTTPS...). Debian trixie amd64 packages,
extracted without running any maintainer script, merged `/usr`, relative symlinks. The engine mounts it read-only.

- `lock.json`: the closure of Debian's Wine 10 packages (235 packages), the base of the root. Debian's own Wine is in
  it but unused: the engine binds voile-wine at `/opt/wine`.
- `lock-network.json`: `curl` and `ca-certificates` (`/etc/ssl/certs/ca-certificates.crt`).
- `lock-graphics-probes.json`: Mesa and Vulkan tools used by the graphics probes.
- `lock-media.json`: GStreamer's base, good and ugly plugins, gst-libav and the video parsers of plugins-bad, with what
  they need beyond the other locks (62 packages, 38 MB to download, 92 MiB in the root). voile-wine's winegstreamer
  plays games' videos and sounds with them: gst-libav decodes H.264, AAC, WMV, WMA and the like with the root's
  FFmpeg, h264parse cuts H.264 into the frames it decodes, asfdemux opens WMV and WMA files. Only
  `libgstvideoparsersbad.so` is taken from plugins-bad, without its dependencies, and libsoup is left out, with the
  systemd, dbus, PAM and base-files (`/etc/os-release`) it would bring.
- `prepare-sysroot.py`: the extractor. `replay` extracts every `lock*.json` from pinned URLs and SHA-256 values into
  `rootfs`, which then holds the published root, and makes what maintainer scripts would: ca-certificates' bundle
  (its certificates in name order, a blank line between them), the links of libblas3's and liblapack3's alternatives,
  which libavfilter loads, and libwine's `zlib1.dll`. `media` resolves `lock-media.json` from `lock.json`'s Packages
  index, and from no other, and adds its packages to the root in `rootfs`.

Each entry names the Debian package, version, URL and SHA-256, which also locate its source package for the GPL.
The root the engine runs on is published as the `debian-root` archive of `sources.json`. A new one starts from it:

```sh
mkdir linux/root/rootfs
tar -xJf build/downloads/debian-root-trixie-20261109.tar.xz -C linux/root/rootfs --strip-components 2 \
    debian-root-trixie-20261109/root
python3 linux/root/prepare-sysroot.py media      # after changing its seeds
./scripts/import-debian-root.sh linux/root/rootfs debian-root-trixie-<date>
```

`import-debian-root.sh` packs it with the locks into `build/downloads` and prints the release to publish and the
checksum for `sources.json`. `media` only adds to the root: to drop a package from `lock-media.json`, start instead
from a root without its packages, debian-root-trixie-20260928's or one `replay` makes with `lock-media.json` moved
aside.
