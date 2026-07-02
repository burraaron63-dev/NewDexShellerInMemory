#!/usr/bin/env bash
#
# 一键编译全部 ABI 的脱壳 native 库，并输出到 ../lib/<abi>/。
#
# 用法：
#   NDK=/path/to/android-ndk  ./build.sh
# 或先 export ANDROID_NDK_HOME=/path/to/android-ndk 再运行 ./build.sh
#
set -euo pipefail

NDK="${NDK:-${ANDROID_NDK_HOME:-${ANDROID_NDK:-}}}"
if [ -z "$NDK" ] || [ ! -x "$NDK/ndk-build" ]; then
    echo "错误：未找到 NDK。请设置 NDK 或 ANDROID_NDK_HOME 指向 NDK 根目录。" >&2
    exit 1
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

rm -rf libs obj

"$NDK/ndk-build" \
    NDK_PROJECT_PATH=. \
    APP_BUILD_SCRIPT=./Android.mk \
    NDK_APPLICATION_MK=./Application.mk \
    NDK_LIBS_OUT=./libs \
    NDK_OUT=./obj

mkdir -p ../lib
cp -rv libs/* ../lib/

echo ""
echo "[*] 完成。各 ABI 的 libdalvik_system_DexFile.so 已复制到 ../lib/<abi>/"
