# -*- coding: UTF-8 -*- 

import zlib
import hashlib
import re
import glob
from subprocess import check_call
import argparse
import os
import zipfile
import shutil

from axml_editor import AXML

# 工具路径可通过环境变量覆盖。
# v3：不再使用 apktool / aapt（不反编译、不重编资源），因此只需 JDK 工具链：
#   ANDROID_JAR(javac)、DX_JAR(dx)、APKSIGNER_JAR(签名)、ZIPALIGN(对齐)。
stShellAppPt = os.environ.get('SHELL_APP_DIR', './shellApplicationSourceCode')
stAndroidJarlibPt = os.environ.get('ANDROID_JAR', r'D:\Android\Sdk\platforms\android-29\android.jar')
stdxJarPt = os.environ.get('DX_JAR', r'D:\Android\Sdk\build-tools\29.0.3\lib\dx.jar')
stApksignJarPt = os.environ.get('APKSIGNER_JAR', r'D:\Android\Sdk\build-tools\29.0.3\lib\apksigner.jar')
stZipalignPt = os.environ.get('ZIPALIGN', r'D:\Android\Sdk\build-tools\29.0.3\zipalign.exe')
stCurrentPt = os.path.abspath(__file__).replace(os.path.basename(__file__), "")

# 加密密钥，需与 Java 层 FileUtils.XOR_KEY / native 层一致
INKEY = 0xFF
# 隐藏 payload 容器魔数 "YYJG"，需与 FileUtils.PAYLOAD_MAGIC 一致
PAYLOAD_MAGIC = 0x474A5959
# 打包 so 的目标 ABI（有对应 lib/<abi>/*.so 才会写入）
TARGET_ABIS = ['arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86']


def le32(n):
    """int -> 4 字节小端 bytes"""
    return bytes([n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >> 24) & 0xff])


def xor_encrypt(data, key=INKEY):
    return bytes([b ^ key for b in data])


def build_shell_dex_with_payloads(shellDexPath, srcDexBytesList):
    """
    将一个或多个原始 dex 加密后隐藏到壳 dex 尾部，容器格式如下（追加在壳 dex 之后）：

        [magic(4,LE)] [count(4,LE)]
        重复 count 次: [len_i(4,LE)] [XOR 加密的原始 dex_i]
        [tailLen(4,LE)]  <- 文件最后 4 字节 = 从 magic 到最后一个 dex 的字节数

    随后重算壳 dex 的 file_size / signature / checksum，使整个 classes.dex 仍是合法 dex。
    需与 Java 层 FileUtils.extractPayloadDexes 完全一致。
    """
    with open(shellDexPath, "rb") as f:
        shellData = f.read()

    out = bytearray(shellData)

    # 容器区
    payload = bytearray()
    payload += le32(PAYLOAD_MAGIC)
    payload += le32(len(srcDexBytesList))
    for src in srcDexBytesList:
        enc = xor_encrypt(src)
        payload += le32(len(enc))
        payload += enc
    tail_len = len(payload)  # magic..最后一个 dex 的字节数

    out += payload
    out += le32(tail_len)

    # 重算 dex 头，使壳 classes.dex 整体合法
    new_fsize = len(out)
    out[32:36] = le32(new_fsize)

    new_sig = hashlib.sha1(bytes(out[32:])).digest()  # signature 覆盖 [32:]
    out[12:32] = new_sig

    new_checksum = zlib.adler32(bytes(out[12:])) & 0xffffffff  # checksum 覆盖 [12:]
    out[8:12] = le32(new_checksum)

    with open(os.path.join(stCurrentPt, 'classes.dex'), 'wb') as f:
        f.write(bytes(out))
    print("[*] 已隐藏 {} 个原始 DEX 到壳 DEX 尾部".format(len(srcDexBytesList)))


STUB_APPLICATION = "cn.yongye.nativeshell.StubApp"


def read_manifest_bytes(apk_path):
    with zipfile.ZipFile(apk_path) as z:
        return z.read('AndroidManifest.xml')


def getAppName(fp):
    """直接解析二进制 AndroidManifest.xml，读取原 <application android:name>。"""
    try:
        ax = AXML(read_manifest_bytes(fp))
        name = ax.get_application_name()
    except Exception as e:
        print("[!] 解析 manifest 失败，退回默认 Application: {}".format(e))
        name = None
    return name if name else "android.app.Application"


def patch_manifest_bytes(manifest_bytes):
    """把 <application android:name> 改/插为壳 StubApp，返回新的 AXML 字节。"""
    ax = AXML(manifest_bytes)
    old = ax.set_application_name(STUB_APPLICATION)
    print("[*] manifest application: {} -> {}".format(old or "(无)", STUB_APPLICATION))
    return ax.to_bytes()


def save_appName(appName):
    stCfgFp = os.path.join(stShellAppPt, "java/cn/yongye/nativeshell/common/Config.java")
    with open(stCfgFp, 'w') as f:
        f.write("package cn.yongye.nativeshell.common;\n")
        f.write("\n")
        f.write("public class Config {\n")
        f.write("    public static final String MAIN_APPLICATION = \"{}\";\n".format(appName))
        f.write("}")

def compileShellDex():
    # 跨平台实现：用 glob 显式展开 .java（javac/dx 本身不展开通配符），
    # 并用独立构建目录，最后把整个 .class 目录树交给 dx（dx 支持目录输入）。
    build_dir = os.path.join(stCurrentPt, "shell_build")
    shutil.rmtree(build_dir, ignore_errors=True)
    os.makedirs(build_dir)

    java_src_root = os.path.join(stShellAppPt, "java")
    java_files = glob.glob(os.path.join(java_src_root, "**", "*.java"), recursive=True)
    if not java_files:
        raise Exception("未找到壳源码 .java 文件，检查 SHELL_APP_DIR: " + stShellAppPt)

    licmd2 = ["javac", "-encoding", "UTF-8",
              "-source", "1.8", "-target", "1.8",
              "-bootclasspath", stAndroidJarlibPt,
              "-d", build_dir] + java_files
    check_call(licmd2)

    licmd3 = ["java", "-jar", stdxJarPt,
              "--dex", "--output=" + os.path.join(stCurrentPt, "shell.dex"),
              build_dir]
    check_call(licmd3)

    shutil.rmtree(build_dir, ignore_errors=True)
    
    
def collect_src_dexes(apk_path):
    """收集原 APK 的全部 classes*.dex（多 dex），按 classes.dex, classes2.dex ... 顺序。"""
    with zipfile.ZipFile(apk_path) as z:
        dexNames = [n for n in z.namelist() if re.match(r'^classes\d*\.dex$', n)]

        def order(name):
            m = re.match(r'^classes(\d*)\.dex$', name)
            return 1 if m.group(1) == '' else int(m.group(1))
        dexNames.sort(key=order)
        data = {n: z.read(n) for n in dexNames}
    print("[*] 检测到原 APK 的 DEX: {}".format(dexNames))
    return dexNames, [data[n] for n in dexNames]


def add_native_libs(zout):
    """把脱壳 native 库按 ABI 目录写入（STORED 未压缩，便于 zipalign 对齐）。

    仅 Android 5.0~5.1 (API 21~22) 会用到；6.0~7.1 无内存脱壳方案，8.0+ 走 Java InMemoryDexClassLoader。
    需为各 ABI 用 NDK 编译出 libdalvik_system_DexFile.so 放到 lib/<abi>/ 下（cpp/build.sh）。
    """
    written = 0
    for abi in TARGET_ABIS:
        soPath = os.path.join(stCurrentPt, "lib", abi, "libdalvik_system_DexFile.so")
        if os.path.isfile(soPath):
            zi = zipfile.ZipInfo("lib/{}/libdalvik_system_DexFile.so".format(abi))
            zi.compress_type = zipfile.ZIP_STORED
            with open(soPath, "rb") as f:
                zout.writestr(zi, f.read())
            written += 1
            print("[*] 打入 native 库: lib/{}/".format(abi))
    if written == 0:
        print("[!] 未找到任何 lib/<abi>/libdalvik_system_DexFile.so；"
              "Android 8+ 不受影响，但 5.0/5.1 机型将无 native 回退。"
              "如需覆盖老机型，请先运行 cpp/build.sh 编译 so。")


def build_result_apk(src_apk, out_apk, shell_dex_path):
    """
    不反编译、不重编资源，直接基于原 APK 重组生成加固包：
      - 替换 AndroidManifest.xml 为 patched（application -> StubApp）
      - 丢弃全部原始 classes*.dex，写入壳 classes.dex
      - 追加各 ABI 的脱壳 so
      - 删除旧签名（META-INF/*.SF/.RSA/.DSA/.EC/MANIFEST.MF）
    其余条目（resources.arsc、res/、assets/、原 lib/ 等）原样拷贝并保留压缩方式。
    """
    sig_re = re.compile(r'^META-INF/.*\.(RSA|DSA|EC|SF)$', re.I)
    dex_re = re.compile(r'^classes\d*\.dex$')

    with zipfile.ZipFile(src_apk) as zin:
        patched_manifest = patch_manifest_bytes(zin.read('AndroidManifest.xml'))
        with zipfile.ZipFile(out_apk, 'w', zipfile.ZIP_DEFLATED) as zout:
            for item in zin.infolist():
                nm = item.filename
                if nm == 'AndroidManifest.xml' or dex_re.match(nm):
                    continue
                if nm == 'META-INF/MANIFEST.MF' or sig_re.match(nm):
                    continue
                zi = zipfile.ZipInfo(nm, date_time=item.date_time)
                zi.compress_type = item.compress_type      # 保留原压缩方式（resources.arsc 保持 STORED）
                zi.external_attr = item.external_attr
                zi.internal_attr = item.internal_attr
                zi.create_system = item.create_system
                zout.writestr(zi, zin.read(nm))

            # patched manifest
            mi = zipfile.ZipInfo('AndroidManifest.xml')
            mi.compress_type = zipfile.ZIP_DEFLATED
            zout.writestr(mi, patched_manifest)

            # 壳 classes.dex（内含全部原始 dex 密文）
            di = zipfile.ZipInfo('classes.dex')
            di.compress_type = zipfile.ZIP_DEFLATED
            with open(shell_dex_path, 'rb') as f:
                zout.writestr(di, f.read())

            # 各 ABI 脱壳 so
            add_native_libs(zout)
    print("[*] 已生成未对齐加固包: {}".format(out_apk))


def zipalignApk(src, dst):
    # -p 让 so 按页对齐；-f 覆盖；4 字节对齐
    check_call([stZipalignPt, "-p", "-f", "4", src, dst])
    print("[*] zipalign 完成: {}".format(dst))


def signApk(fp, stKeystoreFp):
    cmd = ["java", "-jar", stApksignJarPt, "sign",
           "--ks", stKeystoreFp, "--ks-pass", "pass:123456", fp]
    check_call(cmd)

def check_tools():
    """启动前校验外部工具路径，避免回退到默认路径后抛出隐晦错误。"""
    required = [
        ('ANDROID_JAR', stAndroidJarlibPt),
        ('DX_JAR', stdxJarPt),
        ('APKSIGNER_JAR', stApksignJarPt),
        ('ZIPALIGN', stZipalignPt),
    ]
    missing = [(env, p) for env, p in required if not p or not os.path.isfile(p)]
    if missing:
        print("[x] 以下工具路径无效，请先 `source env.sh` 或设置对应环境变量：")
        for env, p in missing:
            print("      {:<14} = {}".format(env, p if p else "(未设置)"))
        print("    提示：运行 ./setup_test_env.sh 会自动探测并生成 env.sh，然后 `source env.sh` 再重试。")
        raise SystemExit(1)
    if not os.path.isfile(os.path.join(stShellAppPt, "java", "cn", "yongye",
                                       "nativeshell", "StubApp.java")):
        print("[x] 找不到壳源码，请检查 SHELL_APP_DIR: {}".format(stShellAppPt))
        raise SystemExit(1)


if __name__ == "__main__":

    parser = argparse.ArgumentParser()
    parser.add_argument('-f', help="对指定文件进行加固", nargs=1, metavar='APK')
    args = parser.parse_args()

    if args.f:
        fp = args.__dict__.get('f')[0]

        # 预检外部工具，缺失则给出清晰提示
        check_tools()
        if not os.path.isfile(fp):
            print("[x] APK 不存在: {}".format(fp)); raise SystemExit(1)

        shell_dex = os.path.join(stCurrentPt, "shell.dex")
        packed_dex = os.path.join(stCurrentPt, "classes.dex")   # 内嵌进结果包的壳 classes.dex
        unaligned = os.path.join(stCurrentPt, "result_unaligned.apk")
        result = os.path.join(stCurrentPt, "result.apk")

        print("[*] 加密算法：异或 0x{:02X}".format(INKEY))

        # 1. 读取原 Application 名并写入壳 Config（直接解析二进制 manifest，无需 apktool）
        stSrcDexAppName = getAppName(fp)
        print("[*] 原 Application: {}".format(stSrcDexAppName))
        save_appName(stSrcDexAppName)

        # 2. 编译壳 DEX
        compileShellDex()
        print("[*] 壳 DEX 编译完成")

        # 3. 收集原 APK 全部 dex，加密隐藏到壳 DEX 尾部 -> classes.dex
        _dexNames, srcDexList = collect_src_dexes(fp)
        build_shell_dex_with_payloads(shell_dex, srcDexList)

        # 4. 无资源重编，直接重组 APK（换 manifest、换 dex、加 so、去旧签名）
        build_result_apk(fp, unaligned, packed_dex)

        # 5. 对齐
        zipalignApk(unaligned, result)

        # 6. 签名
        signApk(result, os.path.join(stCurrentPt, "demo.keystore"))
        print("[*] 签名完成 ✅ 生成: {}".format(result))

        # 清理中间产物
        for p in (shell_dex, packed_dex, unaligned):
            try:
                os.remove(p)
            except OSError:
                pass

    else:
        parser.print_help()
    
    
