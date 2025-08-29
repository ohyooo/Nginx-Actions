#!/bin/bash

# versions
NGINX_VERSION=1.29.1
OPENSSL=3.5.2
PCRE_VERSION=10.44

DIR=$(pwd)

sudo apt update && apt install libbrotli-dev -y


clone_module() {
  git clone --depth=1 "$1" && cd "$(basename "$1")"
  [ "$2" = "submodules" ] && git submodule update --init --recursive
  cd ..
}

download_and_extract() {
  wget "$1"
  tar -xzf "$2"
}

set -e

# print and store nginx version
echo "nginx version $NGINX_VERSION" | tee NGINX_VERSION

echo "patching nginx"
download_and_extract https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz nginx-$NGINX_VERSION.tar.gz
cd nginx-$NGINX_VERSION

{
  echo "downloading libs"
  mkdir modules && cd modules

  echo "downloading ngx_brotli"
  clone_module https://github.com/google/ngx_brotli submodules
  echo "downloading ngx_devel_kit"
  clone_module https://github.com/vision5/ngx_devel_kit
  echo "downloading zlib"
  clone_module https://github.com/cloudflare/zlib
  make -C zlib -f Makefile.in distclean
  echo "downloading pcre2-$PCRE_VERSION"
  wget https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE_VERSION/pcre2-$PCRE_VERSION.tar.gz
  tar -zxf pcre2-$PCRE_VERSION.tar.gz

}

{
  echo "downloading openssl-$OPENSSL"
  cd /opt
  rm -rf libressl-$OPENSSL*.tar.gz
  # https://github.com/openssl/openssl/releases/download/openssl-3.5.2/openssl-3.5.2.tar.gz
  download_and_extract https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL}/openssl-${OPENSSL}.tar.gz openssl-$OPENSSL.tar.gz
  # download_and_extract https://www.openssl.org/source/openssl-3.0.14.tar.gz openssl-$OPENSSL.tar.gz
}

cd $DIR/nginx-$NGINX_VERSION

# configure nginx
./configure --prefix=/etc/nginx \
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
  --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -fPIC -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3' \
  --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' \
  --with-pcre=modules/pcre2-$PCRE_VERSION \
  --with-pcre-jit \
  --with-zlib=modules/zlib \
  --add-module=modules/ngx_brotli \
  --add-module=modules/ngx_devel_kit \
  --with-openssl=/opt/openssl-$OPENSSL

# compile nginx
make -j"$(nproc)"

echo "nginx compiled successfully"
