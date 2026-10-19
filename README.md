> 📖 English documentation: [README.en.md](README.en.md)

# 概况

本文目的：通过**内存加载DEX文件技术**，完成**一键DEX加固脚本**

# 优化说明（v3：无资源重编打包）

v2 仍沿用「apktool 反编译 → 改 manifest → apktool 重新编译」的老流程，对复杂真实 APK
极易在 aapt2 资源链接阶段失败（例如 `gravity="0x0"` 之类的严格校验报错）。v3 彻底改掉：

- **不反编译、不重编资源**：直接解析并「就地修改」二进制 `AndroidManifest.xml`
  （`axml_editor.py`：把 `<application android:name>` 改/插为壳 `StubApp`），再用 zip
  直接重组 APK：替换 manifest、丢弃原 `classes*.dex`、写入壳 `classes.dex`、按 ABI 追加
  脱壳 so、删除旧签名，最后 `zipalign` + `apksigner`。任意真实 APK 都不再受资源问题影响。
- **依赖大幅简化**：不再需要 `apktool` / `aapt`，Python 侧也只用标准库（去掉 Pillow/filetype）。
  现在只需 JDK 工具链：`ANDROID_JAR`(javac)、`DX_JAR`(dx)、`APKSIGNER_JAR`、`ZIPALIGN`。
- **一键测试脚本**：`./run_test.sh <apk>` 自动探测工具、修/建 venv、清残留、跑通全流程，产物 `result.apk`。
- **保留正确性**：`resources.arsc` 等条目原样拷贝并保持 STORED（满足 Android 11+ 要求）。
  AXML 编辑器经字节级 round-trip 验证（空改动可字节还原原文件），改名/插入属性两条路径均验证通过。

> 说明：v3 仅用 `dx` 编译壳 dex。若你的 build-tools 是 31+（已移除 dx），装个旧版即可：
> `sdkmanager "build-tools;30.0.3"`，或 `export DX_JAR=.../build-tools/30.0.3/lib/dx.jar`。

# 优化说明（v2：兼容性重构）

本次针对「各机型兼容」做了重构，核心变化如下：

## 1. 加载流程改为按 Android 版本分发（关键）

旧版把「加载原始 DEX + 替换 ClassLoader + 启动原始 Application」写死在 native 层，且
`OpenMemory` 符号只适配 Android 5.0/5.1，实际只能在极少数机型跑通。现改为在 Java 层
（`StubApp`）按 API 等级分发：

| Android 版本 | API | 加载方式 | 是否需要 native so |
| --- | --- | --- | --- |
| 8.0 ~ 14+ | 26+ | 官方 `InMemoryDexClassLoader`（`ByteBuffer[]` / 链式） | 否 |
| 5.0 ~ 5.1 | 21~22 | native `OpenMemory` 回退（`MyDexClassLoader`） | 是 |
| 6.0 ~ 7.1 | 23~25 | 不支持（cookie/`defineClass` ABI 与 native 方案不兼容） | - |
| < 5.0 | <21 | 不支持（Dalvik，占比极低） | - |

因此绝大多数在网设备（Android 8+）走官方 API，天然稳定；native 仅作为老机型回退。

## 2. 修复的具体 Bug / 兼容问题

- **真机崩溃（最严重）**：`sheller.py` 旧版只把 so 打进 `lib/x86/`，ARM 真机
  `System.loadLibrary` 直接失败闪退。现打入全部 ABI（`arm64-v8a / armeabi-v7a / x86_64 / x86`）。
- **硬编码测试类**：native 旧代码写死加载 `com.h.MyAdmin`，任何真实 APK 必崩，已删除。
- **64 位机型崩溃**：native 旧代码 ELF 解析写死 `Elf32`、库路径写死 `/system/lib`。
  现按 `__LP64__` 选择 `Elf64` 与 `/system/lib64/libart.so`。
- **单一版本符号**：`OpenMemory` 符号仅 5.x 可用。符号候选表覆盖 5.0/5.1 多个变体；注意 6.0+ 即便命中符号，其 cookie/`defineClass` ABI 也已不兼容，故 native 实际只支持 5.0/5.1。
- **进程被静默杀死**：失败处 `exit(0)` 改为记录日志并优雅返回，交由 Java 兜底。
- **多 dex 丢失**：旧版只加固 `classes.dex`。现加固全部 `classes*.dex`（多 dex 应用不再漏保护）。
- **工具路径不可移植**：`sheller.py` 中 `D:\...` 路径改为可用环境变量覆盖。

## 3. native 库重新编译（你需要自己用 NDK 出包）

so 需要按 ABI 重新编译（源码已改，旧 so 为 x86/5.x，需重出）：

```bash
# 一次编译全部 ABI，输出到 ../lib/<abi>/
cd cpp
NDK=/path/to/android-ndk ./build.sh        # Windows 用 build.bat，先 set NDK=...
```

> 提示：API 21~22（5.0/5.1）的 native `OpenMemory` 回退路径依赖各 ROM 的 libart 符号，属尽力而为，
> 建议在目标老机型上实测；Android 8.0+ 无此依赖。**Android 10+ 已由 `InMemoryDexClassLoader`
> 覆盖，无需 native。**

# 使用说明

```powershell
python sheller.py -f xxx.apk
```

# 加固原理

和我的另一个项目[Native层DEX一键加固脚本](https://github.com/yongyecc/dexsheller)基本一样，只是多了一步，引入了内存加载DEX技术

# 一键加固脚本实现步骤

1. 准备原DEX加密算法以及隐藏位置（壳DEX尾部）

```python
        """
        1. 第一步：确定加密算法
        """
        inKey = 0xFF
        print("[*] 确定加密解密算法，异或: {}".format(str(inKey)))
```

2. 生成壳DEX。（壳Application动态加载原application中需要原application的name字段）

```python
        """
        2. 第二步：准备好壳App
        """
        # 反编译原apk
        decompAPK(fp)
        # 获取Applicaiton name并保存到壳App源码中
        stSrcDexAppName = getAppName(fp)
        save_appName(stSrcDexAppName)
        # 编译出壳DEX
        compileShellDex()
        print("[*] 壳App的class字节码文件编译为:shell.dex完成")
```

3. 修改原APK文件中的AndroidManifest.xml文件的applicationandroid:name字段，实现从壳application启动

```python
        """
        3. 第三步：修改原apk AndroidManifest.xml文件中的Application name字段为壳的Application name字段
        """
        # 替换壳Applicaiton name到原apk的AndroidManifest.xml内
        replaceTag(fp, "cn.yongye.nativeshell.StubApp")
        print("[*] 原apk文件AndroidManifest.xml中application的name字段替换为壳application name字段完成")
```

4. 加密原DEX到壳DEX尾部并将壳DEX替换到原APK中

```python
        """
        4. 替换原apk中的DEX文件为壳DEX
        """
        replaceSDexToShellDex(os.path.join(stCurrentPt, "result.apk"))
        print("[*] 壳DEX替换原apk包内的DEX文件完成")
```

5. 添加脱壳lib库到原apk中

```python
        """
        5. 添加脱壳lib库到原apk中
        """
        addLib("result.apk")
```

6. apk签名

```python
        """
        6. apk签名
        """
        signApk(os.path.join(stCurrentPt, "result.apk"), os.path.join(stCurrentPt, "demo.keystore"))
        print("[*] 签名完成，生成apk文件: {}".format(os.path.join(stCurrentPt, "result.apk")))
```

# 内存加载DEX

了解内存加载DEX文件内存加载技术之前，我们需要了解DEX文件加载这一过程。

**DEX文件加载过程：**即下面左图所示的API调用链就是加载过程。DEX文件加载的核心是最后一层，通过Native层函数传入DEX文件从而获取一个cookie值

所以我们要**实现内存加载DEX**的话，不仅需要自己重写这套DEX文件调用链，最主要的是寻找一个Native层API实现传入DEX文件字节流来获取cookie值，就是下面右图所示调用链，API即openMemory(4.3 ART虚拟机以后， 4.3及其以前Dalvik虚拟机用openDexFile([byte...)API)即可实现这样的功能

![内存加载DEX](/images/内存加载DEX.png)

Android 8以后BaseDexClassLoader类就有内存加载的能力，参考Android 8源码，已经加入了这样的接口，我们只需要将相关代码文件copy下来，将最底层的Native函数用openMemory替代即可

![image-20200415234950548](/images/image-20200415234950548.png)

## 自定义MyDexClassLoader

通过dlopen和dlsym的方法找到openMemory函数实现核心函数即可

```c++
JNICALL extern "C"
JNIEXPORT jlong JNICALL
Java_cn_yongye_inmemoryloaddex_DexFile_createCookieWithArray(JNIEnv *env, jclass clazz,
                                                             jbyteArray buf, jint start, jint end) {
    // TODO: implement createCookieWithArray()
    void *artlib =  fake_dlopen("/system/lib/libart.so", RTLD_LAZY);
    if(!artlib){
        exit(0);
    }
    org_artDexFileOpenMemory22 openMemory22 = (org_artDexFileOpenMemory22)fake_dlsym(artlib,
                                                                        "_ZN3art7DexFile10OpenMemoryEPKhjRKNSt3__112basic_stringIcNS3_11char_traitsIcEENS3_9allocatorIcEEEEjPNS_6MemMapEPKNS_7OatFileEPS9_");

    if(!openMemory22){
        exit(0);
    }
    jbyte *bytes;
    char *pDex  = NULL;
    std::string location = "";
    std::string err_msg;


    bytes = env->GetByteArrayElements(buf, 0);
    int inDexLen = env->GetArrayLength(buf);
    pDex = new char[inDexLen + 1];
    memset(pDex, 0, inDexLen + 1);
    memcpy(pDex, bytes, inDexLen);
    pDex[inDexLen] = 0;
    env->ReleaseByteArrayElements(buf, bytes, 0);
    const Header *dex_header = reinterpret_cast<const Header *>(pDex);
    void *value = openMemory22((const unsigned char *)pDex, inDexLen, location, dex_header->checksum_, NULL, NULL, &err_msg);

    jlong cookie = replace_cookie(env, value, 22);
    return cookie;

}
```

还需要实现DEX加载器另外一个重要功能，即加载类的能力，这个功能本来也是需要Native函数实现的，这里我们可以通过反射调用DexFile类的defineClass方法(加载类的调用链是：findClass->defineClass)实现

```java
private Class defineClass(String name, ClassLoader loader, Object cookie,
                              DexFile dexFile, List<Throwable> suppressed) {
        Class result = null;
        try {
            Class clsDexFile = Class.forName("dalvik.system.DexFile");
            Method mdDefineClass = clsDexFile.getDeclaredMethod("defineClass", String.class, ClassLoader.class, long.class, List.class);
            mdDefineClass.setAccessible(true);
            result = (Class) mdDefineClass.invoke(null, name, loader, cookie, suppressed);
        } catch (NoClassDefFoundError e) {
            if (suppressed != null) {
                suppressed.add(e);
            }
        } catch (ClassNotFoundException e) {
            if (suppressed != null) {
                suppressed.add(e);
            }
        } catch (NoSuchMethodException e) {
            e.printStackTrace();
        } catch (IllegalAccessException e) {
            e.printStackTrace();
        } catch (InvocationTargetException e) {
            e.printStackTrace();
        }
        return result;
    }
```

# Cmake、ninja编译cpp文件

> v2 推荐：直接用 `cpp/build.sh`（或 `cpp/build.bat`）基于 ndk-build 一次编译全部 ABI，
> 输出到 `lib/<abi>/`。下面的单 ABI cmake 流程仅作原理参考。

native层代码源文件在cpp目录下，可以直接调用cpp/build.bat一键编译批处理文件

## cmake生成ninja编译配置文件

```powershell
D:\Android\Sdk\cmake\3.10.2.4988404\bin\cmake.exe . -DCMAKE_BUILD_TYPE=Debug -DCMAKE_TOOLCHAIN_FILE=D:\Android\Sdk\ndk\20.0.5594570\build\c make\android.toolchain.cmake -DANDROID_ABI=x86 -DANDROID_NDK=D:\Android\Sdk\ndk\20.0.5594570 -DANDROID_PLATFORM=android-16 -DCMAKE_ANDROID_ARCH_ABI=x86 -DCMAKE_ANDROID_NDK=D:\Android\Sdk\ndk\20.0.5594570 -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_MAKE_PROGRAM=D:\Android\Sdk\cmake\3.10.2.4988404\bin\ninja.exe -DCMAKE_SYSTEM_NAME=Android -DCMAKE_SYSTEM_VERSION=16 -GNinja
```

## ninja生成so文件

只是修改cpp文件，直接运行ninja命令，不用重新用cmake生成ninja配置文件
如果有新cpp文件的增加删除，还是需要删除配置文件，重新运行cmake的

```powershell
D:\Android\Sdk\cmake\3.10.2.4988404\bin\ninja.exe
```

# 参考

【1】[Android中apk加固完善篇之内存加载dex方案实现原理(不落地方式加载)](http://www.520monkey.com/archives/629)

【2】[内存解密并加载DEX](https://github.com/woxihuannisja/Bangcle)
