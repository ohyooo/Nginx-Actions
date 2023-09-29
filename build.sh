#!/bin/bash

# versions
NGINX_VERSION=1.25.2
LIBRESSL=3.8.1
PCRE_VERSION=10.42

clone_module() {
  git clone --depth=1 "$1" && cd "$(basename "$1")"
  [ "$2" = "submodules" ] && git submodule update --init --recursive
  cd ..
}

download_and_extract() {
  curl "$1" | tar -xz
}

set -e

# print and store nginx version
echo "nginx version $NGINX_VERSION" | tee NGINX_VERSION

echo "patching nginx"
download_and_extract https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz
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
  download_and_extract https://github.com/PhilipHazel/pcre2/releases/download/pcre2-$PCRE_VERSION/pcre2-$PCRE_VERSION.tar.gz

}

{
  echo "downloading libressl-$LIBRESSL"
  cd /opt
  rm -rf libressl-$LIBRESSL
  rm -rf libressl-$LIBRESSL.tar.gz
  download_and_extract https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-$LIBRESSL.tar.gz
}

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
  --with-stream \
  --with-stream_realip_module \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' \
  --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' \
  --with-pcre=modules/pcre2-$PCRE_VERSION \
  --with-pcre-jit \
  --with-zlib=modules/zlib \
  --add-module=modules/ngx_brotli \
  --add-module=modules/ngx_devel_kit \
  --with-http_v2_hpack_enc \
  --with-http_v3_module \
  --with-openssl=/opt/libressl-$LIBRESSL \
  --with-cc-opt="-I/opt/libressl-$LIBRESSL/build/include" \
  --with-ld-opt="-L/opt/libressl-$LIBRESSL/build/lib"

# compile nginx
make -j"$(nproc)"

echo "nginx compiled successfully"
