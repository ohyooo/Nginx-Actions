for dir in pcre2 zlib; do
  if [[ -f "$dir/Makefile" ]]; then make -C "$dir" distclean; fi
done
[[ -f pcre2/configure ]] || (cd pcre2 && ./autogen.sh)

log "build BoringSSL"
BORINGSSL_DIR="$MODULES_DIR/boringssl"
BORINGSSL_BUILD_DIR="$BORINGSSL_DIR/build"
prepare_cmake_build "$BORINGSSL_BUILD_DIR"
cmake -S "$BORINGSSL_DIR" -B "$BORINGSSL_BUILD_DIR" "${CMAKE_FLAGS[@]}" \
  -DBUILD_TESTING=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON
cmake --build "$BORINGSSL_BUILD_DIR" --parallel "$NPROC" --target ssl crypto
LIBSSL_A="$(find "$BORINGSSL_BUILD_DIR" -type f -name libssl.a -print -quit)"
LIBCRYPTO_A="$(find "$BORINGSSL_BUILD_DIR" -type f -name libcrypto.a -print -quit)"
[[ -n "$LIBSSL_A" && -f "$LIBSSL_A" ]] || fail "missing libssl.a"
[[ -n "$LIBCRYPTO_A" && -f "$LIBCRYPTO_A" ]] || fail "missing libcrypto.a"

cd "$NGINX_SRC_DIR"
rm -rf objs
# 保持为单行；configure 内部会通过 eval 执行编译/链接探测。
NGINX_CC_OPT="$COMMON_CFLAGS -Wformat -Werror=format-security -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=3 -I$BORINGSSL_DIR/include"
NGINX_LD_OPT="-static -no-pie -pthread -Wl,-z,relro -Wl,--gc-sections -L$(dirname "$LIBSSL_A") -L$(dirname "$LIBCRYPTO_A") -Wl,--start-group $LIBSSL_A $LIBCRYPTO_A $LIBSTDCXX_A -Wl,--end-group -static-libgcc"
MODULE_OPTIONS=(
  --with-compat --with-control-api --with-file-aio --with-threads
  --with-http_addition_module --with-http_auth_request_module
  --with-http_dav_module --with-http_flv_module --with-http_gunzip_module
  --with-http_gzip_static_module --with-http_json_module --with-http_mp4_module
  --with-http_random_index_module --with-http_realip_module
  --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module
  --with-http_stub_status_module --with-http_sub_module
  --with-http_v2_module --with-http_v3_module
  --with-stream --with-stream_realip_module --with-stream_ssl_module
  --with-stream_ssl_preread_module --with-pcre-jit
  --add-module=modules/ngx_brotli
)
log "configure nginx"
./configure \
  --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
  --pid-path=/run/nginx.pid --lock-path=/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nobody --group=nobody --with-cc="$CC" \
  --with-cc-opt="$NGINX_CC_OPT" --with-ld-opt="$NGINX_LD_OPT" \
  --with-pcre=modules/pcre2 --with-pcre-opt="$COMMON_CFLAGS -no-pie" \
  --with-zlib=modules/zlib --with-zlib-opt="$COMMON_CFLAGS -no-pie" \
  "${MODULE_OPTIONS[@]}"
make -j"$NPROC"

verify_static() {
  local binary="$1" program_headers dynamic_section
  # 先检查 readelf 成功，再判断内容；不使用可能 SIGPIPE 的 grep -q 管道。
  program_headers="$(readelf -lW "$binary")"
  dynamic_section="$(readelf -dW "$binary")"
  if grep -Eq '^[[:space:]]*INTERP[[:space:]]' <<< "$program_headers"; then
    fail "$binary contains PT_INTERP"
  fi
  [[ "$dynamic_section" != *'(NEEDED)'* ]] || fail "$binary contains DT_NEEDED"
  file "$binary"
}

log "verify and stage artifact"
STAGE_DIR="$(mktemp -d "$ROOT_DIR/.nginx-artifact.XXXXXX")"
TEMP_DIRS+=("$STAGE_DIR")
cp -- "$NGINX_SRC_DIR/objs/nginx" "$STAGE_DIR/$OUTPUT_NAME"
chmod 0755 "$STAGE_DIR/$OUTPUT_NAME"
strip --strip-unneeded "$STAGE_DIR/$OUTPUT_NAME"
verify_static "$STAGE_DIR/$OUTPUT_NAME"
BUILD_INFO="$("$STAGE_DIR/$OUTPUT_NAME" -V 2>&1)"
printf '%s\n' "$BUILD_INFO"
# 精确匹配选项边界，避免 --with-stream 被 --with-stream_ssl_module 误满足。
for option in "${MODULE_OPTIONS[@]}"; do
  [[ " $BUILD_INFO " = *" $option "* ]] || fail "missing configure option: $option"
done

log "configuration smoke test"
SMOKE_DIR="$(mktemp -d "$ROOT_DIR/.nginx-smoke.XXXXXX")"
TEMP_DIRS+=("$SMOKE_DIR")
cat > "$SMOKE_DIR/nginx.conf" <<'EOF'
worker_processes 1;
error_log stderr notice;
pid nginx.pid;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path client_temp;
    proxy_temp_path proxy_temp;
    fastcgi_temp_path fastcgi_temp;
    uwsgi_temp_path uwsgi_temp;
    scgi_temp_path scgi_temp;
    brotli on;
    brotli_static on;
    gzip on;
    gzip_static on;
    ssl_protocols TLSv1.2 TLSv1.3;
    server {
        listen 127.0.0.1:18080;
        location ~ ^/health$ { return 200 "ok\n"; }
    }
}
stream { }
EOF
"$STAGE_DIR/$OUTPUT_NAME" -t -e stderr -p "$SMOKE_DIR/" -c "$SMOKE_DIR/nginx.conf"

log "write metadata"
{
  printf '%s\n\n' "$BUILD_INFO"
  printf 'Alpine: %s\nArchitecture: %s\n' "$(cat /etc/alpine-release)" "$(uname -m)"
  gcc --version
  printf '\nnginx source archive:\n'
  sha256sum "$SRC_DIR/nginx-$NGINX_VERSION.tar.gz"
  printf '\nDependency commits (working trees may include local edits):\n'
  for dir in ngx_brotli zlib pcre2 boringssl; do
    printf '%s %s\n' "$dir" "$(git -C "$MODULES_DIR/$dir" rev-parse HEAD)"
    git -C "$MODULES_DIR/$dir" submodule status --recursive
  done
} > "$STAGE_DIR/$OUTPUT_NAME.build-info.txt"
(cd "$STAGE_DIR" && sha256sum "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256")
# 所有检查通过后才替换旧产物；同一文件系统内每个 rename 都是原子的。
mv -f -- "$STAGE_DIR/$OUTPUT_NAME.build-info.txt" "$ROOT_DIR/$OUTPUT_NAME.build-info.txt"
mv -f -- "$STAGE_DIR/$OUTPUT_NAME.sha256" "$ROOT_DIR/$OUTPUT_NAME.sha256"
mv -f -- "$STAGE_DIR/$OUTPUT_NAME" "$FINAL_BIN"
ccache --show-stats
ls -lh "$FINAL_BIN"
cat "$ROOT_DIR/$OUTPUT_NAME.sha256"
log "done: $FINAL_BIN"
