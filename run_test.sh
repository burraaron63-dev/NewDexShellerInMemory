#!/usr/bin/env bash
#
# 一条命令跑通加固测试：自动探测工具 -> 修复/复用 venv -> 装依赖 -> 清理残留
# -> 导出全部环境变量 -> 对指定 APK 加固，产物 result.apk。
#
# 用法：
#   ./run_test.sh <apk路径>                 # 加固指定 apk（默认 ./test.apk）
#   ./run_test.sh <apk路径> --build-so      # 顺便用 NDK 编译各 ABI 的 native so
#
# 依赖：java(JDK)、python3、Android SDK（含带 dx 的 build-tools）、可选 apktool、NDK
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APK="${1:-$HERE/test.apk}"
BUILD_SO=0
for a in "$@"; do [ "$a" = "--build-so" ] && BUILD_SO=1; done

info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"; }

[ -f "$APK" ] || { err "APK 不存在: $APK"; exit 1; }
command -v java >/dev/null 2>&1 || { err "未找到 java，请安装 JDK（apktool/dx/apksigner 需要）"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "未找到 python3"; exit 1; }

# ------------------------------------------------------------------
# 1. 探测 Android SDK / 工具
# ------------------------------------------------------------------
detect_sdk() {
    for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
             "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "/usr/local/share/android-sdk"; do
        [ -n "$c" ] && [ -d "$c" ] && { echo "$c"; return; }
    done
}
SDK="$(detect_sdk || true)"
[ -n "$SDK" ] || { err "未找到 Android SDK，请设置 ANDROID_SDK_ROOT"; exit 1; }

pick_newest() { ls $1 2>/dev/null | sort -V | tail -n1; }  # 传入 glob，取版本最新

BT_LATEST_DIR="$(ls -1 "$SDK/build-tools" 2>/dev/null | sort -V | tail -n1)"
BT_LATEST="$SDK/build-tools/$BT_LATEST_DIR"

# v3 不再需要 apktool / aapt（不反编译、不重编资源），只需 JDK 工具链 + zipalign
APKSIGNER_JAR="${APKSIGNER_JAR:-$BT_LATEST/lib/apksigner.jar}"
ZIPALIGN="${ZIPALIGN:-$BT_LATEST/zipalign}"
[ -f "$ZIPALIGN" ] || ZIPALIGN="$(pick_newest "$SDK/build-tools/*/zipalign")"
DX_JAR="${DX_JAR:-$(pick_newest "$SDK/build-tools/*/lib/dx.jar")}"
ANDROID_JAR="${ANDROID_JAR:-$(pick_newest "$SDK/platforms/*/android.jar")}"

# ------------------------------------------------------------------
# 2. 体检：缺什么一次性列全并给安装建议
# ------------------------------------------------------------------
MISS=0
chk() { if [ -n "$2" ] && [ -f "$2" ]; then printf '    \033[32m✓\033[0m %-13s %s\n' "$1" "$2"; else printf '    \033[31m✗\033[0m %-13s %s\n' "$1" "${2:-未找到}"; MISS=1; fi; }
info "工具探测（v3 无需 apktool/aapt）："
chk android.jar "$ANDROID_JAR"
chk dx.jar      "$DX_JAR"
chk apksigner   "$APKSIGNER_JAR"
chk zipalign    "$ZIPALIGN"

if [ "$MISS" = "1" ]; then
    echo ""
    [ -f "${DX_JAR:-}" ] || warn "缺 dx.jar：新版 build-tools(31+) 已删 dx，装旧版：sdkmanager \"build-tools;30.0.3\""
    err "工具不完整，已中止。补齐上面标 ✗ 的项后重试。"
    exit 1
fi

# ------------------------------------------------------------------
# 3. venv：坏了就重建，缺依赖才安装（不破坏已可用环境）
# ------------------------------------------------------------------
# v3 的 sheller.py 只用 Python 标准库，无第三方依赖；venv 仅作隔离用途
VPY="$HERE/.venv/bin/python"
if [ ! -x "$VPY" ]; then
    warn "未发现可用 venv，创建 .venv"
    rm -rf "$HERE/.venv" 2>/dev/null || true
    python3 -m venv --without-pip "$HERE/.venv" 2>/dev/null || python3 -m venv "$HERE/.venv"
fi
[ -x "$VPY" ] || VPY="python3"   # venv 创建失败则退回系统 python3（无需依赖）
info "Python 环境就绪 ($VPY)"

# ------------------------------------------------------------------
# 4. 可选：编译各 ABI 的 native so
# ------------------------------------------------------------------
if [ "$BUILD_SO" = "1" ]; then
    NDK="${NDK:-${ANDROID_NDK_HOME:-}}"
    if [ -z "$NDK" ] && [ -d "$SDK/ndk" ]; then
        NDK="$SDK/ndk/$(ls -1 "$SDK/ndk" | sort -V | tail -n1)"
    fi
    if [ -n "$NDK" ] && [ -x "$NDK/ndk-build" ]; then
        info "编译 native so (NDK: $NDK)"
        ( cd "$HERE/cpp" && NDK="$NDK" ./build.sh )
    else
        warn "未找到 NDK，跳过 so 编译（Android 8+ 测试不需要 so）"
    fi
fi

# ------------------------------------------------------------------
# 5. 清理上次残留 + 运行加固
# ------------------------------------------------------------------
rm -f "$HERE/result.apk" "$HERE/result_unaligned.apk" "$HERE/shell.dex" "$HERE/classes.dex" 2>/dev/null || true

export ANDROID_JAR DX_JAR APKSIGNER_JAR ZIPALIGN

info "开始加固: $APK"
"$VPY" "$HERE/sheller.py" -f "$APK"

if [ -f "$HERE/result.apk" ]; then
    info "完成 ✅  产物: $HERE/result.apk"
    ls -lh "$HERE/result.apk"
else
    err "未生成 result.apk，请看上方日志"
    exit 1
fi
