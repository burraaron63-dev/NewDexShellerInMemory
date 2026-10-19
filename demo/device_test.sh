#!/usr/bin/env bash
#
# 真机端到端测试：构建 demo -> 用本项目加固 -> 装到设备 -> 拉起 -> 校验原始代码确实跑起来。
#
# 校验点（都来自 demo 源码里打的唯一 marker）：
#   APP_ONCREATE    原始 Application 被壳正确启动（解壳 + 换 ClassLoader 成功）
#   ACTIVITY_ONCREATE  原始 Activity 能被加载（组件 ClassLoader 已替换）
#   SECONDARY_OK    主 dex 跨 dex 调用 classes2.dex 成功（多 dex 可见性 / #1 回归点）
#
# 用法：
#   ./demo/device_test.sh              # 构建+加固+装+验（默认跑加固包）
#   ./demo/device_test.sh --baseline   # 先装未加固 demo 验基线，再装加固包对比
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PKG="com.dexshell.demo"
TAG="DEXSHELL_DEMO"
BASELINE=0
for a in "$@"; do [ "$a" = "--baseline" ] && BASELINE=1; done

info(){ printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[x]\033[0m %s\n' "$*"; }

# --- JDK（绕开 macOS /usr/bin 的 Xcode javac 桩）---
if [ -z "${JAVA_HOME:-}" ] && [ -x /usr/libexec/java_home ]; then
    JAVA_HOME="$(/usr/libexec/java_home 2>/dev/null || true)"
fi
[ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/javac" ] || { err "未找到 JDK：请设置 JAVA_HOME 指向 JDK 根目录"; exit 1; }
export PATH="$JAVA_HOME/bin:$PATH"
info "JDK: $("$JAVA_HOME/bin/javac" -version 2>&1)"

# --- Android SDK 工具探测 ---
SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || { err "未找到 Android SDK，请设置 ANDROID_SDK_ROOT"; exit 1; }
ADB="$SDK/platform-tools/adb"
pick_newest(){ ls $1 2>/dev/null | sort -V | tail -n1; }
BT_LATEST="$SDK/build-tools/$(ls -1 "$SDK/build-tools" | sort -V | tail -n1)"
export ANDROID_JAR="${ANDROID_JAR:-$(pick_newest "$SDK/platforms/*/android.jar")}"
export DX_JAR="${DX_JAR:-$(pick_newest "$SDK/build-tools/*/lib/dx.jar")}"
export APKSIGNER_JAR="${APKSIGNER_JAR:-$BT_LATEST/lib/apksigner.jar}"
export ZIPALIGN="${ZIPALIGN:-$BT_LATEST/zipalign}"
for v in ANDROID_JAR DX_JAR APKSIGNER_JAR ZIPALIGN; do
    eval "p=\$$v"; [ -n "$p" ] && [ -f "$p" ] || { err "缺少工具 $v = ${p:-(空)}（dx 需旧版 build-tools，如 30.0.3）"; exit 1; }
done

# --- 设备 ---
[ -x "$ADB" ] || { err "未找到 adb"; exit 1; }
DEV_CNT="$("$ADB" devices | grep -cE '\tdevice$' || true)"
[ "$DEV_CNT" -ge 1 ] || { err "没有已连接的设备（adb devices 为空）"; exit 1; }
SDK_INT="$("$ADB" shell getprop ro.build.version.sdk | tr -d '\r ')"
if   [ "${SDK_INT}" -ge 29 ]; then PATHDESC="InMemoryDexClassLoader(ByteBuffer[])"
elif [ "${SDK_INT}" -ge 26 ]; then PATHDESC="InMemoryDexClassLoader 合并 dexElements (#1 回归点)"
elif [ "${SDK_INT}" -ge 23 ]; then PATHDESC="6.0~7.1 无内存方案 (预期 FAIL)"
else                               PATHDESC="native OpenMemory (5.0/5.1)"
fi
info "设备 API=${SDK_INT} -> 预期走 ${PATHDESC}"

run_and_check() {   # $1=apk 描述  $2=apk 路径
    local label="$1" apk="$2"
    info "安装并启动：$label"
    "$ADB" uninstall "$PKG" >/dev/null 2>&1 || true
    "$ADB" install -r "$apk" >/dev/null
    "$ADB" logcat -c
    "$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
    sleep 4
    local log; log="$("$ADB" logcat -d -s "$TAG:I" yongye:I AndroidRuntime:E 2>/dev/null)"
    echo "$log" | grep -E "$TAG|yongye|FATAL|$PKG" || true
    local ok=1
    for m in APP_ONCREATE ACTIVITY_ONCREATE SECONDARY_OK; do
        if echo "$log" | grep -q "$m"; then printf '    \033[32m✓\033[0m %s\n' "$m"; else printf '    \033[31m✗\033[0m %s\n' "$m"; ok=0; fi
    done
    [ "$ok" = "1" ] && { info "$label: PASS ✅"; return 0; } || { err "$label: FAIL ❌"; return 1; }
}

# --- 1. 构建 demo ---
"$HERE/build_demo.sh"

# --- 2. 可选基线 ---
if [ "$BASELINE" = "1" ]; then
    run_and_check "未加固 demo（基线）" "$HERE/demo.apk" || true
fi

# --- 3. 加固 ---
rm -f "$ROOT/result.apk" "$ROOT/result_unaligned.apk" "$ROOT/shell.dex" "$ROOT/classes.dex" 2>/dev/null || true
info "加固 demo.apk -> result.apk"
python3 "$ROOT/sheller.py" -f "$HERE/demo.apk"
[ -f "$ROOT/result.apk" ] || { err "未生成 result.apk"; exit 1; }

# --- 4. 验加固包 ---
run_and_check "加固包 result.apk" "$ROOT/result.apk"
