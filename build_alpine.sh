#!/usr/bin/env bash
set -Eeuo pipefail

NGINX_VERSION="${NGINX_VERSION:-1.31.3}"

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SRC_DIR:-$ROOT_DIR/src}"
NPROC="${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)}"

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
      git submodule update --init --recursive --depth=1
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
# Alpine
# =============================================================================

log "verify Alpine build environment"

if ! command -v apk >/dev/null 2>&1; then
  fail "build_alpine.sh must run inside Alpine Linux"
fi


# =============================================================================
# Build dependencies
# =============================================================================

log "install build dependencies"

apk add --no-cache \
  bash \
  build-base \
  linux-headers \
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
  libstdc++-dev \
  libgcc-static


# =============================================================================
# ccache
# =============================================================================

if command -v ccache >/dev/null 2>&1; then
  if [ -d /usr/lib/ccache/bin ]; then
    export PATH="/usr/lib/ccache/bin:$PATH"
  fi

  ccache --set-config=max_size="${CCACHE_MAXSIZE:-2G}"
fi


# =============================================================================
# Static GCC / C++ runtime
# =============================================================================

log "verify static GCC/C++ runtimes"

LIBSTDCXX_A="$(g++ -print-file-name=libstdc++.a)"
LIBGCC_A="$(gcc -print-libgcc-file-name)"

[ -f "$LIBSTDCXX_A" ] || \
  fail "static libstdc++ not found: $LIBSTDCXX_A"

[ -f "$LIBGCC_A" ] || \
  fail "static libgcc not found: $LIBGCC_A"

printf 'libstdc++ static: %s\n' "$LIBSTDCXX_A"
printf 'libgcc static:   %s\n' "$LIBGCC_A"


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

mkdir -p "$MODULES_DIR"

cd "$MODULES_DIR"


# =============================================================================
# ngx_brotli
# =============================================================================

log "clone ngx_brotli"

clone_module \
  "https://github.com/google/ngx_brotli" \
  "ngx_brotli" \
  "submodules"

BROTLI_DIR="$MODULES_DIR/ngx_brotli/deps/brotli"
BROTLI_BUILD_DIR="$BROTLI_DIR/out"

[ -f "$BROTLI_DIR/c/include/brotli/encode.h" ] || \
  fail "ngx_brotli Brotli submodule is missing"


# =============================================================================
# Build Brotli static libraries
# =============================================================================

log "build Brotli static libraries"

cmake \
  -S "$BROTLI_DIR" \
  -B "$BROTLI_BUILD_DIR" \
  -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DBROTLI_BUILD_TOOLS=OFF \
  -DBROTLI_DISABLE_TESTS=ON \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON

cmake \
  --build "$BROTLI_BUILD_DIR" \
  --parallel "$NPROC" \
  --target brotlienc

BROTLI_ENC_A="$BROTLI_BUILD_DIR/libbrotlienc.a"
BROTLI_COMMON_A="$BROTLI_BUILD_DIR/libbrotlicommon.a"

[ -f "$BROTLI_ENC_A" ] || \
  fail "libbrotlienc.a not found: $BROTLI_ENC_A"

[ -f "$BROTLI_COMMON_A" ] || \
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
  >/dev/null 2>&1 || true


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


# =============================================================================
# Build BoringSSL
# =============================================================================

log "build BoringSSL static libraries"

cmake \
  -S "$BORINGSSL_DIR" \
  -B "$BORINGSSL_BUILD_DIR" \
  -GNinja \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON

cmake \
  --build "$BORINGSSL_BUILD_DIR" \
  --parallel "$NPROC"


# =============================================================================
# Locate BoringSSL
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

[ -n "$LIBSSL_A" ] || \
  fail "libssl.a not found under $BORINGSSL_BUILD_DIR"

[ -n "$LIBCRYPTO_A" ] || \
  fail "libcrypto.a not found under $BORINGSSL_BUILD_DIR"

[ -f "$BORINGSSL_DIR/include/openssl/ssl.h" ] || \
  fail "BoringSSL headers not found"

log "BoringSSL static libraries"

printf 'libssl:    %s\n' "$LIBSSL_A"
printf 'libcrypto: %s\n' "$LIBCRYPTO_A"


# =============================================================================
# nginx
# =============================================================================

cd "$NGINX_SRC_DIR"

log "write nginx version file"

printf 'nginx version %s\n' "$NGINX_VERSION" \
  | tee "$ROOT_DIR/NGINX_VERSION"


# =============================================================================
# Compiler / linker options
# =============================================================================
#
# Important:
#
# Nginx's OpenSSL detection itself appends:
#
#   -lssl -lcrypto
#
# Therefore:
#
#   -L$BORINGSSL_BUILD_DIR
#
# is required so those names resolve to BoringSSL.
#
# We also explicitly put:
#
#   libssl.a
#   libcrypto.a
#   libstdc++.a
#
# in this order so BoringSSL C++ references are resolved before the static
# C++ runtime is processed.
#
# libgcc is made static with -static-libgcc.
#
# musl remains dynamically linked.
#

NGINX_CC_OPT="\
-O2 \
-fstack-protector-strong \
-Wformat \
-Werror=format-security \
-fPIC \
-ffunction-sections \
-fdata-sections \
-U_FORTIFY_SOURCE \
-D_FORTIFY_SOURCE=3 \
-I$BORINGSSL_DIR/include"

NGINX_LD_OPT="\
-Wl,-Bsymbolic-functions \
-Wl,-z,relro \
-Wl,-z,now \
-Wl,--as-needed \
-Wl,--gc-sections \
-pie \
-L$BORINGSSL_BUILD_DIR \
$LIBSSL_A \
$LIBCRYPTO_A \
$LIBSTDCXX_A \
-static-libgcc"


# =============================================================================
# Configure nginx
# =============================================================================

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
  --with-compat \
  --with-file-aio \
  --with-threads \
  --with-http_addition_module \
  --with-http_auth_request_module \
  --with-http_dav_module \
  --with-http_flv_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
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
  --with-stream \
  --with-stream_realip_module \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-cc-opt="$NGINX_CC_OPT" \
  --with-ld-opt="$NGINX_LD_OPT" \
  --with-pcre="modules/pcre2" \
  --with-pcre-opt="-O2 -fPIC -ffunction-sections -fdata-sections" \
  --with-pcre-jit \
  --with-zlib="modules/zlib" \
  --with-zlib-opt="-O2 -fPIC -ffunction-sections -fdata-sections" \
  --add-module="modules/ngx_brotli"


# =============================================================================
# Build nginx
# =============================================================================

log "build nginx"

make -j"$NPROC"

NGINX_BIN="$NGINX_SRC_DIR/objs/nginx"

[ -x "$NGINX_BIN" ] || \
  fail "nginx binary not found: $NGINX_BIN"


# =============================================================================
# nginx -V
# =============================================================================

log "nginx version info"

"$NGINX_BIN" -V


# =============================================================================
# ELF information
# =============================================================================

log "binary information"

file "$NGINX_BIN"


# =============================================================================
# Verify musl interpreter
# =============================================================================

log "verify musl ELF interpreter"

INTERP="$(
  readelf -l "$NGINX_BIN" \
    | grep 'Requesting program interpreter' \
    || true
)"

printf '%s\n' "$INTERP"

printf '%s\n' "$INTERP" \
  | grep -Fq 'ld-musl-' \
  || fail "nginx is not linked against the musl dynamic loader"


# =============================================================================
# ldd
# =============================================================================

log "dynamic dependencies"

LDD_OUTPUT="$(ldd "$NGINX_BIN" 2>&1 || true)"

printf '%s\n' "$LDD_OUTPUT"


# =============================================================================
# Strong runtime dependency verification
# =============================================================================
#
# Goal:
#
# The final binary may only dynamically depend on musl libc.
#
# Everything else must be statically included.
#

log "verify that musl is the only dynamic runtime dependency"

NEEDED_LIBS="$(
  readelf -d "$NGINX_BIN" \
    | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p'
)"

if [ -z "$NEEDED_LIBS" ]; then
  fail "no DT_NEEDED entries found; expected a dynamically linked musl binary"
fi

FAILED=0

while IFS= read -r lib; do
  [ -n "$lib" ] || continue

  case "$lib" in
    libc.musl-*.so.1)
      printf 'allowed: %s\n' "$lib"
      ;;

    *)
      printf \
        'ERROR: unwanted dynamic dependency: %s\n' \
        "$lib" \
        >&2

      FAILED=1
      ;;
  esac
done <<< "$NEEDED_LIBS"

if [ "$FAILED" -ne 0 ]; then
  fail "nginx has runtime dependencies that are not present in a clean Alpine base image"
fi


# =============================================================================
# Extra sanity check
# =============================================================================

FORBIDDEN_PATTERNS='libstdc++.so
libgcc_s.so
libssl.so
libcrypto.so
libpcre
libz.so
libbrotli'

while IFS= read -r pattern; do
  [ -n "$pattern" ] || continue

  if printf '%s\n' "$LDD_OUTPUT" \
    | grep -Fq "$pattern"
  then
    fail "unexpected dynamic dependency detected: $pattern"
  fi
done <<< "$FORBIDDEN_PATTERNS"


# =============================================================================
# Copy artifact
# =============================================================================

log "copy final nginx binary"

cp -f \
  "$NGINX_BIN" \
  "$ROOT_DIR/nginx"

chmod 0755 "$ROOT_DIR/nginx"

strip --strip-unneeded "$ROOT_DIR/nginx"


# =============================================================================
# Artifact information
# =============================================================================

log "final artifact"

ls -lh "$ROOT_DIR/nginx"


# =============================================================================
# ccache stats
# =============================================================================

if command -v ccache >/dev/null 2>&1; then
  log "ccache stats"

  ccache --show-stats || true
fi


# =============================================================================
# Done
# =============================================================================

cat <<EOF

============================================================

Build complete.

Original binary:
  $NGINX_BIN

Final binary:
  $ROOT_DIR/nginx

Expected runtime model:

  musl             dynamic (provided by Alpine base image)

  BoringSSL        static
  PCRE2            static
  Cloudflare zlib  static
  Brotli           static
  libstdc++        static
  libgcc           static

Clean Alpine smoke test:

  docker run --rm \\
    -v "$ROOT_DIR/nginx:/nginx:ro" \\
    alpine:3.24 \\
    /nginx -V

============================================================

EOF
