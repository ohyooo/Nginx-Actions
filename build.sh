#!/usr/bin/env bash
set -euo pipefail

# ===== versions =====
NGINX_VERSION="1.29.5"
PCRE2_VERSION="10.47"
#BUILD_JOBS="${BUILD_JOBS:-1}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

# ===== paths =====
ROOT_DIR="$(pwd)"
SRC_DIR="$ROOT_DIR/src"

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

  rm -rf "$dir"
  git clone --depth=1 "$url" "$dir"

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

  rm -f "$out"
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
rm -rf "$SRC_DIR"
mkdir -p "$SRC_DIR"

cd "$SRC_DIR"

log "download nginx-$NGINX_VERSION"
download_and_extract "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz"

cd "nginx-$NGINX_VERSION"
mkdir -p modules
cd modules

log "clone ngx_brotli"
clone_module "https://github.com/google/ngx_brotli" "ngx_brotli" "submodules"

log "clone ngx_devel_kit"
clone_module "https://github.com/vision5/ngx_devel_kit" "ngx_devel_kit"

log "clone cloudflare zlib"
clone_module "https://github.com/cloudflare/zlib" "zlib"
make -C zlib -f Makefile.in distclean >/dev/null 2>&1 || true

log "download pcre2-$PCRE2_VERSION"
download_and_extract "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz"

log "clone boringssl"
rm -rf boringssl
git clone --depth=1 https://github.com/google/boringssl boringssl

log "build boringssl"
(
  cd boringssl
  cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
  cmake --build build -j"$BUILD_JOBS"
)

cd "$SRC_DIR/nginx-$NGINX_VERSION"

log "write nginx version file"
echo "nginx version $NGINX_VERSION" | tee "$ROOT_DIR/NGINX_VERSION"

BORINGSSL_DIR="$SRC_DIR/nginx-$NGINX_VERSION/modules/boringssl"
BORINGSSL_BUILD_DIR="$BORINGSSL_DIR/build"

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
  --with-ld-opt="-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie -L$BORINGSSL_BUILD_DIR -lstdc++" \
  --with-pcre="modules/pcre2-$PCRE2_VERSION" \
  --with-pcre-jit \
  --with-zlib=modules/zlib \
  --add-module=modules/ngx_brotli \
  --add-module=modules/ngx_devel_kit

log "build nginx with -j$BUILD_JOBS"
make -j"$BUILD_JOBS"

log "show nginx version info"
objs/nginx -V

cat <<EOF

编译完成。
二进制文件：
  $SRC_DIR/nginx-$NGINX_VERSION/objs/nginx

低配机器建议：
  BUILD_JOBS=1 bash $0

EOF
