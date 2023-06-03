#!/bin/bash

# versions
NGINX_VERSION=1.25.0
LIBRESSL=3.8.0
PCRE_VERSION=10.42

set -e

# print and store nginx version
echo "nginx version $NGINX_VERSION" | tee NGINX_VERSION

# download and patch nginx
curl https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz | tar -xz
cd nginx-$NGINX_VERSION

curl -LO https://raw.githubusercontent.com/kn007/patch/master/nginx.patch
curl -LO https://raw.githubusercontent.com/kn007/patch/master/use_openssl_md5_sha1.patch

patch -p1 < nginx.patch
patch -p1 < use_openssl_md5_sha1.patch

# download libs
mkdir modules && cd modules

clone_module() {
  git clone --depth=1 "$1" && cd "$(basename "$1")"
  [ "$2" = "submodules" ] && git submodule update --init --recursive
  cd ..
}

clone_module https://github.com/google/ngx_brotli submodules
clone_module https://github.com/vision5/ngx_devel_kit
clone_module https://github.com/cloudflare/zlib

make -C zlib -f Makefile.in distclean

download_and_extract() {
  curl "$1" | tar -xz
}

{
    cd /opt
    download_and_extract https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/libressl-LIBRESSL.tar.gz
}

wget https://github.com/PhilipHazel/pcre2/releases/download/pcre2-$PCRE_VERSION/pcre2-$PCRE_VERSION.tar.gz
tar zxf pcre2-$PCRE_VERSION.tar.gz

cd ..

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
make

echo "nginx compiled successfully"

