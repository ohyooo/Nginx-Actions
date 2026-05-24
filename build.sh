#!/usr/bin/env bash
set -euo pipefail

NGINX_VERSION="1.31.1"
PCRE2_VERSION="10.47"

ROOT_DIR="$(pwd)"
SRC_DIR="$ROOT_DIR/src"
NPROC="$(nproc)"

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
      git submodule update --init --recursive
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
  clang \
  libbrotli-dev \
  libunwind-dev

log "prepare source directory"
mkdir -p "$SRC_DIR"

cd "$SRC_DIR"

log "download nginx-$NGINX_VERSION"
download_and_extract "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"

cd "nginx-$NGINX_VERSION"
mkdir -p modules
cd modules

log "clone ngx_brotli"
clone_module "https://github.com/google/ngx_brotli" "ngx_brotli" "submodules"

log "clone cloudflare zlib"
clone_module "https://github.com/cloudflare/zlib" "zlib"
make -C zlib -f Makefile.in distclean >/dev/null 2>&1 || true

log "download pcre2-$PCRE2_VERSION"
download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz"

log "clone boringssl"
clone_module "https://github.com/google/boringssl" "boringssl"

log "build boringssl"
(
  cd boringssl
  cmake -S . -B build -GNinja -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j"$NPROC"
)

cd "$SRC_DIR/nginx-$NGINX_VERSION"

log "write nginx version file"
echo "nginx version $NGINX_VERSION" | tee "$ROOT_DIR/NGINX_VERSION"

BORINGSSL_DIR="$SRC_DIR/nginx-$NGINX_VERSION/modules/boringssl"
BORINGSSL_BUILD_DIR="$BORINGSSL_DIR/build"

log "locate boringssl artifacts"
LIBSSL_A="$(find "$BORINGSSL_BUILD_DIR" -type f -name libssl.a | head -n1)"
LIBCRYPTO_A="$(find "$BORINGSSL_BUILD_DIR" -type f -name libcrypto.a | head -n1)"

[ -n "$LIBSSL_A" ] || { echo "libssl.a not found under $BORINGSSL_BUILD_DIR"; exit 1; }
[ -n "$LIBCRYPTO_A" ] || { echo "libcrypto.a not found under $BORINGSSL_BUILD_DIR"; exit 1; }

LIBSSL_DIR="$(dirname "$LIBSSL_A")"
LIBCRYPTO_DIR="$(dirname "$LIBCRYPTO_A")"

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
  --user=nginx \
  --group=nginx \
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
  --with-ld-opt="-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie -L$LIBSSL_DIR -L$LIBCRYPTO_DIR -lssl -lcrypto -lstdc++" \
  --with-pcre="modules/pcre2-$PCRE2_VERSION" \
  --with-pcre-jit \
  --with-zlib=modules/zlib \
  --add-module=modules/ngx_brotli

log "build nginx"
make -j"$NPROC"

log "show nginx version info"
objs/nginx -V

cat <<EOF

编译完成。
二进制文件：
  $SRC_DIR/nginx-$NGINX_VERSION/objs/nginx

EOF
