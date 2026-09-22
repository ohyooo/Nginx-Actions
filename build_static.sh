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
