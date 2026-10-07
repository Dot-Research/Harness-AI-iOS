#!/usr/bin/env bash
set -euo pipefail
# Provision outside the checkout; tasks already have an isolated checkout.
toolchain_root=/workspace/toolchains
swift_name=swift-6.2-RELEASE-ubuntu24.04
swift_url=https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE
swift_fingerprint=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
mkdir -p "$toolchain_root"/{downloads,verification,gnupg,sysroot,cache/clang,cache/swiftpm,cache/config,cache/security}
chmod 700 "$toolchain_root/gnupg"

fetch_if_missing() {
  local url=$1 output=$2
  if [[ ! -f "$output" ]]; then
    curl --fail --silent --show-error --location "$url" -o "$output.tmp"
    mv "$output.tmp" "$output"
  fi
}
fetch_if_missing "$swift_url/$swift_name.tar.gz" "$toolchain_root/downloads/$swift_name.tar.gz"
fetch_if_missing "$swift_url/$swift_name.tar.gz.sig" "$toolchain_root/downloads/$swift_name.tar.gz.sig"
fetch_if_missing https://raw.githubusercontent.com/swiftlang/swift-org-website/4bd32dac6fa26bea67cfe387ac20f24237f797df/keys/all-keys.asc "$toolchain_root/verification/swift-all-keys.asc"
printf '%s  %s\n' 8e3d63a3371caad495e694414b9b9a22c5f68c6473077406c7296472a41bc077 "$toolchain_root/downloads/$swift_name.tar.gz" | sha256sum --check --strict

gpg --homedir "$toolchain_root/gnupg" --batch --import "$toolchain_root/verification/swift-all-keys.asc"
gpg --homedir "$toolchain_root/gnupg" --batch --status-fd 1 --verify "$toolchain_root/downloads/$swift_name.tar.gz.sig" "$toolchain_root/downloads/$swift_name.tar.gz" > "$toolchain_root/verification/swift-signature-status.log" 2>&1
# The historical2025 signature predates the key's2026 expiration. GPG reports
# VALIDSIG and current expiration; the fixed archive hash and full pinned
# signing fingerprint both remain mandatory.
python3 - "$toolchain_root/verification/swift-signature-status.log" "$swift_fingerprint" <<'PY'
import sys
log = open(sys.argv[1]).read()
assert f'[GNUPG:] VALIDSIG {sys.argv[2]} 2025-09-12 ' in log, log
assert not any(f'[GNUPG:] {s}' in log for s in ('BADSIG', 'ERRSIG', 'REVKEYSIG')), log
PY
if [[ ! -x "$toolchain_root/$swift_name/usr/bin/swift" ]]; then
  tar -xzf "$toolchain_root/downloads/$swift_name.tar.gz" -C "$toolchain_root"
fi

# These hashes were authenticated against the Debian trixie signed Packages
# metadata (Debian archive keyring). TLS and fixed checksum checks stay enabled.
for package_name in libsqlite3-0 libsqlite3-dev; do
  package_file="${package_name}_3.46.1-7+deb13u2_amd64.deb"
  fetch_if_missing "https://deb.debian.org/debian/pool/main/s/sqlite3/$package_file" "$toolchain_root/downloads/$package_file"
done
printf '%s  %s\n' \
  0a459adaffd901109f7811ab65f58e7a957b4907d05539cf3d1184efdcde0468 "$toolchain_root/downloads/libsqlite3-0_3.46.1-7+deb13u2_amd64.deb" \
  56e1945d52292b506c1f0bcb77543fea289ccee857c478dcddded40226e1594d "$toolchain_root/downloads/libsqlite3-dev_3.46.1-7+deb13u2_amd64.deb" | sha256sum --check --strict
for package_name in libsqlite3-0 libsqlite3-dev; do
  dpkg-deb -x "$toolchain_root/downloads/${package_name}_3.46.1-7+deb13u2_amd64.deb" "$toolchain_root/sysroot"
done
cat > "$toolchain_root/env.sh" <<'ENV'
export PATH="/workspace/toolchains/swift-6.2-RELEASE-ubuntu24.04/usr/bin:$PATH"
export XDG_CACHE_HOME=/workspace/toolchains/cache
export CLANG_MODULE_CACHE_PATH=/workspace/toolchains/cache/clang
export SWIFTPM_MODULECACHE_OVERRIDE=/workspace/toolchains/cache/clang
export PKG_CONFIG_PATH=/workspace/toolchains/sysroot/usr/lib/x86_64-linux-gnu/pkgconfig
export PKG_CONFIG_ALLOW_SYSTEM_LIBS=1
export PKG_CONFIG_SYSROOT_DIR=/workspace/toolchains/sysroot
export LD_LIBRARY_PATH="/workspace/toolchains/sysroot/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="/workspace/toolchains/sysroot/usr/lib/x86_64-linux-gnu${LIBRARY_PATH:+:$LIBRARY_PATH}"
ENV
source "$toolchain_root/env.sh"
swift --version
pkg-config --cflags --libs sqlite3
