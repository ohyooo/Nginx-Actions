#!/usr/bin/env bash
# Alpine/musl 全静态 Nginx。先安装 bash，再执行本脚本。
set -Eeuo pipefail
export LC_ALL=C
umask 022

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
VERSION_FILE="$ROOT_DIR/NGINX_VERSION"
OUTPUT_NAME=nginx
NPROC="${NPROC:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
TEMP_DIRS=()

log() { printf '\n>>> %s\n' "$*"; }
fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
  local status=$?
  trap - EXIT
  local dir
  for dir in "${TEMP_DIRS[@]}"; do rm -rf -- "$dir" || true; done
  exit "$status"
}
trap cleanup EXIT
trap 'printf "ERROR: line %s, exit %s: %s\n" "$LINENO" "$?" "$BASH_COMMAND" >&2' ERR

[[ -f "$VERSION_FILE" ]] || fail "missing $VERSION_FILE"
NGINX_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[[ "$NGINX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "invalid NGINX_VERSION"
[[ "$NPROC" =~ ^[1-9][0-9]*$ ]] || fail "NPROC must be a positive integer"
[[ -f /etc/alpine-release ]] && command -v apk >/dev/null || fail "Alpine Linux is required"

log "install build dependencies"
apk add --no-cache \
  bash build-base linux-headers musl-dev libstdc++-dev libgcc-static \
  git curl ca-certificates perl cmake samurai pkgconf \
  autoconf automake libtool ccache go binutils file

mkdir -p "${SRC_DIR:-$ROOT_DIR/src}"
SRC_DIR="$(cd -- "${SRC_DIR:-$ROOT_DIR/src}" && pwd -P)"
# nginx 的 configure/Makefile 会拼接路径；在前期明确拒绝不支持的字符。
[[ "$SRC_DIR" =~ ^/[a-zA-Z0-9_./-]+$ ]] || fail "SRC_DIR must not contain spaces or shell metacharacters"
NGINX_SRC_DIR="$SRC_DIR/nginx-$NGINX_VERSION"
MODULES_DIR="$NGINX_SRC_DIR/modules"
FINAL_BIN="$ROOT_DIR/$OUTPUT_NAME"

export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/.ccache}"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$ROOT_DIR}"
export CCACHE_COMPILERCHECK=content
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-2G}"
mkdir -p "$CCACHE_DIR"
# Autoconf、zlib、nginx 明确走 ccache；CMake 单独使用 launcher。
export CC='ccache gcc'
export CXX='ccache g++'
ccache --zero-stats

MUSL_LIBC_A="$(gcc -print-file-name=libc.a)"
LIBSTDCXX_A="$(g++ -print-file-name=libstdc++.a)"
LIBGCC_A="$(gcc -print-libgcc-file-name)"
for archive in "$MUSL_LIBC_A" "$LIBSTDCXX_A" "$LIBGCC_A"; do
  [[ "$archive" = /* && -f "$archive" ]] || fail "missing static runtime: $archive"
done

download_nginx() {
  local archive="$SRC_DIR/nginx-$NGINX_VERSION.tar.gz" stage
  if [[ ! -f "$archive" ]]; then
    stage="$(mktemp -d "$SRC_DIR/.nginx-download.XXXXXX")"
    TEMP_DIRS+=("$stage")
    curl --fail --location --show-error --retry 4 --retry-delay 2 \
      --connect-timeout 20 --max-time 600 \
      "https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" \
      -o "$stage/source.tar.gz"
    tar -tzf "$stage/source.tar.gz" >/dev/null
    mv -- "$stage/source.tar.gz" "$archive"
  fi
  # 可选：传入已独立核实的源码 SHA256；产物 SHA256 不能替代源码校验。
  if [[ -n "${NGINX_SHA256:-}" ]]; then
    [[ "$NGINX_SHA256" =~ ^[a-fA-F0-9]{64}$ ]] || fail "invalid NGINX_SHA256"
    printf '%s  %s\n' "$NGINX_SHA256" "$archive" | sha256sum -c -
  fi
  if [[ ! -d "$NGINX_SRC_DIR" ]]; then
    stage="$(mktemp -d "$SRC_DIR/.nginx-extract.XXXXXX")"
    TEMP_DIRS+=("$stage")
    tar -xzf "$archive" -C "$stage"
    [[ -f "$stage/nginx-$NGINX_VERSION/configure" ]] || fail "incomplete nginx archive"
    mv -- "$stage/nginx-$NGINX_VERSION" "$NGINX_SRC_DIR"
  fi
  [[ -f "$NGINX_SRC_DIR/configure" ]] || fail "incomplete source directory: $NGINX_SRC_DIR"
}

clone_module() {
  local url="$1" dir="$2" submodules="${3:-}" stage
  if [[ ! -e "$dir" ]]; then
    stage="$(mktemp -d "$MODULES_DIR/.clone.XXXXXX")"
    TEMP_DIRS+=("$stage")
    git clone --depth=1 "$url" "$stage/repo"
    mv -- "$stage/repo" "$dir"
  fi
  [[ -e "$dir/.git" ]] || fail "not a Git checkout: $dir"
  [[ "$(git -C "$dir" remote get-url origin)" = "$url" ]] || fail "unexpected origin: $dir"
  if [[ "$submodules" = submodules ]]; then
    git -C "$dir" submodule update --init --recursive --depth=1 --jobs "$NPROC"
  fi
  # 本地重跑复用现有 commit；CI 干净 checkout 会取得上游默认分支。
  log "$dir @ $(git -C "$dir" rev-parse HEAD)"
}

# 保留 CMake 增量构建；工具链/系统/路径改变时重建，避免旧对象混入。
TOOLCHAIN_ID="$(
  { printf '%s\n' "$SRC_DIR"; cat /etc/alpine-release; gcc -v 2>&1;
    g++ -v 2>&1; cmake --version; apk info -v; } | sha256sum
)"
prepare_cmake_build() {
  local dir="$1"
  if [[ -d "$dir" ]]; then
    if [[ ! -f "$dir/.toolchain-id" ]] || [[ "$(cat "$dir/.toolchain-id")" != "$TOOLCHAIN_ID" ]]; then
      rm -rf -- "$dir"
    fi
  fi
  mkdir -p "$dir"
  printf '%s\n' "$TOOLCHAIN_ID" > "$dir/.toolchain-id"
}

log "prepare nginx $NGINX_VERSION"
download_nginx
cd "$NGINX_SRC_DIR"
# nginx 的 auto/options 在正常输出帮助后也会 exit 1。
# 在条件上下文接收状态，避免 set -e / ERR trap 把帮助输出当成构建失败。
CONFIGURE_HELP_STATUS=0
CONFIGURE_HELP="$(./configure --help 2>&1)" || CONFIGURE_HELP_STATUS=$?
if (( CONFIGURE_HELP_STATUS > 1 )) ||
   [[ "$CONFIGURE_HELP" != *'--help'* || "$CONFIGURE_HELP" != *'--prefix=PATH'* ]]; then
  printf '%s\n' "$CONFIGURE_HELP" >&2
  fail "cannot read nginx configure help (exit $CONFIGURE_HELP_STATUS)"
fi
# 不静默删除用户要求的功能；版本不支持时在编译依赖之前报错。
for option in --with-control-api --with-http_json_module --with-http_v3_module; do
  [[ "$CONFIGURE_HELP" = *"$option"* ]] || fail "nginx $NGINX_VERSION does not support $option"
done
mkdir -p "$MODULES_DIR"
cd "$MODULES_DIR"
clone_module https://github.com/google/ngx_brotli ngx_brotli submodules
clone_module https://github.com/cloudflare/zlib zlib
clone_module https://github.com/PCRE2Project/pcre2 pcre2 submodules
clone_module https://github.com/google/boringssl boringssl

COMMON_CFLAGS='-O2 -fno-pie -fstack-protector-strong -ffunction-sections -fdata-sections'
CMAKE_FLAGS=(
  -GNinja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_C_COMPILER=/usr/bin/gcc -DCMAKE_CXX_COMPILER=/usr/bin/g++
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  -DCMAKE_EXE_LINKER_FLAGS=-no-pie
  "-DCMAKE_C_FLAGS_RELEASE=$COMMON_CFLAGS -DNDEBUG"
  "-DCMAKE_CXX_FLAGS_RELEASE=$COMMON_CFLAGS -DNDEBUG"
)

log "build Brotli"
BROTLI_DIR="$MODULES_DIR/ngx_brotli/deps/brotli"
BROTLI_BUILD_DIR="$BROTLI_DIR/out"
[[ -f "$BROTLI_DIR/c/include/brotli/encode.h" ]] || fail "missing Brotli submodule"
prepare_cmake_build "$BROTLI_BUILD_DIR"
cmake -S "$BROTLI_DIR" -B "$BROTLI_BUILD_DIR" "${CMAKE_FLAGS[@]}" \
  -DBROTLI_BUILD_TOOLS=OFF -DBROTLI_DISABLE_TESTS=ON
cmake --build "$BROTLI_BUILD_DIR" --parallel "$NPROC" --target brotlienc
for archive in libbrotlienc.a libbrotlicommon.a; do
  [[ -f "$BROTLI_BUILD_DIR/$archive" ]] || fail "missing $archive"
done

log "prepare PCRE2 and zlib"
# PCRE2 的 Makefile 由 configure 生成；仅在已有配置时清理。
if [[ -f pcre2/Makefile ]]; then make -C pcre2 distclean; fi
[[ -f pcre2/configure ]] || (cd pcre2 && ./autogen.sh)

# Cloudflare zlib 的全新 Git checkout 可能没有 Makefile。
# nginx 的构建规则却会先调用 make distclean，再运行 ./configure。
# 显式使用上游 Makefile.in 清理；该目标还会生成带 distclean 的引导 Makefile。
[[ -f zlib/Makefile.in ]] || fail "missing zlib/Makefile.in"
make -C zlib -f Makefile.in distclean

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
