#!/bin/bash

# https://nginx.org/en/download.html
NGINX_VERSION=1.21.6

# https://www.openssl.org/source/
OPENSSL_VERSION=3.0.1

# https://ftp.pcre.org/pub/pcre/
PCRE_VERSION=10.39

# https://github.com/apache/incubator-pagespeed-ngx
NGX_PAGESPEED_VERSION=1.14.33.1-RC1

echo -e "nginx-$NGINX_VERSION\c" > NGINX_VERSION

# download & patch
echo "nginx version $NGINX_VERSION"
curl https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz | tar -xz && cd nginx-$NGINX_VERSION

wget https://raw.githubusercontent.com/kn007/patch/master/nginx.patch
wget https://raw.githubusercontent.com/kn007/patch/master/use_openssl_md5_sha1.patch
patch -p1 < nginx.patch
patch -p1 < use_openssl_md5_sha1.patch

# download lib
mkdir modules && cd modules

git clone --depth=1 https://github.com/google/ngx_brotli && cd ngx_brotli && git submodule update --init --recursive && cd ..

git clone --depth=1 https://github.com/vision5/ngx_devel_kit

git clone --depth=1 https://github.com/cloudflare/zlib

cd zlib && make -f Makefile.in distclean && cd ..

curl https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz | tar -xz

# curl https://ftp.pcre.org/pub/pcre/pcre-$PCRE_VERSION.tar.gz | tar -xz
wget https://github.com/PhilipHazel/pcre2/releases/download/pcre2-$PCRE_VERSION/pcre2-$PCRE_VERSION.tar.gz
tar zxf pcre2-$PCRE_VERSION.tar.gz

# pagespeed
sudo apt install build-essential zlib1g-dev libpcre3 libpcre3-dev unzip uuid-dev -y

wget https://github.com/apache/incubator-pagespeed-ngx/archive/v$NGX_PAGESPEED_VERSION.zip
unzip -q v$NGX_PAGESPEED_VERSION.zip
mv incubator-pagespeed-ngx-$NGX_PAGESPEED_VERSION ngx_pagespeed

curl https://dist.apache.org/repos/dist/release/incubator/pagespeed/1.14.36.1/x64/psol-1.14.36.1-apache-incubating-x64.tar.gz | tar -xz -C ngx_pagespeed

cd ..

./configure --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log --pid-path=/run/nginx.pid --lock-path=/run/nginx.lock --http-client-body-temp-path=/var/cache/nginx/client_temp --http-proxy-temp-path=/var/cache/nginx/proxy_temp --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp --http-scgi-temp-path=/var/cache/nginx/scgi_temp --user=nginx --group=nginx --with-compat --with-file-aio --with-threads --with-http_addition_module --with-http_auth_request_module --with-http_dav_module --with-http_flv_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_mp4_module --with-http_random_index_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_stub_status_module --with-http_sub_module --with-http_v2_module --with-stream --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' --with-ld-opt='-Wl,-Bsymbolic-functions -Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie' --with-pcre=modules/pcre2-$PCRE_VERSION --with-pcre-jit --with-zlib=modules/zlib --add-module=modules/ngx_brotli --add-module=modules/ngx_devel_kit --add-module=modules/ngx_pagespeed --with-openssl=modules/openssl-$OPENSSL_VERSION --with-http_v2_hpack_enc

make
