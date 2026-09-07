#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR"

VERSION_FILE="$ROOT_DIR/NGINX_VERSION"

[ -f "$VERSION_FILE" ] || {
  echo "ERROR: NGINX_VERSION file not found: $VERSION_FILE" >&2
  exit 1
}

NGINX_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"

SRC_DIR="${SRC_DIR:-$ROOT_DIR/src}"
NPROC="${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)}"


# =============================================================================
# Helpers
# =============================================================================

log() {
  printf '\n>>> %s\n' "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

clone_module() {
  local url="$1"
  local dir="${2:-}"
  local with_submodules="${3:-}"

  if [ -z "$dir" ]; then
    dir="${url##*/}"
    dir="${dir%.git}"
  fi

  if [ -d "$dir/.git" ]; then
    log "reuse $dir"
  else
    git clone --depth=1 "$url" "$dir"
  fi

  if [ "$with_submodules" = "submodules" ]; then
    (
      cd "$dir"
      git submodule update \
        --init \
        --recursive \
        --depth=1
    )
  fi
}

download_and_extract() {
  local url="$1"
  local out="${2:-${url##*/}}"
  local extracted="${out%.tar.gz}"

  if [ -d "$extracted" ]; then
    log "reuse $extracted"
    return 0
  fi

  wget -O "$out" "$url"
  tar -xf "$out"
}


# =============================================================================
# Verify nginx version
# =============================================================================

log "verify nginx version"

if ! printf '%s\n' "$NGINX_VERSION" |
  grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  fail "invalid NGINX_VERSION: $NGINX_VERSION"
fi

printf 'nginx version: %s\n' "$NGINX_VERSION"


# =============================================================================
# Require Alpine/musl build environment
# =============================================================================

log "verify Alpine build environment"

if ! command -v apk >/dev/null 2>&1; then
  fail "build_static.sh must run inside Alpine Linux"
fi


# =============================================================================
# Build dependencies
# =============================================================================

log "install build dependencies"

apk add --no-cache \
  bash \
  build-base \
  linux-headers \
  musl-dev \
  libstdc++-dev \
  libgcc-static \
  git \
  wget \
  curl \
  ca-certificates \
  perl \
  cmake \
  samurai \
  pkgconf \
  autoconf \
  automake \
  libtool \
  ccache \
  go \
  binutils \
  file


# =============================================================================
# ccache
# =============================================================================

log "configure ccache"

if command -v ccache >/dev/null 2>&1; then
  if [ -d /usr/lib/ccache/bin ]; then
    export PATH="/usr/lib/ccache/bin:$PATH"
  elif [ -d /usr/lib/ccache ]; then
    export PATH="/usr/lib/ccache:$PATH"
  fi

  ccache --set-config=max_size="${CCACHE_MAXSIZE:-2G}"

  ccache --zero-stats || true
fi


# =============================================================================
# Verify static runtime archives
# =============================================================================

log "verify static musl/GCC/C++ runtime archives"

MUSL_LIBC_A="$(gcc -print-file-name=libc.a)"
LIBSTDCXX_A="$(g++ -print-file-name=libstdc++.a)"
LIBGCC_A="$(gcc -print-libgcc-file-name)"

[ "$MUSL_LIBC_A" != "libc.a" ] &&
  [ -f "$MUSL_LIBC_A" ] ||
  fail "static musl libc.a not found; check musl-dev"

[ "$LIBSTDCXX_A" != "libstdc++.a" ] &&
  [ -f "$LIBSTDCXX_A" ] ||
  fail "static libstdc++.a not found; check libstdc++-dev"

[ -f "$LIBGCC_A" ] ||
  fail "static libgcc archive not found; check libgcc-static"

printf 'musl libc.a:   %s\n' "$MUSL_LIBC_A"
printf 'libstdc++.a:   %s\n' "$LIBSTDCXX_A"
printf 'libgcc:        %s\n' "$LIBGCC_A"


# =============================================================================
# Source directory
# =============================================================================

log "prepare source directory"

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"


# =============================================================================
# nginx
# =============================================================================

log "download nginx-$NGINX_VERSION"

download_and_extract \
  "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"

NGINX_SRC_DIR="$SRC_DIR/nginx-$NGINX_VERSION"
MODULES_DIR="$NGINX_SRC_DIR/modules"

[ -d "$NGINX_SRC_DIR" ] ||
  fail "nginx source directory not found: $NGINX_SRC_DIR"

mkdir -p "$MODULES_DIR"

cd "$MODULES_DIR"


# =============================================================================
# ngx_brotli + Brotli
# =============================================================================

log "clone ngx_brotli"

clone_module \
  "https://github.com/google/ngx_brotli" \
  "ngx_brotli" \
  "submodules"

BROTLI_DIR="$MODULES_DIR/ngx_brotli/deps/brotli"
BROTLI_BUILD_DIR="$BROTLI_DIR/out"

[ -f "$BROTLI_DIR/c/include/brotli/encode.h" ] ||
  fail "ngx_brotli Brotli submodule is missing"

log "build Brotli static libraries"

# ngx_brotli expects the static libraries under deps/brotli/out.
# Recreate the build directory to avoid stale CMake state.
rm -rf "$BROTLI_BUILD_DIR"

cmake \
  -S "$BROTLI_DIR" \
  -B "$BROTLI_BUILD_DIR" \
  -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBROTLI_BUILD_TOOLS=OFF \
  -DBROTLI_DISABLE_TESTS=ON \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache

cmake \
  --build "$BROTLI_BUILD_DIR" \
  --parallel "$NPROC" \
  --target brotlienc

BROTLI_ENC_A="$BROTLI_BUILD_DIR/libbrotlienc.a"
BROTLI_COMMON_A="$BROTLI_BUILD_DIR/libbrotlicommon.a"

[ -f "$BROTLI_ENC_A" ] ||
  fail "libbrotlienc.a not found: $BROTLI_ENC_A"

[ -f "$BROTLI_COMMON_A" ] ||
  fail "libbrotlicommon.a not found: $BROTLI_COMMON_A"

log "Brotli static libraries"

ls -lh \
  "$BROTLI_ENC_A" \
  "$BROTLI_COMMON_A"


# =============================================================================
# Cloudflare zlib
# =============================================================================

log "clone Cloudflare zlib"

clone_module \
  "https://github.com/cloudflare/zlib" \
  "zlib"

make \
  -C zlib \
  -f Makefile.in \
  distclean \
  >/dev/null 2>&1 ||
  true


# =============================================================================
# PCRE2
# =============================================================================

log "clone PCRE2"

clone_module \
  "https://github.com/PCRE2Project/pcre2" \
  "pcre2" \
  "submodules"

(
  cd pcre2

  if [ ! -f configure ]; then
    ./autogen.sh
  fi
)


# =============================================================================
# BoringSSL
# =============================================================================

log "clone BoringSSL"

clone_module \
  "https://github.com/google/boringssl" \
  "boringssl"

BORINGSSL_DIR="$MODULES_DIR/boringssl"
BORINGSSL_BUILD_DIR="$BORINGSSL_DIR/build"

[ -f "$BORINGSSL_DIR/include/openssl/ssl.h" ] ||
  fail "BoringSSL headers not found"

log "build BoringSSL static libraries"

# Only libssl.a and libcrypto.a are required by nginx.
# Do not build BoringSSL's large test suite.
rm -rf "$BORINGSSL_BUILD_DIR"

cmake \
  -S "$BORINGSSL_DIR" \
  -B "$BORINGSSL_BUILD_DIR" \
  -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache

cmake \
  --build "$BORINGSSL_BUILD_DIR" \
  --parallel "$NPROC" \
  --target ssl crypto


# =============================================================================
# Locate BoringSSL artifacts
# =============================================================================

log "locate BoringSSL artifacts"

LIBSSL_A="$(
  find "$BORINGSSL_BUILD_DIR" \
    -type f \
    -name libssl.a \
    -print \
    -quit
)"

LIBCRYPTO_A="$(
  find "$BORINGSSL_BUILD_DIR" \
    -type f \
    -name libcrypto.a \
    -print \
    -quit
)"

[ -n "$LIBSSL_A" ] &&
  [ -f "$LIBSSL_A" ] ||
  fail "libssl.a not found under $BORINGSSL_BUILD_DIR"

[ -n "$LIBCRYPTO_A" ] &&
  [ -f "$LIBCRYPTO_A" ] ||
  fail "libcrypto.a not found under $BORINGSSL_BUILD_DIR"

LIBSSL_DIR="$(dirname "$LIBSSL_A")"
LIBCRYPTO_DIR="$(dirname "$LIBCRYPTO_A")"

printf 'libssl.a:      %s\n' "$LIBSSL_A"
printf 'libcrypto.a:   %s\n' "$LIBCRYPTO_A"
printf 'libssl dir:    %s\n' "$LIBSSL_DIR"
printf 'libcrypto dir: %s\n' "$LIBCRYPTO_DIR"


# =============================================================================
# nginx configure
# =============================================================================

cd "$NGINX_SRC_DIR"

# Remove an old nginx object tree if the source directory was reused.
rm -rf objs

#
# Keep CC/LD options on ONE logical shell line.
#
# nginx configure performs several compiler/linker probes through eval.
# Embedded newlines in --with-cc-opt / --with-ld-opt can break those probes.
#

NGINX_CC_OPT="-O2 -fno-pie -fstack-protector-strong -Wformat -Werror=format-security -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -ffunction-sections -fdata-sections -I$BORINGSSL_DIR/include"

#
# nginx's OpenSSL detection adds:
#
#   -lssl -lcrypto
#
# itself.
#
# BoringSSL may place libssl.a and libcrypto.a in different directories.
# Therefore both actual library directories must be supplied with -L.
#
# The explicit static archive group ensures BoringSSL's C++ references can
# resolve against libstdc++.a regardless of static archive ordering.
#

NGINX_LD_OPT="-static -no-pie -pthread -Wl,-z,relro -Wl,--gc-sections -L$LIBSSL_DIR -L$LIBCRYPTO_DIR -Wl,--start-group $LIBSSL_A $LIBCRYPTO_A $LIBSTDCXX_A -Wl,--end-group -static-libgcc"

log "configure nginx"

./configure \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/run/nginx.pid \
  --lock-path=/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nobody \
  --group=nobody \
  \
  --with-compat \
  --with-control-api \
  --with-file-aio \
  --with-threads \
  \
  --with-http_addition_module \
  --with-http_auth_request_module \
  --with-http_dav_module \
  --with-http_flv_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_json_module \
  --with-http_mp4_module \
  --with-http_random_index_module \
  --with-http_realip_module \
  --with-http_secure_link_module \
  --with-http_slice_module \
  --with-http_ssl_module \
  --with-http_stub_status_module \
  --with-http_sub_module \
  --with-http_v2_module \
  --with-http_v3_module \
  \
  --with-stream \
  --with-stream_realip_module \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  \
  --with-cc-opt="$NGINX_CC_OPT" \
  --with-ld-opt="$NGINX_LD_OPT" \
  \
  --with-pcre="modules/pcre2" \
  --with-pcre-opt="-O2 -fno-pie -no-pie -ffunction-sections -fdata-sections" \
  --with-pcre-jit \
  \
  --with-zlib="modules/zlib" \
  --with-zlib-opt="-O2 -fno-pie -no-pie -ffunction-sections -fdata-sections" \
  \
  --add-module="modules/ngx_brotli"


# =============================================================================
# Build nginx
# =============================================================================

log "build nginx"

make -j"$NPROC"

NGINX_BIN="$NGINX_SRC_DIR/objs/nginx"

[ -x "$NGINX_BIN" ] ||
  fail "nginx binary not found: $NGINX_BIN"


# =============================================================================
# Verify required modules
# =============================================================================

log "verify required modules"

NGINX_BUILD_INFO="$("$NGINX_BIN" -V 2>&1)"

printf '%s\n' "$NGINX_BUILD_INFO"

for module in \
  --with-control-api \
  --with-http_json_module \
  --with-http_slice_module \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module
do
  printf '%s\n' "$NGINX_BUILD_INFO" |
    grep -Fq -- "$module" ||
    fail "required nginx module/configure option missing: $module"
done

printf '%s\n' "$NGINX_BUILD_INFO" |
  grep -Fq -- '--add-module=modules/ngx_brotli' ||
  fail "ngx_brotli module missing"

log "required modules enabled"


# =============================================================================
# Verify unstripped binary
# =============================================================================

log "binary information"

file "$NGINX_BIN"

log "verify fully static ELF"

if readelf -l "$NGINX_BIN" |
  grep -q 'Requesting program interpreter'; then

  readelf -l "$NGINX_BIN" |
    grep 'Requesting program interpreter' ||
    true

  fail "static nginx unexpectedly has a PT_INTERP dynamic loader"
fi

NEEDED_LIBS="$(
  readelf -d "$NGINX_BIN" 2>/dev/null |
    sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' ||
    true
)"

if [ -n "$NEEDED_LIBS" ]; then
  printf '%s\n' "$NEEDED_LIBS" >&2

  fail "static nginx still has DT_NEEDED shared-library dependencies"
fi

if ! file "$NGINX_BIN" |
  grep -qi 'statically linked'; then

  fail "file(1) does not report a statically linked executable"
fi

log "ldd output (expected to reject a static executable)"

ldd "$NGINX_BIN" 2>&1 || true


# =============================================================================
# Copy + strip final artifact
# =============================================================================

log "copy and strip final nginx binary"

FINAL_BIN="$ROOT_DIR/nginx"

rm -f \
  "$FINAL_BIN" \
  "$ROOT_DIR/nginx.sha256"

cp -f \
  "$NGINX_BIN" \
  "$FINAL_BIN"

chmod 0755 "$FINAL_BIN"

strip \
  --strip-unneeded \
  "$FINAL_BIN"


# =============================================================================
# Verify stripped artifact
# =============================================================================

log "verify final nginx binary"

"$FINAL_BIN" -V

if readelf -l "$FINAL_BIN" |
  grep -q 'Requesting program interpreter'; then

  fail "stripped nginx unexpectedly has a PT_INTERP dynamic loader"
fi

FINAL_NEEDED="$(
  readelf -d "$FINAL_BIN" 2>/dev/null |
    sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' ||
    true
)"

[ -z "$FINAL_NEEDED" ] ||
  fail "stripped nginx still has DT_NEEDED dependencies: $FINAL_NEEDED"

file "$FINAL_BIN" |
  grep -qi 'statically linked' ||
  fail "stripped nginx is not reported as statically linked"


# =============================================================================
# Artifact metadata
# =============================================================================

log "final artifact"

ls -lh "$FINAL_BIN"

(
  cd "$ROOT_DIR"
  sha256sum nginx > nginx.sha256
)

cat "$ROOT_DIR/nginx.sha256"


# =============================================================================
# ccache stats
# =============================================================================

if command -v ccache >/dev/null 2>&1; then
  log "ccache stats"

  ccache --show-stats || true
fi


# =============================================================================
# Summary
# =============================================================================

cat <<EOF

============================================================
Build complete.

Nginx version:
  $NGINX_VERSION

Original binary:
  $NGINX_BIN

Final stripped binary:
  $FINAL_BIN

SHA256:
  $ROOT_DIR/nginx.sha256

Expected runtime model:
  musl             static
  BoringSSL        static
  PCRE2            static
  Cloudflare zlib  static
  Brotli           static
  libstdc++        static
  libgcc           static

Expected ELF properties:
  PT_INTERP: none
  DT_NEEDED: none

The binary can be used as the executable in a scratch image.

Runtime configuration/data files such as nginx.conf, certificates,
writable temporary directories and passwd/group are separate from
the ELF itself.

============================================================

EOF
