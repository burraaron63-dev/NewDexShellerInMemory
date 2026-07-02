#!/usr/bin/env bash
#
# 一键创建加固脚本的测试环境：
#   1. 用 venv 创建 Python 虚拟环境并安装依赖（Pillow / filetype）
#   2. 自动探测 Android SDK / NDK，定位 apktool / aapt / dx / apksigner / android.jar
#   3. 生成可 source 的 env.sh，导出 sheller.py 需要的工具路径
#   4. 校验环境，打印后续操作步骤
#
# 用法：
#   ./setup_test_env.sh                 # 创建/复用 venv 并探测工具
#   ./setup_test_env.sh --recreate      # 删除旧 venv 重新创建
#   ./setup_test_env.sh --smoke         # 环境就绪后对 test.apk 跑一次加固冒烟测试
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

VENV_DIR="$HERE/.venv"
ENV_FILE="$HERE/env.sh"
RECREATE=0
SMOKE=0
for arg in "$@"; do
    case "$arg" in
        --recreate) RECREATE=1 ;;
        --smoke)    SMOKE=1 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

info() { printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[x]\033[0m %s\n' "$*"; }

# ------------------------------------------------------------------
# 1. Python venv
# ------------------------------------------------------------------
PY="${PYTHON:-python3}"
if ! command -v "$PY" >/dev/null 2>&1; then
    err "未找到 python3，请先安装 Python 3.7+"; exit 1
fi

if [ "$RECREATE" = "1" ] && [ -d "$VENV_DIR" ]; then
    info "删除旧虚拟环境 $VENV_DIR"
    rm -rf "$VENV_DIR"
fi

if [ ! -f "$VENV_DIR/bin/activate" ]; then
    [ -d "$VENV_DIR" ] && { warn "检测到不完整的虚拟环境，重建"; rm -rf "$VENV_DIR"; }
    info "创建虚拟环境: $VENV_DIR"
    if ! "$PY" -m venv "$VENV_DIR" 2>/dev/null; then
        warn "标准 venv 创建失败（ensurepip 不可用），改用 --without-pip 并自举 pip"
        "$PY" -m venv --without-pip "$VENV_DIR"
    fi
else
    info "复用已存在的虚拟环境: $VENV_DIR"
fi

# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

# 确保 venv 内有 pip（应对 --without-pip 情况）
if ! python -m pip --version >/dev/null 2>&1; then
    info "自举 pip"
    if ! python -m ensurepip --upgrade >/dev/null 2>&1; then
        if command -v curl >/dev/null 2>&1; then
            curl -sS https://bootstrap.pypa.io/get-pip.py | python
        else
            err "无法自举 pip：既无 ensurepip 也无 curl。请手动安装 pip 后重试。"; exit 1
        fi
    fi
fi

info "升级 pip 并安装依赖"
python -m pip install --quiet --upgrade pip
python -m pip install --quiet -r "$HERE/requirements.txt"
python -c "import PIL, filetype; print('    Pillow', PIL.__version__, '/ filetype', filetype.version.__version__ if hasattr(filetype,'version') else 'ok')" \
    && info "Python 依赖安装完成" || { err "依赖校验失败"; exit 1; }

# ------------------------------------------------------------------
# 2. 探测 Android SDK / NDK
# ------------------------------------------------------------------
detect_sdk() {
    for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
             "$HOME/Library/Android/sdk" "$HOME/Android/Sdk" "/usr/local/share/android-sdk"; do
        [ -n "$c" ] && [ -d "$c" ] && { echo "$c"; return; }
    done
}
SDK="$(detect_sdk || true)"

# 选择“仍带 dx.jar”的最新 build-tools（dx 在较新版本被移除，sheller.py 依赖它）
find_build_tools_with_dx() {
    local sdk="$1"
    [ -d "$sdk/build-tools" ] || return 0
    local d
    for d in $(ls -1 "$sdk/build-tools" 2>/dev/null | sort -rV); do
        if [ -f "$sdk/build-tools/$d/lib/dx.jar" ]; then echo "$sdk/build-tools/$d"; return; fi
    done
}
# 选最新 build-tools（用于 aapt / apksigner，即使没有 dx）
find_latest_build_tools() {
    local sdk="$1"
    [ -d "$sdk/build-tools" ] || return 0
    local d; d="$(ls -1 "$sdk/build-tools" 2>/dev/null | sort -rV | head -n1)"
    [ -n "$d" ] && echo "$sdk/build-tools/$d"
}
find_latest_platform_jar() {
    local sdk="$1"
    [ -d "$sdk/platforms" ] || return 0
    local p
    for p in $(ls -1 "$sdk/platforms" 2>/dev/null | sort -rV); do
        [ -f "$sdk/platforms/$p/android.jar" ] && { echo "$sdk/platforms/$p/android.jar"; return; }
    done
}
find_ndk() {
    for c in "${NDK:-}" "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK:-}"; do
        [ -n "$c" ] && [ -x "$c/ndk-build" ] && { echo "$c"; return; }
    done
    [ -n "$SDK" ] && [ -d "$SDK/ndk" ] || return 0
    local d; d="$(ls -1 "$SDK/ndk" 2>/dev/null | sort -rV | head -n1)"
    [ -n "$d" ] && [ -x "$SDK/ndk/$d/ndk-build" ] && echo "$SDK/ndk/$d"
}
find_apktool_jar() {
    # 常见位置：brew 的 libexec、手动放置、或环境变量
    for c in "${APKTOOL_JAR:-}" \
             /opt/homebrew/opt/apktool/libexec/apktool.jar \
             /usr/local/opt/apktool/libexec/apktool.jar \
             "$HOME/apktool.jar"; do
        [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return; }
    done
    # brew 安装的 apktool 是个包装脚本，尝试从中解析 jar 路径
    if command -v apktool >/dev/null 2>&1; then
        local j; j="$(grep -oE '/[^" ]*apktool[^" ]*\.jar' "$(command -v apktool)" 2>/dev/null | head -n1 || true)"
        [ -n "$j" ] && [ -f "$j" ] && { echo "$j"; return; }
    fi
}

BT_DX="$([ -n "$SDK" ] && find_build_tools_with_dx "$SDK" || true)"
BT_LATEST="$([ -n "$SDK" ] && find_latest_build_tools "$SDK" || true)"
ANDROID_JAR_PATH="$([ -n "$SDK" ] && find_latest_platform_jar "$SDK" || true)"
NDK_PATH="$(find_ndk || true)"
APKTOOL_PATH="$(find_apktool_jar || true)"

AAPT_PATH=""; DX_PATH=""; APKSIGNER_PATH=""
[ -n "$BT_LATEST" ] && [ -x "$BT_LATEST/aapt" ] && AAPT_PATH="$BT_LATEST/aapt"
[ -n "$BT_DX" ] && DX_PATH="$BT_DX/lib/dx.jar"
[ -n "$BT_LATEST" ] && [ -f "$BT_LATEST/lib/apksigner.jar" ] && APKSIGNER_PATH="$BT_LATEST/lib/apksigner.jar"

# ------------------------------------------------------------------
# 3. 生成 env.sh
# ------------------------------------------------------------------
{
    echo "# 由 setup_test_env.sh 生成，source 本文件后再运行 sheller.py"
    echo "# 缺失项请手动补全对应路径"
    echo "source \"$VENV_DIR/bin/activate\""
    echo "export APKTOOL_JAR=\"${APKTOOL_PATH:-/path/to/apktool.jar}\""
    echo "export AAPT=\"${AAPT_PATH:-/path/to/aapt}\""
    echo "export ANDROID_JAR=\"${ANDROID_JAR_PATH:-/path/to/android.jar}\""
    echo "export DX_JAR=\"${DX_PATH:-/path/to/dx.jar}\""
    echo "export APKSIGNER_JAR=\"${APKSIGNER_PATH:-/path/to/apksigner.jar}\""
    echo "export NDK=\"${NDK_PATH:-/path/to/android-ndk}\""
} > "$ENV_FILE"
info "已生成环境文件: $ENV_FILE"

# ------------------------------------------------------------------
# 4. 环境体检
# ------------------------------------------------------------------
echo ""
info "环境探测结果："
check() { if [ -n "$2" ] && { [ -f "$2" ] || [ -x "$2" ]; }; then printf '    \033[32m✓\033[0m %-12s %s\n' "$1" "$2"; else printf '    \033[31m✗\033[0m %-12s %s\n' "$1" "${2:-未找到，请手动设置}"; fi; }
command -v java >/dev/null 2>&1 && info "java: $(java -version 2>&1 | head -n1)" || warn "未找到 java（apktool/dx/apksigner 需要 JDK）"
check "SDK"        "${SDK:-}"
check "apktool"    "$APKTOOL_PATH"
check "aapt"       "$AAPT_PATH"
check "android.jar" "$ANDROID_JAR_PATH"
check "dx.jar"     "$DX_PATH"
check "apksigner"  "$APKSIGNER_PATH"
check "ndk-build"  "${NDK_PATH:+$NDK_PATH/ndk-build}"

[ -z "$DX_PATH" ] && warn "未找到 dx.jar：较新 build-tools(31+) 已移除 dx。请安装带 dx 的旧版 build-tools，如 sdkmanager \"build-tools;29.0.3\""
[ -z "$APKTOOL_PATH" ] && warn "未找到 apktool.jar：可 brew install apktool，或手动下载 jar 后 export APKTOOL_JAR=..."

echo ""
info "下一步："
echo "    source env.sh                          # 载入 venv 与工具路径"
echo "    (cd cpp && ./build.sh)                  # 编译各 ABI 的 native so 到 lib/<abi>/"
echo "    python sheller.py -f test.apk          # 对测试 apk 加固，生成 result.apk"

# ------------------------------------------------------------------
# 5. 可选冒烟测试
# ------------------------------------------------------------------
if [ "$SMOKE" = "1" ]; then
    echo ""
    if [ -z "$APKTOOL_PATH" ] || [ -z "$AAPT_PATH" ] || [ -z "$DX_PATH" ] || [ -z "$ANDROID_JAR_PATH" ] || [ -z "$APKSIGNER_PATH" ]; then
        err "工具链不完整，跳过冒烟测试。请先补齐上面标 ✗ 的项。"; exit 0
    fi
    [ -f "$HERE/test.apk" ] || { err "缺少 test.apk，无法冒烟测试"; exit 0; }
    export APKTOOL_JAR="$APKTOOL_PATH" AAPT="$AAPT_PATH" ANDROID_JAR="$ANDROID_JAR_PATH" DX_JAR="$DX_PATH" APKSIGNER_JAR="$APKSIGNER_PATH"
    info "冒烟测试：python sheller.py -f test.apk"
    python sheller.py -f test.apk && info "冒烟测试完成，产物: result.apk" || err "冒烟测试失败，请看上方日志"
fi
