#!/usr/bin/env bash
set -euo pipefail

NGINX_VERSION="${NGINX_VERSION:-1.31.3}"

ROOT_DIR="$(pwd)"
SRC_DIR="$ROOT_DIR/src"
NPROC="${NPROC:-$(nproc)}"

log() {
  printf '\n>>> %s\n' "$*"
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

log "install build dependencies"

if command -v apk >/dev/null 2>&1; then
  # Alpine
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
    binutils
else
  # Debian / Ubuntu
  sudo apt update

  sudo apt install -y \
    build-essential \
    git \
    wget \
    curl \
    ca-certificates \
    perl \
    cmake \
    ninja-build \
    pkg-config \
    autoconf \
    automake \
    libtool \
    ccache \
    golang-go \
    binutils
fi

if command -v ccache >/dev/null 2>&1; then
  if [ -d /usr/lib/ccache/bin ]; then
    export PATH="/usr/lib/ccache/bin:$PATH"
  elif [ -d /usr/lib/ccache ]; then
    export PATH="/usr/lib/ccache:$PATH"
  fi

  ccache --set-config=max_size="${CCACHE_MAXSIZE:-2G}"
fi

log "prepare source directory"

mkdir -p "$SRC_DIR"
cd "$SRC_DIR"

#
# nginx
#

log "download nginx-$NGINX_VERSION"

download_and_extract \
  "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"

cd "$SRC_DIR/nginx-$NGINX_VERSION"

mkdir -p modules
cd modules

#
# ngx_brotli
#

log "clone ngx_brotli"

clone_module \
  "https://github.com/google/ngx_brotli" \
  "ngx_brotli" \
  "submodules"

#
# Cloudflare zlib
#

log "clone cloudflare zlib"

clone_module \
  "https://github.com/cloudflare/zlib" \
  "zlib"

make -C zlib -f Makefile.in distclean >/dev/null 2>&1 || true

#
# PCRE2
#

log "clone pcre2"

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

#
# BoringSSL
#

log "clone boringssl"

clone_module \
  "https://github.com/google/boringssl" \
  "boringssl"

log "build boringssl"

(
  cd boringssl

  cmake \
    -S . \
    -B build \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON

  cmake --build build -j"$NPROC"
)

#
# nginx configure
#

cd "$SRC_DIR/nginx-$NGINX_VERSION"

log "write nginx version file"

echo "nginx version $NGINX_VERSION" \
  | tee "$ROOT_DIR/NGINX_VERSION"

BORINGSSL_DIR="$SRC_DIR/nginx-$NGINX_VERSION/modules/boringssl"
BORINGSSL_BUILD_DIR="$BORINGSSL_DIR/build"

log "locate boringssl artifacts"

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

if [ -z "$LIBSSL_A" ]; then
  echo "ERROR: libssl.a not found under $BORINGSSL_BUILD_DIR"
  exit 1
fi

if [ -z "$LIBCRYPTO_A" ]; then
  echo "ERROR: libcrypto.a not found under $BORINGSSL_BUILD_DIR"
  exit 1
fi

log "boringssl libraries"

echo "libssl:"
echo "  $LIBSSL_A"

echo "libcrypto:"
echo "  $LIBCRYPTO_A"

#
# Static C++ runtime
#
# BoringSSL uses C++, but nginx itself is linked using gcc/cc.
#
# Explicitly switch the linker to static mode for libstdc++,
# then switch back to dynamic mode so musl remains dynamically linked.
#
# -static-libgcc makes GCC runtime static as well.
#

STATIC_CXX_LDFLAGS="-Wl,-Bstatic -lstdc++ -Wl,-Bdynamic -static-libgcc"

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
  --with-cc-opt="-O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -I$BORINGSSL_DIR/include" \
  --with-ld-opt="-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie -L$BORINGSSL_BUILD_DIR $LIBSSL_A $LIBCRYPTO_A $STATIC_CXX_LDFLAGS" \
  --with-pcre="modules/pcre2" \
  --with-pcre-jit \
  --with-zlib="modules/zlib" \
  --add-module="modules/ngx_brotli"

#
# Build nginx
#

log "build nginx"

make -j"$NPROC"

NGINX_BIN="$SRC_DIR/nginx-$NGINX_VERSION/objs/nginx"

if [ ! -x "$NGINX_BIN" ]; then
  echo "ERROR: nginx binary not found"
  exit 1
fi

#
# Show information
#

log "show nginx version info"

"$NGINX_BIN" -V

log "binary information"

file "$NGINX_BIN"

#
# Runtime dependency verification
#

log "check runtime dependencies"

LDD_OUTPUT="$(ldd "$NGINX_BIN" 2>&1 || true)"

printf '%s\n' "$LDD_OUTPUT"

#
# These libraries must NOT be dynamically linked.
#

FORBIDDEN_LIBS='
libstdc++.so
libgcc_s.so
libssl.so
libcrypto.so
libpcre
libz.so
libbrotli
'

FAILED=0

while IFS= read -r lib; do
  [ -n "$lib" ] || continue

  if printf '%s\n' "$LDD_OUTPUT" | grep -Fq "$lib"; then
    echo
    echo "ERROR: unwanted dynamic dependency detected:"
    echo "  $lib"
    FAILED=1
  fi
done <<< "$FORBIDDEN_LIBS"

if [ "$FAILED" -ne 0 ]; then
  echo
  echo "ERROR: nginx still has unwanted dynamic runtime dependencies."
  exit 1
fi

#
# Alpine/musl verification
#

if command -v apk >/dev/null 2>&1; then
  log "verify musl interpreter"

  INTERP="$(
    readelf -l "$NGINX_BIN" \
      | grep 'Requesting program interpreter' \
      || true
  )"

  printf '%s\n' "$INTERP"

  if ! printf '%s\n' "$INTERP" | grep -Fq 'ld-musl-'; then
    echo
    echo "ERROR: nginx is not linked against musl"
    exit 1
  fi
fi

#
# Copy final artifact
#

log "copy final nginx binary"

cp -f "$NGINX_BIN" "$ROOT_DIR/nginx"
chmod +x "$ROOT_DIR/nginx"

#
# Size
#

log "binary size"

ls -lh "$ROOT_DIR/nginx"

#
# ccache stats
#

if command -v ccache >/dev/null 2>&1; then
  log "ccache stats"
  ccache --show-stats || true
fi

cat <<EOF

============================================================
编译完成

原始二进制：
  $NGINX_BIN

最终二进制：
  $ROOT_DIR/nginx

目标：
  Alpine musl 动态链接
  BoringSSL 静态链接
  PCRE2 静态链接
  Cloudflare zlib 静态链接
  brotli 静态链接
  libstdc++ 静态链接
  libgcc 静态链接

空白 Alpine 中无需安装：
  libstdc++
  libgcc
  openssl
  pcre2
  zlib
  brotli

验证：

  docker run --rm \\
    -v "$ROOT_DIR/nginx:/nginx:ro" \\
    alpine:3.24 \\
    /nginx -V

============================================================

EOF
