#!/usr/bin/env bash
# Builds the bundled Linux runtime for dsh-app (Ubuntu Base + Node.js + DeepSeek Harness,
# run through Termux proot) for each Android ABI, entirely on an x86_64 Linux host without
# executing any foreign-architecture code.
#
#   runtime/build-runtime.sh                 # both ABIs (x86_64 first)
#   runtime/build-runtime.sh x86_64          # one ABI
#   COMPRESS=gz runtime/build-runtime.sh     # .tar.gz instead of .tar.xz
#   RUNTIME_OUT=/path runtime/build-runtime.sh   # stage outputs outside runtime/out (not packaged)
#
# The DSH tree is patched with runtime/patches/*.diff (pinned per DSH version in
# runtime/patches/pins.json; an unvetted DSH version fails the build) and the dsh-go-bridge
# plugin (runtime/bridge/dsh-go-bridge) is installed at /opt/dsh-go/dsh-go-bridge and loaded by
# the `dsh web` overlay. Check both on the host with runtime/tests/run-guard-tests.sh
# runtime/.work/x86_64/dsh-prefix, or end to end with runtime/test-host.sh.
#
# Outputs (consumed by app/android/app/build.gradle.kts flavors):
#   runtime/out/<abi>/assets/runtime/rootfs-<abi>.tar.xz
#   runtime/out/<abi>/assets/runtime/manifest.json      (versions, hashes, launch template)
#   runtime/out/<abi>/assets/runtime/licenses/...
#   runtime/out/<abi>/jniLibs/<abi>/lib{proot,proot-loader,talloc,android-shmem}.so
#   runtime/out/<abi>/build-report.json                  (ELF audit, pruned files, warnings)
#   runtime/out/manifest.json                            (index of all built ABIs)
#
# Idempotent: downloads are cached in runtime/.cache and verified on every run; the npm
# trees are pinned by runtime/locks/dsh-<version>/package-lock.json and
# runtime/locks/pnpm-<version>/package-lock.json (created on the first run, reused with
# `npm ci` afterwards; pnpm's tarball integrity is additionally pinned below).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE="$HERE/.cache"
WORK="$HERE/.work"
OUT="${RUNTIME_OUT:-$HERE/out}"   # the app build reads runtime/out; RUNTIME_OUT stages a build elsewhere
LOCKS="$HERE/locks"
PY=(python3 -I "$HERE/lib/rtbuild.py")

# ---- pinned inputs (override via environment; pinned hashes then must be updated too) ----
RUNTIME_REVISION="${RUNTIME_REVISION:-r15}"  # r14 + per-family DNS under PRoot, input recovery, session deletion and upload resolver fixes, title and boot cache work; DSH as r12
DSH_VERSION="${DSH_VERSION:-0.2.2-rc.1}"
NODE_VERSION="${NODE_VERSION:-24.22.1}"
# pnpm runs DSH's plugin installs (pluginManager / `dsh plugin`); the version the DSH repo pins.
PNPM_VERSION="${PNPM_VERSION:-11.28.5}"
# dist.integrity of pnpm-$PNPM_VERSION.tgz, identical on registry.npmjs.org and npmmirror
PNPM_INTEGRITY="${PNPM_INTEGRITY:-sha512-SEVj0wtMKtJ8tIqpT/KzAtvOvI/2vyiBbCWJiG4UbOf3bzVPO8GkOOb16XaMMCqgpvet2CMpA81M+BQmy8FNng==}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04.5}"
PROOT_VERSION="5.1.107.102"
TALLOC_VERSION="2.5.0"
SHMEM_VERSION="0.7"
UBUNTU_EXTRA="${UBUNTU_EXTRA:-tzdata ca-certificates git}"   # extra noble debs (+ dependency closure)
PYTHON_VERSION="${PYTHON_VERSION:-3.12.15}"
PBS_RELEASE="${PBS_RELEASE:-20261021}"    # astral-sh/python-build-standalone release tag
COMPRESS="${COMPRESS:-xz}"          # xz | gz
XZ_PRESET="${XZ_PRESET:-6}"         # 8 MiB dictionary: modest memory for xz-java on phones
XZ_THREADS="${XZ_THREADS:-4}"       # each xz -6 worker needs ~100 MiB; output does not depend on this
PRUNE_DEV_METADATA="${PRUNE_DEV_METADATA:-1}"   # drop *.map / *.d.ts from node_modules
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1767225600}"  # 2026-01-01T00:00:00Z, fixed tar mtimes

# Mirrors default to the China-friendly ones. Every one of them is overridable, because a
# builder outside China (CI) reaches the upstreams far faster, and the sha256 pins below
# make the mirror a pure transport choice: the bytes are identical either way.
UBUNTU_MIRROR="${UBUNTU_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release}"
NODE_MIRROR="${NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
NPM_REGISTRY="${NPM_REGISTRY:-https://registry.npmmirror.com}"
TERMUX_REPO="${TERMUX_REPO:-https://packages.termux.dev/apt/termux-main}"
UBUNTU_ARCHIVE_AMD64="${UBUNTU_ARCHIVE_AMD64:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu}"   # InRelease verified with gpgv
UBUNTU_ARCHIVE_ARM64="${UBUNTU_ARCHIVE_ARM64:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports}"
# Security uploads land in their own pool and reach the archive mirrors later; a build that
# only asks the archive 404s on a package the index already lists.
UBUNTU_SECURITY_ARCHIVE="${UBUNTU_SECURITY_ARCHIVE:-https://security.ubuntu.com/ubuntu}"
# Last-resort pools. Ubuntu keeps one copy of a package in pool/ and drops the rest, so the
# only copy of a security upload may sit on hosts that sync security into their main tree.
# These are mirrors, not sources of truth: every byte still has to match the signed index.
UBUNTU_EXTRA_POOLS="${UBUNTU_EXTRA_POOLS:-https://mirrors.tuna.tsinghua.edu.cn/ubuntu https://mirrors.aliyun.com/ubuntu}"
PBS_OFFICIAL="https://github.com/astral-sh/python-build-standalone/releases/download"
PBS_MIRROR="https://registry.npmmirror.com/-/binary/python-build-standalone"

# sha256 pins, cross-checked against cdimage.ubuntu.com / nodejs.org / the Termux Packages
# index. The mirror's SHA256SUMS / SHASUMS256.txt are verified as well.
declare -A PIN=(
  [ubuntu-base-24.04.5-base-arm64.tar.gz]=a91d5a93010193712d346d761372b7c9db6dfcf093893161c64ca107f05914f2
  [ubuntu-base-24.04.5-base-amd64.tar.gz]=e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86
  [node-v24.22.1-linux-arm64.tar.xz]=dbabf7a1cbf947e6059ffad2c27b80041db97dea1e553b62afdee7f13fca336e
  [node-v24.22.1-linux-x64.tar.xz]=6c172a9ab6718f7b801fb5a7bd486af2ee5e32758086a04b84fcce2aa77095e6
  [proot_5.1.107.102_aarch64.deb]=10a394b585c2fc2b2c8502544f4e5f1be581dc8bfff79e8ba62f16207423e030
  [proot_5.1.107.102_x86_64.deb]=2497064226c15971be8131c7facead94a06c225347796326a383c832dca57758
  [libtalloc_2.5.0_aarch64.deb]=556591f43bb773ad8777e1a29522640866a55f95dab71914418b94a8c58ad5a7
  [libtalloc_2.5.0_x86_64.deb]=b8c6d95f20075dc1f9ec6573575b2444e8d526e48e0d8d6d5cf4e071e6e06530
  [libandroid-shmem_0.7_aarch64.deb]=0da3a24d558b93c92bcf8d611e0826a99ff96e396b148e6cdf33b47c47c57ff6
  [libandroid-shmem_0.7_x86_64.deb]=ffa9e4c87467b158b148d0ff92dda796aa038276c2075af3269cdcdb06f25797
  [cpython-3.12.15+20261021-aarch64-unknown-linux-gnu-install_only_stripped.tar.gz]=b4567aa5a11f51b540c4dfd9e082ebf23e554f8ac17b85caa6cea23e83693394
  [cpython-3.12.15+20261021-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz]=6d7521138fd33afddc1ccd08abb007d9a2829e38117c2576f9efdc0ec73ce772
  # GPL-2.0 source of the proot binary (same archive Termux's build recipe pins); used for COPYING.
  [proot-v5.1.107.102.zip]=30d12a6e2cc4147123756ff58edea262d3083bbc238c12d0ab9b39e3d1c40852
)

log() { printf '\033[1;34m[runtime %s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf '\033[1;31m[runtime] error:\033[0m %s\n' "$*" >&2; exit 1; }
sha256() { sha256sum "$1" | cut -d' ' -f1; }

for tool in curl sha256sum python3 tar xz; do
  command -v "$tool" >/dev/null || die "missing host tool: $tool"
done

# fetch URL DEST [expected-sha256]: cached download with checksum verification.
fetch() {
  local url="$1" dest="$2" want="${3:-}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && -n "$want" && "$(sha256 "$dest")" == "$want" ]]; then return 0; fi
  if [[ -f "$dest" && -z "$want" ]]; then return 0; fi
  log "download $url"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 -sS -o "$dest.part" "$url"
  mv "$dest.part" "$dest"
  if [[ -n "$want" ]]; then
    local got; got="$(sha256 "$dest")"
    [[ "$got" == "$want" ]] || { rm -f "$dest"; die "sha256 mismatch for $dest: got $got want $want"; }
  fi
}

# fetch_try URL DEST [expected-sha256]: like fetch, but a bad copy is a return code, not a
# death. For optional inputs -- a mirror that serves an index inconsistent with its own
# InRelease (or an HTML error page) should cost us that one source, not the whole build.
fetch_try() {
  local url="$1" dest="$2" want="${3:-}"
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && -n "$want" && "$(sha256 "$dest")" == "$want" ]]; then return 0; fi
  # 索引与 InRelease 不一致,常常只是发布窗口里某台 CDN 边缘还在发旧副本:
  # 隔几秒再来一次就对了。这里的重试是**只读**的,不会接受任何未经校验的字节。
  local attempt
  for attempt in 1 2 3 4; do
    rm -f "$dest" "$dest.part"
    log "download $url (attempt $attempt)"
    if ! curl -fL --retry 2 --retry-delay 1 --connect-timeout 20 -sS -o "$dest.part" "$url"; then
      rm -f "$dest.part"
      sleep $((attempt * 5))
      continue
    fi
    if [[ -n "$want" && "$(sha256 "$dest.part")" != "$want" ]]; then
      log "  $url: bytes do not match InRelease yet, retrying"
      rm -f "$dest.part"
      sleep $((attempt * 5))
      continue
    fi
    mv "$dest.part" "$dest"
    return 0
  done
  rm -f "$dest" "$dest.part"
  return 1
}

pin_of() {
  local name="$1"
  if [[ -n "${PIN[$name]:-}" ]]; then printf '%s' "${PIN[$name]}"; fi
}

# fetch_any DEST SHA256 URL...: the first URL whose bytes match wins.
# A pool echo is normal here rather than a failure: ports.ubuntu.com carries the ports
# architectures only, so an Architecture: all package (tzdata, ca-certificates) is simply
# not there and the primary archive has it. The sha256 is checked before anything is kept,
# so trying more than one host cannot smuggle in different bytes.
fetch_any() {
  local dest="$1" want="$2"; shift 2
  mkdir -p "$(dirname "$dest")"
  if [[ -f "$dest" && "$(sha256 "$dest")" == "$want" ]]; then return 0; fi
  local url got code rc
  for url in "$@"; do
    # No -f: the status code is the diagnostic. "404 on every host" and "200 with the
    # wrong bytes" are different problems and used to look identical in the log.
    rc=0
    code="$(curl -L --retry 2 --retry-delay 1 --connect-timeout 20 -sS \
      -o "$dest.part" -w '%{http_code}' "$url" 2>/dev/null)" || rc=$?
    # curl still reports 200 when it gets the body but cannot write it (exit 23, e.g. the
    # cache directory not created yet by the fetch path), which reads as "wrong bytes".
    if [[ "$rc" != 0 || ! -s "$dest.part" ]]; then
      log "  curl exit $rc, http ${code:-000}: $url"
      rm -f "$dest.part"
      continue
    fi
    if [[ "$code" == 200 ]]; then
      got="$(sha256 "$dest.part")"
      if [[ "$got" == "$want" ]]; then mv "$dest.part" "$dest"; return 0; fi
      log "  200 but wrong bytes (${got:0:12} != ${want:0:12}): $url"
      rm -f "$dest.part"
    else
      log "  http ${code:-000}: $url"
      rm -f "$dest.part"
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# inputs
# ---------------------------------------------------------------------------
ubuntu_base() {  # $1 = ubuntu arch; echoes path
  local arch="$1" name="ubuntu-base-${UBUNTU_VERSION}-base-$1.tar.gz"
  local dir="$CACHE/ubuntu/$UBUNTU_VERSION"
  fetch "$UBUNTU_MIRROR/SHA256SUMS" "$dir/SHA256SUMS"
  local listed; listed="$(awk -v f="$name" '{n=$2; sub(/^\*/,"",n); if (n==f) print $1}' "$dir/SHA256SUMS")"
  [[ -n "$listed" ]] || { rm -f "$dir/SHA256SUMS"; die "$name not listed in SHA256SUMS (stale cache removed, rerun)"; }
  local pin; pin="$(pin_of "$name")"
  [[ -z "$pin" || "$pin" == "$listed" ]] || die "SHA256SUMS disagrees with pinned hash for $name"
  fetch "$UBUNTU_MIRROR/$name" "$dir/$name" "$listed"
  printf '%s' "$dir/$name"
}

node_dist() {  # $1 = node arch (arm64|x64); echoes path
  local name="node-v${NODE_VERSION}-linux-$1.tar.xz" dir="$CACHE/node/v$NODE_VERSION"
  fetch "$NODE_MIRROR/v$NODE_VERSION/SHASUMS256.txt" "$dir/SHASUMS256.txt"
  local listed; listed="$(awk -v f="$name" '$2==f {print $1}' "$dir/SHASUMS256.txt")"
  [[ -n "$listed" ]] || die "$name not listed in SHASUMS256.txt"
  local pin; pin="$(pin_of "$name")"
  [[ -z "$pin" || "$pin" == "$listed" ]] || die "SHASUMS256.txt disagrees with pinned hash for $name"
  fetch "$NODE_MIRROR/v$NODE_VERSION/$name" "$dir/$name" "$listed"
  printf '%s' "$dir/$name"
}

termux_deb() {  # $1 = package, $2 = version, $3 = termux arch; echoes path
  local pkg="$1" ver="$2" arch="$3" name="$1_$2_$3.deb"
  local dest="$CACHE/termux/$name" pin; pin="$(pin_of "$name")"
  if [[ -f "$dest" && -n "$pin" && "$(sha256 "$dest")" == "$pin" ]]; then printf '%s' "$dest"; return; fi
  # Resolve pool path + hash from the current Packages index (verifies index -> deb).
  local idx="$CACHE/termux/Packages-$arch"
  fetch "$TERMUX_REPO/dists/stable/main/binary-$arch/Packages" "$idx.new" && mv "$idx.new" "$idx"
  local rec; rec="$(awk -v RS= -v p="$pkg" -v v="$ver" \
    '$0 ~ "(^|\n)Package: " p "\n" && $0 ~ "\nVersion: " v "\n"' "$idx")"
  if [[ -z "$rec" ]]; then
    # Termux keeps only the current build in its pool, so the pin goes stale on every
    # upstream rebuild. Print what the index actually offers instead of making the next
    # person page through a 1.8 MB Packages file: fixing this is then a copy-paste.
    printf '\033[1;31m[runtime] error:\033[0m Termux index no longer has %s %s for %s\n' \
      "$pkg" "$ver" "$arch" >&2
    printf '  current in index:\n' >&2
    awk -v RS= -v p="$pkg" '$0 ~ "(^|\n)Package: " p "\n"' "$idx" \
      | sed -n 's/^Version: /    version /p; s/^SHA256: /    sha256  /p' >&2
    die "bump the pin in build-runtime.sh (name = ${pkg}_<version>_${arch}.deb)"
  fi
  local file sum; file="$(sed -n 's/^Filename: //p' <<<"$rec")"; sum="$(sed -n 's/^SHA256: //p' <<<"$rec")"
  [[ -z "$pin" || "$pin" == "$sum" ]] || die "Termux index hash for $name differs from pin"
  fetch "$TERMUX_REPO/$file" "$dest" "$sum"
  printf '%s' "$dest"
}

# Re-resolve a package whose pinned pool file has vanished from every mirror.
# Ubuntu deletes a superseded .deb from pool/ as soon as a newer upload lands in the same
# suite, so a lockfile that pins a filename byte for byte starts 404ing months later -- which
# is exactly how the first green cloud run died (ca-certificates 20260816ubuntu0.24.04.1_all
# was gone from both archive and ports). Re-pinning by hand only postpones the same failure,
# so ask the signed indexes for the current file instead: InRelease -> gpgv -> Packages.xz ->
# deb, the same chain of trust as the initial resolve. We stop pretending that a mutable pool
# is immutable; the archive keyring still vouches for the bytes.
# Echoes "<package>\t<filename>\t<sha256>\t<version>".
ubuntu_repin() {  # $1 = mirror, $2 = index arch, $3 = base tarball, $4... = package names
  local mirror="$1" index_arch="$2" base="$3"; shift 3
  command -v gpgv >/dev/null || die "gpgv is required to re-resolve a stale pin"
  local dir="$CACHE/ubuntu/repin-$index_arch"; mkdir -p "$dir"
  if [[ ! -f "$dir/archive-keyring.gpg" ]]; then
    python3 -I - "$base" "$dir/archive-keyring.gpg" <<'PYEOF'
import sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as t:
    for m in t:
        if m.name.lstrip("./") == "usr/share/keyrings/ubuntu-archive-keyring.gpg":
            open(sys.argv[2], "wb").write(t.extractfile(m).read()); break
    else:
        sys.exit("keyring not found in base tarball")
PYEOF
  fi
  local -a idx=() pkgs=(); local suite want p base_url usable=0
  for p in "$@"; do pkgs+=(--package "$p"); done
  for suite in noble noble-updates noble-security; do
    # Security metadata belongs to the security host. Asking the archive for it gets a copy
    # that disagrees with the Packages file it comes with (or an HTML error page), which is
    # exactly how this path died the first time it ran.
    [[ "$suite" == noble-security ]] && base_url="$UBUNTU_SECURITY_ARCHIVE" || base_url="$mirror"
    if ! fetch_try "$base_url/dists/$suite/InRelease" "$dir/$suite.InRelease"; then
      log "  $suite: no InRelease from $base_url; working without it"
      continue
    fi
    gpgv --keyring "$dir/archive-keyring.gpg" "$dir/$suite.InRelease" 2>/dev/null || {
      log "  $suite: InRelease failed its signature check; working without it"
      continue
    }
    want="$(awk -v f="main/binary-$index_arch/Packages.xz" '/^SHA256:/{s=1;next} /^[A-Za-z]/{s=0} s && $3==f {print $1}' "$dir/$suite.InRelease")"
    [[ -n "$want" ]] || { log "  $suite: no Packages.xz hash for $index_arch"; continue; }
    if ! fetch_try "$base_url/dists/$suite/main/binary-$index_arch/Packages.xz" "$dir/$suite.Packages.xz" "$want"; then
      log "  $suite: Packages.xz does not match its InRelease; working without it"
      continue
    fi
    idx+=(--packages "$dir/$suite.Packages.xz"); usable=1
  done
  [[ "$usable" == 1 ]] || die "no verifiable Ubuntu index for $index_arch while re-pinning $*"
  "${PY[@]}" repin --arch "$index_arch" "${idx[@]}" "${pkgs[@]}"
}

# Extra Ubuntu noble packages (tzdata, ca-certificates, git and their dependency closure).
# Chain of trust: InRelease of noble / noble-updates / noble-security verified with gpgv against
# ubuntu-archive-keyring.gpg from the checksum-verified Ubuntu Base tarball -> Packages.xz hash
# -> each .deb hash. The resolved set is pinned in runtime/locks/ubuntu-noble-<arch>.json
# (re-resolve with UPDATE_DEB_LOCK=1).
ubuntu_extra_debs() {  # $1 = ubuntu arch, $2 = verified base tarball; echoes deb paths, one per line
  local arch="$1" base="$2" lock="$LOCKS/ubuntu-noble-$1.json" mirror
  [[ "$arch" == amd64 ]] && mirror="$UBUNTU_ARCHIVE_AMD64" || mirror="$UBUNTU_ARCHIVE_ARM64"
  if [[ ! -f "$lock" || "${UPDATE_DEB_LOCK:-0}" == 1 ]] || \
     ! python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["want"] != sys.argv[2].split())' "$lock" "$UBUNTU_EXTRA"; then
    command -v gpgv >/dev/null || die "gpgv is required to resolve Ubuntu packages"
    local dir="$CACHE/ubuntu/dists-$arch"; rm -rf "$dir"; mkdir -p "$dir"
    python3 -I - "$base" "$dir/archive-keyring.gpg" <<'PYEOF'
import sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as t:
    for m in t:
        if m.name.lstrip("./") == "usr/share/keyrings/ubuntu-archive-keyring.gpg":
            open(sys.argv[2], "wb").write(t.extractfile(m).read()); break
    else:
        sys.exit("keyring not found in base tarball")
PYEOF
    local -a idx=() ; local suite want
    for suite in noble noble-updates noble-security; do
      fetch "$mirror/dists/$suite/InRelease" "$dir/$suite.InRelease"
      gpgv --keyring "$dir/archive-keyring.gpg" "$dir/$suite.InRelease" 2>/dev/null \
        || die "InRelease signature check failed for $suite"
      want="$(awk -v f="main/binary-$arch/Packages.xz" '/^SHA256:/{s=1;next} /^[A-Za-z]/{s=0} s && $3==f {print $1}' "$dir/$suite.InRelease")"
      [[ -n "$want" ]] || die "no Packages.xz hash for $suite/$arch"
      fetch "$mirror/dists/$suite/main/binary-$arch/Packages.xz" "$dir/$suite.Packages.xz" "$want"
      idx+=(--packages "$dir/$suite.Packages.xz")
    done
    mkdir -p "$LOCKS"
    # shellcheck disable=SC2086
    "${PY[@]}" resolve-debs --base "$base" --arch "$arch" "${idx[@]}" --want $UBUNTU_EXTRA --out "$lock" >&2
  fi
  local name file sum arch_of pkg
  while IFS=$'\t' read -r pkg file sum arch_of; do
    name="$(basename "$file")"
    # Architecture: all lives in the primary archive only; the ports mirror has just the
    # ports architectures. Both are tried either way, sha256 decides.
    local -a urls=()
    if [[ "$arch_of" == all ]]; then
      urls+=("$UBUNTU_ARCHIVE_AMD64/$file" "$mirror/$file")
    else
      urls+=("$mirror/$file" "$UBUNTU_ARCHIVE_AMD64/$file")
    fi
    local pool
    for pool in $UBUNTU_EXTRA_POOLS; do urls+=("$pool/$file"); done
    if ! fetch_any "$CACHE/ubuntu/debs/$name" "$sum" "${urls[@]}"; then
      # The pin rotted: Ubuntu dropped this file from pool/ when a newer one was uploaded.
      local index_arch index_mirror rec newfile newsum
      [[ "$arch_of" == all ]] && index_arch=amd64 || index_arch="$arch"
      [[ "$index_arch" == amd64 ]] && index_mirror="$UBUNTU_ARCHIVE_AMD64" || index_mirror="$mirror"
      rec="$(ubuntu_repin "$index_mirror" "$index_arch" "$base" "$pkg")" \
        || die "no mirror serves $name and the index no longer lists $pkg"
      # The index may name an upload whose .deb has not reached a pool we can read yet
      # (security publishes to security.ubuntu.com before the archive mirrors catch up),
      # so walk down the versions it offers instead of dying on the newest one.
      local ok=0
      while IFS=$'\t' read -r _ newfile newsum _; do
        [[ -n "${newfile:-}" ]] || continue
        name="$(basename "$newfile")"
        local -a pool_urls=("$UBUNTU_SECURITY_ARCHIVE/$newfile" "$UBUNTU_ARCHIVE_AMD64/$newfile" "$mirror/$newfile")
        local pool
        for pool in $UBUNTU_EXTRA_POOLS; do pool_urls+=("$pool/$newfile"); done
        if fetch_any "$CACHE/ubuntu/debs/$name" "$newsum" "${pool_urls[@]}"; then
          log "stale pin: $pkg re-resolved to $name"
          ok=1
          break
        fi
        log "  $name is listed but not downloadable yet; trying the next version"
      done <<<"$rec"
      [[ "$ok" == 1 ]] || die "index lists $pkg but no mirror serves any of its files"
    fi
    printf '%s\n' "$CACHE/ubuntu/debs/$name"
  done < <(python3 -I -c 'import json,sys; [print("\t".join((p["package"], p["filename"], p["sha256"], p["architecture"]))) for p in json.load(open(sys.argv[1]))["packages"]]' "$lock")
}

# Relocatable CPython (python-build-standalone, install_only_stripped). Checksums come from the
# release's SHA256SUMS on GitHub; the tarball itself may come from the npmmirror copy.
python_dist() {  # $1 = aarch64|x86_64; echoes path
  local name="cpython-${PYTHON_VERSION}+${PBS_RELEASE}-$1-unknown-linux-gnu-install_only_stripped.tar.gz"
  local dir="$CACHE/python/$PBS_RELEASE" pin; pin="$(pin_of "$name")"
  if [[ -f "$dir/$name" && -n "$pin" && "$(sha256 "$dir/$name")" == "$pin" ]]; then printf '%s' "$dir/$name"; return; fi
  fetch "$PBS_OFFICIAL/$PBS_RELEASE/SHA256SUMS" "$dir/SHA256SUMS"
  local listed; listed="$(awk -v f="$name" '$2==f {print $1}' "$dir/SHA256SUMS")"
  [[ -n "$listed" ]] || die "$name not in SHA256SUMS of $PBS_RELEASE"
  [[ -z "$pin" || "$pin" == "$listed" ]] || die "SHA256SUMS disagrees with pinned hash for $name"
  fetch "$PBS_MIRROR/$PBS_RELEASE/$name" "$dir/$name" "$listed" 2>/dev/null \
    || fetch "$PBS_OFFICIAL/$PBS_RELEASE/$name" "$dir/$name" "$listed"
  printf '%s' "$dir/$name"
}

# Node used to run npm on the build host (the official x64 build; never the foreign one).
host_npm() {
  if [[ "$(uname -m)" == "x86_64" ]]; then
    local tarball; tarball="$(node_dist x64)"
    local dir="$CACHE/host-node/node-v${NODE_VERSION}-linux-x64"
    if [[ ! -x "$dir/bin/node" ]]; then
      mkdir -p "$CACHE/host-node"; tar -xJf "$tarball" -C "$CACHE/host-node"
    fi
    printf '%s' "$dir/bin"
  else
    command -v npm >/dev/null || die "non-x86_64 host without npm on PATH"
    dirname "$(command -v npm)"
  fi
}

# ---------------------------------------------------------------------------
# DSH npm tree
# ---------------------------------------------------------------------------
# npm flags for a host-side install into a prefix (no user/global config, no scripts).
npm_prefix_flags() {  # $1 = npm cpu, $2 = prefix dir; sets the caller's npm_flags array
  : > "$WORK/empty-user-npmrc"; : > "$WORK/empty-global-npmrc"
  npm_flags=(
    --prefix "$2" --cpu="$1" --os=linux --libc=glibc
    --registry="$NPM_REGISTRY" --cache "$CACHE/npm"
    # The lockfile's `resolved` URLs name the mirror they were pinned from. Without this npm
    # ignores --registry and still fetches them, so a build on another network cannot switch.
    # With it the host is rewritten to --registry and the lockfile's integrity check still
    # decides whether the bytes are right.
    --replace-registry-host=always
    --userconfig "$WORK/empty-user-npmrc" --globalconfig "$WORK/empty-global-npmrc"
    --ignore-scripts --no-audit --no-fund --update-notifier=false --loglevel=warn
  )
}

install_dsh() {  # $1 = npm cpu, $2 = prefix dir
  local cpu="$1" prefix="$2" bin; bin="$(host_npm)"
  local lockdir="$LOCKS/dsh-$DSH_VERSION"
  rm -rf "$prefix"; mkdir -p "$prefix"
  local -a npm_flags=(); npm_prefix_flags "$cpu" "$prefix"
  if [[ -f "$lockdir/package-lock.json" ]]; then
    log "npm ci @deepseek-ai/dsh@$DSH_VERSION (cpu=$cpu, pinned lock)"
    cp "$lockdir/package.json" "$lockdir/package-lock.json" "$prefix/"
    PATH="$bin:$PATH" npm ci "${npm_flags[@]}"
  else
    log "npm install @deepseek-ai/dsh@$DSH_VERSION (cpu=$cpu) — first run, will pin the lock"
    PATH="$bin:$PATH" npm install "${npm_flags[@]}" --save-exact "@deepseek-ai/dsh@$DSH_VERSION"
    # npm nests an exact-pinned dependency in every dependent when another version wins the top
    # level (0.2.1-rc.2: 50 copies of zod 4.4.3, ~26k files). Pin those as direct dependencies so
    # one copy is hoisted, then reinstall.
    local -a hoist=(); mapfile -t hoist < <("${PY[@]}" hoist-candidates "$prefix/package-lock.json")
    if [[ ${#hoist[@]} -gt 0 ]]; then
      log "hoisting duplicated exact dependencies: ${hoist[*]}"
      PATH="$bin:$PATH" npm install "${npm_flags[@]}" --save-exact "@deepseek-ai/dsh@$DSH_VERSION" "${hoist[@]}"
    fi
    mkdir -p "$lockdir"
    cp "$prefix/package.json" "$prefix/package-lock.json" "$lockdir/"
  fi
  local got; got="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' \
    "$prefix/node_modules/@deepseek-ai/dsh/package.json")"
  [[ "$got" == "$DSH_VERSION" ]] || die "installed dsh $got != $DSH_VERSION"
}

# pnpm for the guest (zero dependencies, plain JS). Same lock-then-`npm ci` scheme as DSH; the
# lock's integrity must equal PNPM_INTEGRITY, so a regenerated lock cannot swap the tarball.
install_pnpm() {  # $1 = npm cpu, $2 = prefix dir
  local cpu="$1" prefix="$2" bin; bin="$(host_npm)"
  local lockdir="$LOCKS/pnpm-$PNPM_VERSION"
  rm -rf "$prefix"; mkdir -p "$prefix"
  local -a npm_flags=(); npm_prefix_flags "$cpu" "$prefix"
  if [[ -f "$lockdir/package-lock.json" ]]; then
    log "npm ci pnpm@$PNPM_VERSION (pinned lock)"
    cp "$lockdir/package.json" "$lockdir/package-lock.json" "$prefix/"
    PATH="$bin:$PATH" npm ci "${npm_flags[@]}"
  else
    log "npm install pnpm@$PNPM_VERSION — first run, will pin the lock"
    PATH="$bin:$PATH" npm install "${npm_flags[@]}" --save-exact "pnpm@$PNPM_VERSION"
    mkdir -p "$lockdir"
    cp "$prefix/package.json" "$prefix/package-lock.json" "$lockdir/"
  fi
  python3 -I - "$prefix" "$PNPM_VERSION" "$PNPM_INTEGRITY" <<'PYEOF' || die "pnpm lock/install does not match the pins"
import json, os, sys
prefix, version, integrity = sys.argv[1:4]
lock = json.load(open(os.path.join(prefix, "package-lock.json")))
pkgs = lock["packages"]
entry = pkgs.get("node_modules/pnpm", {})
others = sorted(k for k in pkgs if k not in ("", "node_modules/pnpm"))
got = json.load(open(os.path.join(prefix, "node_modules/pnpm/package.json")))["version"]
ok = entry.get("version") == version and entry.get("integrity") == integrity and got == version and not others
print("pnpm lock: version=%s integrity=%s... installed=%s extra=%s -> %s" % (
    entry.get("version"), (entry.get("integrity") or "")[:20], got, others, "ok" if ok else "MISMATCH"), file=sys.stderr)
sys.exit(0 if ok else 1)
PYEOF
}

# ---------------------------------------------------------------------------
# per-ABI build
# ---------------------------------------------------------------------------
# jniLibs: Termux binaries, renamed lib*.so so the package manager extracts
# them and they stay executable on the device. Split out of [build_abi] so the
# prebuilt-base shortcut can rebuild them on its own (2026-11-10: the shortcut
# shipped an APK without libproot.so because only the full assemble made them).
build_jni_libs() {  # $1=abi $2=termux_arch $3=work $4=assets $5=jni
  local abi="$1" termux_arch="$2" work="$3" assets="$4" jni="$5"
  local proot_deb talloc_deb shmem_deb proot_src
  proot_deb="$(termux_deb proot "$PROOT_VERSION" "$termux_arch")"
  talloc_deb="$(termux_deb libtalloc "$TALLOC_VERSION" "$termux_arch")"
  shmem_deb="$(termux_deb libandroid-shmem "$SHMEM_VERSION" "$termux_arch")"
  proot_src="$CACHE/termux/proot-v$PROOT_VERSION.zip"
  fetch "https://github.com/termux/proot/archive/v$PROOT_VERSION.zip" "$proot_src" "$(pin_of "proot-v$PROOT_VERSION.zip")"

  local debx="$work/debs"; rm -rf "$debx"
  local d
  for d in "$proot_deb" "$talloc_deb" "$shmem_deb"; do "${PY[@]}" deb-extract "$d" "$debx"; done
  local tprefix="$debx/data/data/com.termux/files/usr"
  cp "$tprefix/bin/proot"                  "$jni/libproot.so"
  cp "$tprefix/libexec/proot/loader"       "$jni/libproot-loader.so"
  cp "$tprefix/lib/libtalloc.so.$TALLOC_VERSION" "$jni/libtalloc.so"
  cp "$tprefix/lib/libandroid-shmem.so"    "$jni/libandroid-shmem.so"
  local orig_proot orig_talloc
  orig_proot="$(sha256 "$jni/libproot.so")"; orig_talloc="$(sha256 "$jni/libtalloc.so")"
  # APKs can only carry lib*.so, so the DT_NEEDED/SONAME "libtalloc.so.2" becomes "libtalloc.so".
  "${PY[@]}" patch-dynstr "$jni/libproot.so" libtalloc.so.2 libtalloc.so >&2
  "${PY[@]}" patch-dynstr "$jni/libtalloc.so" libtalloc.so.2 libtalloc.so >&2
  chmod 0755 "$jni"/*.so
  "${PY[@]}" elf-info "$jni"/*.so > "$work/jni-elf.json"

  python3 -I - "$jni" "$work/jni-elf.json" "$work/jnilibs.json" <<PYEOF
import hashlib, json, os, sys
jni, elf, out = sys.argv[1:4]
info = json.load(open(elf))
src = {
  "libproot.so": ("proot", "$PROOT_VERSION", "$(basename "$proot_deb")", "usr/bin/proot",
                  "DT_NEEDED libtalloc.so.2 -> libtalloc.so", "$orig_proot"),
  "libproot-loader.so": ("proot", "$PROOT_VERSION", "$(basename "$proot_deb")", "usr/libexec/proot/loader", None, None),
  "libtalloc.so": ("libtalloc", "$TALLOC_VERSION", "$(basename "$talloc_deb")", "usr/lib/libtalloc.so.$TALLOC_VERSION",
                   "DT_SONAME libtalloc.so.2 -> libtalloc.so", "$orig_talloc"),
  "libandroid-shmem.so": ("libandroid-shmem", "$SHMEM_VERSION", "$(basename "$shmem_deb")", "usr/lib/libandroid-shmem.so", None, None),
}
res = {}
for name, (pkg, ver, deb, inner, patch, orig) in src.items():
    path = os.path.join(jni, name)
    e = info[path]
    res[name] = {
        "sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(),
        "bytes": os.path.getsize(path),
        "source": "termux-main %s %s (%s:/data/data/com.termux/files/%s)" % (pkg, ver, deb, inner),
        "patch": patch, "originalSha256": orig,
        "machine": e["machine"], "type": e["type"], "needed": e.get("needed"),
        "soname": e.get("soname"), "minLoadAlign": e["minLoadAlign"],
    }
json.dump(res, open(out, "w"), indent=2)
PYEOF
  # licenses for the native bits (--jni-only 时 assets/licenses 可能不存在,先建目录)
  mkdir -p "$assets/licenses"
  python3 -I - "$proot_src" "$assets/licenses/proot-COPYING.txt" <<'PYEOF'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
name = next(n for n in z.namelist() if n.endswith("/COPYING") and n.count("/") == 1)
open(sys.argv[2], "wb").write(z.read(name))
PYEOF
  cp "$debx/data/data/com.termux/files/usr/share/doc/libandroid-shmem/copyright" "$assets/licenses/libandroid-shmem-copyright.txt"
  sed -n '1,/\*\//p' "$tprefix/include/talloc.h" > "$assets/licenses/libtalloc-notice.txt"
}

# Only (re)builds the jniLibs for one ABI, then checks every file against the
# manifest already sitting in $OUT — the prebuilt-base shortcut has the manifest
# from the full assemble, so a mismatch here means the pinned debs drifted and
# the build must fail rather than ship a proot the manifest cannot vouch for.
build_jni_only() {
  local abi="$1" termux_arch
  case "$abi" in
    arm64-v8a) termux_arch=aarch64 ;;
    x86_64)    termux_arch=x86_64 ;;
    *) die "unknown ABI $abi (use arm64-v8a or x86_64)" ;;
  esac
  local out="$OUT/$abi"
  local assets="$out/assets/runtime" jni="$out/jniLibs/$abi" work="$WORK/$abi"
  local manifest="$assets/manifest.json"
  [[ -f "$manifest" ]] || die "--jni-only: $manifest missing — run the full assemble (or fetch the prebuilt base) first"
  mkdir -p "$work" "$jni"
  build_jni_libs "$abi" "$termux_arch" "$work" "$assets" "$jni"
  python3 -I - "$manifest" "$jni" <<'PYEOF'
import hashlib, json, os, sys
manifest, jni = sys.argv[1:3]
expect = json.load(open(manifest)).get("jniLibs") or {}
if not expect:
    print("[runtime] manifest has no jniLibs section; nothing to verify", flush=True)
    raise SystemExit(0)
bad = []
for name, meta in sorted(expect.items()):
    path = os.path.join(jni, name)
    if not os.path.isfile(path):
        bad.append("%s missing" % name); continue
    got = hashlib.sha256(open(path, "rb").read()).hexdigest()
    if got != meta.get("sha256"):
        bad.append("%s sha256 %s != manifest %s" % (name, got[:12], str(meta.get("sha256"))[:12]))
if bad:
    print("[runtime] jniLibs mismatch:", "; ".join(bad), flush=True)
    raise SystemExit(1)
print("[runtime] jniLibs verified against manifest: %d files" % len(expect), flush=True)
PYEOF
}

build_abi() {
  local abi="$1" ubuntu_arch node_arch npm_cpu termux_arch elf_name
  case "$abi" in
    arm64-v8a) ubuntu_arch=arm64; node_arch=arm64; npm_cpu=arm64; termux_arch=aarch64; elf_name="ARM aarch64" ;;
    x86_64)    ubuntu_arch=amd64; node_arch=x64;   npm_cpu=x64;   termux_arch=x86_64;  elf_name="x86-64" ;;
    *) die "unknown ABI $abi (use arm64-v8a or x86_64)" ;;
  esac
  log "=== $abi ==="
  local work="$WORK/$abi" out="$OUT/$abi"
  local assets="$out/assets/runtime" jni="$out/jniLibs/$abi"
  mkdir -p "$work"
  rm -rf "$out"; mkdir -p "$assets/licenses" "$jni"

  local base node
  base="$(ubuntu_base "$ubuntu_arch")"
  node="$(node_dist "$node_arch")"
  ubuntu_extra_debs "$ubuntu_arch" "$base" > "$work/extra-debs.txt"   # set -e aborts on any failure inside
  local -a extra_debs=(); mapfile -t extra_debs < "$work/extra-debs.txt"
  [[ ${#extra_debs[@]} -gt 0 ]] || die "Ubuntu package resolution produced nothing"
  local python; python="$(python_dist "$termux_arch")"

  build_jni_libs "$abi" "$termux_arch" "$work" "$assets" "$jni"

  # -- DSH --
  local prefix="$work/dsh-prefix"
  install_dsh "$npm_cpu" "$prefix"
  log "patching DSH (runtime/patches, pinned for $DSH_VERSION)"
  "${PY[@]}" patch-dsh --prefix "$prefix" --dsh-version "$DSH_VERSION" --patches "$HERE/patches" \
    --out "$work/dsh-patches.json" >&2
  local bridge="$HERE/bridge/dsh-go-bridge"
  local bridge_version
  bridge_version="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$bridge/package.json")"
  local pnpm_prefix="$work/pnpm-prefix"
  install_pnpm "$npm_cpu" "$pnpm_prefix"

  # -- extra plugins baked in from outside the repo (EXTRA_PLUGINS, `id=path` entries) --
  # Each one is mounted at /opt/dsh-go/plugins/<id> and gets an overlay row, exactly like the
  # bridge: DSH loads it by path, so it never has to be installed into a profile.
  local plugin_json='[]'
  local -a plugin_flags=()
  if [[ -n "${EXTRA_PLUGINS// /}" ]]; then
    local entry pid ppath
    for entry in $EXTRA_PLUGINS; do
      pid="${entry%%=*}"; ppath="${entry#*=}"
      [[ -d "$ppath" ]] || die "EXTRA_PLUGINS: $pid has no directory at $ppath"
      plugin_flags+=(--plugin "$pid=$ppath")
    done
    plugin_json="$(EXTRA_PLUGINS="$EXTRA_PLUGINS" python3 -I -c '
import json, os
rows = []
for entry in os.environ["EXTRA_PLUGINS"].split():
    pid, _, path = entry.partition("=")
    with open(os.path.join(path, "package.json"), encoding="utf-8") as fh:
        meta = json.load(fh)
    rows.append({"id": pid, "package": meta.get("name"), "version": meta.get("version"),
                 "mount": "/opt/dsh-go/plugins/" + pid})
print(json.dumps(sorted(rows, key=lambda r: r["id"]), ensure_ascii=False))
')"
    log "extra plugins: $plugin_json"
  fi

  # -- runtimeVersion: hash of every input + the recipe itself --
  local lockfile="$LOCKS/dsh-$DSH_VERSION/package-lock.json"
  local pnpm_lockfile="$LOCKS/pnpm-$PNPM_VERSION/package-lock.json"
  local inputs_sha
  inputs_sha="$( {
      echo "$RUNTIME_REVISION $abi $DSH_VERSION $NODE_VERSION $PNPM_VERSION $UBUNTU_VERSION $COMPRESS $XZ_PRESET $PRUNE_DEV_METADATA $SOURCE_DATE_EPOCH"
      sha256 "$base"; sha256 "$node"; sha256 "$python"; sha256sum "${extra_debs[@]}" | cut -d' ' -f1
      sha256 "$proot_deb"; sha256 "$talloc_deb"; sha256 "$shmem_deb"
      sha256 "$lockfile"; sha256 "$pnpm_lockfile"; sha256 "$HERE/build-runtime.sh"; sha256 "$HERE/lib/rtbuild.py"
      printf '%s' "$plugin_json" | sha256sum | cut -d' ' -f1
      (cd "$HERE" && find patches bridge boot direct -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
    } | sha256sum | cut -c1-12 )"
  local runtime_version="${RUNTIME_REVISION}-dsh${DSH_VERSION}-node${NODE_VERSION}-ubuntu${UBUNTU_VERSION}-${inputs_sha}"
  local runtime_info
  runtime_info="$(printf '{"runtimeVersion":"%s","abi":"%s","dshVersion":"%s","nodeVersion":"%s","pnpmVersion":"%s","ubuntuVersion":"%s","prootVersion":"%s","dshPatches":%s,"dshGoBridge":"%s","extraPlugins":%s}' \
    "$runtime_version" "$abi" "$DSH_VERSION" "$NODE_VERSION" "$PNPM_VERSION" "$UBUNTU_VERSION" "$PROOT_VERSION" \
    "$(cat "$work/dsh-patches.json")" "$bridge_version" "$plugin_json")"

  # -- rootfs archive --
  local archive="$assets/rootfs-$abi.tar.$COMPRESS"
  local -a prune=(); [[ "$PRUNE_DEV_METADATA" == 1 ]] && prune=(--prune-dev-metadata)
  log "assembling rootfs ($COMPRESS)"
  "${PY[@]}" assemble --abi "$abi" --base "$base" --node "$node" --dsh-prefix "$prefix" --pnpm-prefix "$pnpm_prefix" \
    --out "$archive" --report "$out/build-report.json" --runtime-info "$runtime_info" \
    --compress "$COMPRESS" --xz-preset "$XZ_PRESET" --threads "$XZ_THREADS" --epoch "$SOURCE_DATE_EPOCH" "${prune[@]}" \
    "${extra_debs[@]/#/--deb=}" --python "$python" --bridge "$bridge" "${plugin_flags[@]}"

  local versions
  versions="$(printf '{"runtimeVersion":"%s","dshVersion":"%s","nodeVersion":"%s","pnpmVersion":"%s","ubuntuVersion":"%s","prootVersion":"%s","tallocVersion":"%s","androidShmemVersion":"%s","dshPatches":%s,"dshGoBridge":"%s","build":{"inputsSha256_12":"%s","ubuntuBaseSha256":"%s","nodeSha256":"%s","dshLockSha256":"%s","pnpmIntegrity":"%s","sourceDateEpoch":%s}}' \
    "$runtime_version" "$DSH_VERSION" "$NODE_VERSION" "$PNPM_VERSION" "$UBUNTU_VERSION" "$PROOT_VERSION" "$TALLOC_VERSION" "$SHMEM_VERSION" \
    "$(cat "$work/dsh-patches.json")" "$bridge_version" \
    "$inputs_sha" "$(sha256 "$base")" "$(sha256 "$node")" "$(sha256 "$lockfile")" "$PNPM_INTEGRITY" "$SOURCE_DATE_EPOCH")"
  "${PY[@]}" manifest --abi "$abi" --report "$out/build-report.json" --jnilibs "$work/jnilibs.json" \
    --versions "$versions" --out "$assets/manifest.json" >&2

  # -- verification: every jniLib and every ELF in the rootfs must match the ABI --
  local f bad=0
  for f in "$jni"/*.so; do
    file -b "$f" | grep -q "$elf_name" || { log "ABI mismatch: $f: $(file -b "$f")"; bad=1; }
  done
  python3 -I - "$out/build-report.json" "$abi" <<'PYEOF' || bad=1
import json, sys
r = json.load(open(sys.argv[1])); want = {"arm64-v8a": "aarch64", "x86_64": "x86-64"}[sys.argv[2]]
wrong = [e["path"] for e in r["elf"] if e["machine"] != want]
print("rootfs ELF objects: %d, wrong-arch: %d, warnings: %d" % (len(r["elf"]), len(wrong), len(r["warnings"])), file=sys.stderr)
sys.exit(1 if wrong else 0)
PYEOF
  [[ "$bad" == 0 ]] || die "ABI verification failed for $abi"
  log "$abi done: $(du -h "$archive" | cut -f1) archive, version $runtime_version"
}

write_index() {
  python3 -I - "$OUT" <<'PYEOF'
import json, os, sys
out = sys.argv[1]
index = {"schema": 1, "abis": {}}
for abi in ("x86_64", "arm64-v8a"):
    p = os.path.join(out, abi, "assets", "runtime", "manifest.json")
    if not os.path.isfile(p):
        continue
    m = json.load(open(p))
    index["abis"][abi] = {k: m.get(k) for k in (  # .get: another ABI may still hold an older build
        "runtimeVersion", "rootfs", "rootfsSha256", "rootfsBytes", "uncompressedBytes", "entries",
        "dshVersion", "nodeVersion", "pnpmVersion", "ubuntuVersion", "prootVersion")}
    index["abis"][abi]["jniLibs"] = {n: {"sha256": v["sha256"], "bytes": v["bytes"]} for n, v in m["jniLibs"].items()}
json.dump(index, open(os.path.join(out, "manifest.json"), "w"), indent=2)
print("wrote " + os.path.join(out, "manifest.json"))
PYEOF
}

main() {
  local jni_only=0
  local -a abis=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --jni-only) jni_only=1 ;;
      *) abis+=("$arg") ;;
    esac
  done
  [[ ${#abis[@]} -gt 0 ]] || abis=(x86_64 arm64-v8a)
  mkdir -p "$CACHE" "$WORK" "$OUT"
  local abi
  if [[ $jni_only == 1 ]]; then
    # Prebuilt-base shortcut: the rootfs+manifest already exist, only the
    # Termux binaries are missing. Never touch the assets here.
    for abi in "${abis[@]}"; do build_jni_only "$abi"; done
    return
  fi
  for abi in "${abis[@]}"; do build_abi "$abi"; done
  write_index
}

main "$@"
