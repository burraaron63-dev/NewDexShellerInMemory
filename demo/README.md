# demo —— 加固真机测试

一个最小「受害者」App，专门用来在真机上验证加固全链路是否成功。

## 它为什么能证明加固有效

`demo` 是**多 dex**的，且主 dex 跨 dex 调用了 `classes2.dex` 里的类：

- `DemoApp`（原始 `Application`，classes.dex）`onCreate` 打 `APP_ONCREATE`
- `MainActivity`（原始 Activity，classes.dex）`onCreate` 打 `ACTIVITY_ONCREATE`
- `Secondary`（classes2.dex）`ping()` 返回 `SECONDARY_OK`，被上面两者调用

加固后若三条 marker 都出现在 logcat，说明：
1. 壳解密并取出了原始 dex（`APP_ONCREATE`、`原始 Application 启动完成`）
2. ClassLoader 被成功替换，原始组件可加载（`ACTIVITY_ONCREATE`）
3. 多 dex 互相可见（`SECONDARY_OK`）—— 即 #1（API 26~28 链式 ClassLoader 断链）的回归点

## 用法

```bash
# 一条命令：构建 demo -> 加固 -> 装到已连接设备 -> 拉起 -> 校验 marker
./demo/device_test.sh              # 只验加固包
./demo/device_test.sh --baseline   # 先验未加固基线，再验加固包
```

前置：JDK（脚本会用 JAVA_HOME / java_home 自动定位，绕开 macOS 的 Xcode javac 桩）、
Android SDK（build-tools 需有 `dx`，如 30.0.3；aapt2/zipalign/apksigner 用最新即可）、
一台 `adb devices` 可见的真机或模拟器。

只想单独出 demo.apk：`./demo/build_demo.sh`（产物 `demo/demo.apk`）。

## 覆盖范围说明

`device_test.sh` 会打印设备 API 对应的加载分支：

| 设备 API | 走哪条路径 | 本 demo 能覆盖 |
| --- | --- | --- |
| 29+ (10+) | `InMemoryDexClassLoader(ByteBuffer[])` | ✅ 已在 Android 15 真机验证 |
| 26~28 (8.0~8.1) | 合并 dexElements（#1 修复点） | 需 8.0~8.1 模拟器才命中 |
| 23~25 (6.0~7.1) | 无内存方案，**预期 FAIL** | 已知不支持（cookie/defineClass ABI 不兼容） |
| 21~22 (5.0/5.1) | native `OpenMemory` | 需 5.0/5.1 模拟器 + 先 `cd cpp && ./build.sh` 出 so |

> 要专门回归 #1，请在 **8.0 / 8.1 模拟器**上跑本脚本——demo 的跨 dex 调用正是该 bug 的触发条件。
