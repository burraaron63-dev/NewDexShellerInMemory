//
// 已废弃 (Deprecated)
//
// 旧版把「加载原始 DEX + 替换 ClassLoader + 启动原始 Application」的编排写在 native 层，
// 存在多处硬伤：
//   1. 写死 com.h.MyAdmin 测试类，任何真实 APK 都会崩溃；
//   2. 大量 ActivityThread 内部字段/方法反射，随 Android 版本变化极易失效；
//   3. 无 64 位/多机型适配。
//
// 现已全部迁移到 Java 层 cn.yongye.nativeshell.StubApp（按 API 分发，26+ 用官方
// InMemoryDexClassLoader，21~25 回退 native OpenMemory），本文件不再参与编译。
//
// 保留空文件仅为兼容旧的构建脚本；请勿在此新增代码。
