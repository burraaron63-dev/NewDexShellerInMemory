#!/usr/bin/env bash
#
# 构建 demo「受害者」APK（多 dex，含跨 dex 调用），供加固 + 真机测试使用。
# 用 aapt2(编译二进制 manifest) + javac + d8(分出 classes.dex / classes2.dex) + apksigner。
# 产物: demo/demo.apk
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="$HERE/build"
APK="$HERE/demo.apk"

info(){ printf '\033[1;32m[*]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[x]\033[0m %s\n' "$*"; }

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
[ -d "$SDK" ] || { err "未找到 Android SDK，请设置 ANDROID_SDK_ROOT"; exit 1; }
BT="$SDK/build-tools/$(ls -1 "$SDK/build-tools" | sort -V | tail -1)"
AAPT2="$BT/aapt2"; ZIPALIGN="$BT/zipalign"; APKSIGNER="$BT/lib/apksigner.jar"; D8="$BT/lib/d8.jar"
ANDROID_JAR="$(ls "$SDK/platforms/"*/android.jar | sort -V | tail -1)"
for f in "$AAPT2" "$ZIPALIGN" "$APKSIGNER" "$D8" "$ANDROID_JAR"; do
  [ -f "$f" ] || { err "缺少工具: $f"; exit 1; }
done

rm -rf "$OUT"; mkdir -p "$OUT/classes" "$OUT/d1" "$OUT/d2"
SRC="$HERE/java/com/dexshell/demo"
CLS="$OUT/classes/com/dexshell/demo"

info "javac（对 android.jar 编译，目标 1.8）"
javac -source 8 -target 8 -nowarn -Xlint:-options \
  -classpath "$ANDROID_JAR" -d "$OUT/classes" \
  "$SRC/Secondary.java" "$SRC/DemoApp.java" "$SRC/MainActivity.java"

info "d8 -> classes2.dex（Secondary 单独一 dex）"
java -cp "$D8" com.android.tools.r8.D8 --min-api 21 --lib "$ANDROID_JAR" --classpath "$OUT/classes" \
  --output "$OUT/d2" "$CLS/Secondary.class"
mv "$OUT/d2/classes.dex" "$OUT/classes2.dex"

info "d8 -> classes.dex（主 dex：DemoApp + MainActivity，含对 Secondary 的跨 dex 引用）"
java -cp "$D8" com.android.tools.r8.D8 --min-api 21 --lib "$ANDROID_JAR" --classpath "$OUT/classes" \
  --output "$OUT/d1" "$CLS/DemoApp.class" "$CLS/MainActivity.class"
mv "$OUT/d1/classes.dex" "$OUT/classes.dex"

info "aapt2 link（生成二进制 AndroidManifest + resources.arsc）"
"$AAPT2" link -o "$OUT/base.apk" -I "$ANDROID_JAR" \
  --manifest "$HERE/AndroidManifest.xml" \
  --min-sdk-version 21 --target-sdk-version 30

info "注入 classes.dex / classes2.dex"
cp "$OUT/base.apk" "$OUT/staged.apk"
python3 - "$OUT" <<'PY'
import sys, zipfile, os
out = sys.argv[1]
with zipfile.ZipFile(os.path.join(out, "staged.apk"), "a", zipfile.ZIP_DEFLATED) as z:
    z.write(os.path.join(out, "classes.dex"), "classes.dex")
    z.write(os.path.join(out, "classes2.dex"), "classes2.dex")
print("    injected classes.dex + classes2.dex")
PY

info "zipalign + 签名（demo.keystore / pass:123456）"
"$ZIPALIGN" -p -f 4 "$OUT/staged.apk" "$OUT/aligned.apk"
java -jar "$APKSIGNER" sign --ks "$ROOT/demo.keystore" --ks-pass pass:123456 \
  --out "$APK" "$OUT/aligned.apk"

info "demo 构建完成: $APK"
unzip -l "$APK" | grep -E 'classes.*dex|AndroidManifest' || true
