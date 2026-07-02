package cn.yongye.nativeshell;

import android.app.Application;
import android.content.Context;
import android.os.Build;
import android.util.Log;

import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

import cn.yongye.nativeshell.common.Config;
import cn.yongye.nativeshell.common.FileUtils;
import cn.yongye.nativeshell.inmemoryloaddex.MyDexClassLoader;

/**
 * 壳 Application。整个「解密 -> 内存加载原始 dex -> 替换 ClassLoader -> 启动原始 Application」
 * 的编排全部放在 Java 层完成，按 API 等级分发不同的内存加载实现，以解决各机型/各 Android 版本兼容问题：
 *
 *   - API 26+ (Android 8.0+)：使用系统公开的 dalvik.system.InMemoryDexClassLoader，
 *     官方支持、无需 native hack，一直到 Android 14+ 均可用。
 *   - API 21~25 (Android 5.0~7.1)：InMemoryDexClassLoader 不存在，回退到 native
 *     OpenMemory 方案（MyDexClassLoader + libdalvik_system_DexFile.so）。
 *
 * 相比旧版把加载流程写死在 native 层（只适配 Android 5.x + x86 + 32 位），此设计天然覆盖
 * 绝大多数在网设备，并把仅剩的 native 依赖限制在少数老旧机型上。
 */
public class StubApp extends Application {

    public static final String TAG = "yongye";

    @Override
    protected void attachBaseContext(Context base) {
        super.attachBaseContext(base);
        try {
            loadRealApp();
        } catch (Throwable t) {
            // 任何失败都完整记录，避免旧版那样直接 exit(0) 把进程静默杀死
            Log.e(TAG, "加载原始 DEX 失败", t);
        }
    }

    private void loadRealApp() throws Exception {
        // 1. 从壳 classes.dex 尾部解密取出全部原始 dex（支持多 dex）
        List<byte[]> dexes = FileUtils.extractPayloadDexes(this);
        if (dexes == null || dexes.isEmpty()) {
            Log.e(TAG, "未在壳内找到原始 DEX，跳过");
            return;
        }
        Log.i(TAG, "解密得到原始 DEX 数量: " + dexes.size());

        // 2. 取当前壳的 LoadedApk 及其 ClassLoader 作为父加载器
        Object activityThread = currentActivityThread();
        Object loadedApk = getShellLoadedApk(activityThread);
        ClassLoader parent = (ClassLoader) getField(loadedApk, "mClassLoader");

        // 3. 按版本构建内存 ClassLoader
        ClassLoader realLoader = buildInMemoryClassLoader(dexes, parent);
        if (realLoader == null) {
            Log.e(TAG, "构建内存 ClassLoader 失败");
            return;
        }

        // 4. 把原始 dex 的 ClassLoader 装回当前 LoadedApk，后续 Activity 等组件即可加载
        setField(loadedApk, "mClassLoader", realLoader);
        Log.i(TAG, "ClassLoader 替换完成: " + realLoader.getClass().getName());

        // 5. 启动原始 Application
        startRealApplication(activityThread, loadedApk);
    }

    /** 按 API 等级分发内存加载实现 */
    private ClassLoader buildInMemoryClassLoader(List<byte[]> dexes, ClassLoader parent) {
        ByteBuffer[] buffers = new ByteBuffer[dexes.size()];
        for (int i = 0; i < dexes.size(); i++) {
            buffers[i] = ByteBuffer.wrap(dexes.get(i));
        }

        final int sdk = Build.VERSION.SDK_INT;
        try {
            if (sdk >= 26) {
                // Android 8.0+：官方 InMemoryDexClassLoader（反射构造，避免在老系统上触发校验）
                Class<?> cls = Class.forName("dalvik.system.InMemoryDexClassLoader");
                if (sdk >= 29) {
                    // API 29+ 支持一次性传入 ByteBuffer[]
                    Constructor<?> ctor = cls.getConstructor(ByteBuffer[].class, ClassLoader.class);
                    return (ClassLoader) ctor.newInstance(buffers, parent);
                } else {
                    // API 26~28 只有单 ByteBuffer 构造，多 dex 通过链式父子关系串起来
                    Constructor<?> ctor = cls.getConstructor(ByteBuffer.class, ClassLoader.class);
                    ClassLoader cl = parent;
                    for (ByteBuffer buf : buffers) {
                        cl = (ClassLoader) ctor.newInstance(buf, cl);
                    }
                    return cl;
                }
            } else {
                // Android 5.0~7.1：native OpenMemory 回退路径
                return new MyDexClassLoader(buffers, parent);
            }
        } catch (Throwable t) {
            Log.e(TAG, "buildInMemoryClassLoader 异常, sdk=" + sdk, t);
            // 最后兜底：即使高版本失败也尝试 native 路径
            try {
                return new MyDexClassLoader(buffers, parent);
            } catch (Throwable t2) {
                Log.e(TAG, "native 兜底加载也失败", t2);
                return null;
            }
        }
    }

    /** 重置并启动原始 APK 的 Application 组件 */
    private void startRealApplication(Object activityThread, Object loadedApk) throws Exception {
        String realAppName = Config.MAIN_APPLICATION;
        if (realAppName == null || realAppName.isEmpty()) {
            realAppName = "android.app.Application";
        }

        Object boundApp = getField(activityThread, "mBoundApplication"); // AppBindData
        Object boundLoadedApk = getField(boundApp, "info");
        // 清空已创建的壳 Application，makeApplication 才会重新创建
        setField(boundLoadedApk, "mApplication", null);

        Object initialApp = getField(activityThread, "mInitialApplication");
        Object allApps = getField(activityThread, "mAllApplications"); // ArrayList<Application>
        if (allApps instanceof List) {
            //noinspection SuspiciousMethodCalls
            ((List) allApps).remove(initialApp);
        }

        // 改写 className，指向原始 Application
        Object apkAppInfo = getField(boundLoadedApk, "mApplicationInfo");
        setField(apkAppInfo, "className", realAppName);
        Object bindAppInfo = getField(boundApp, "appInfo");
        setField(bindAppInfo, "className", realAppName);

        // LoadedApk.makeApplication(boolean, Instrumentation)
        Method makeApplication = boundLoadedApk.getClass().getMethod(
                "makeApplication", boolean.class,
                Class.forName("android.app.Instrumentation"));
        makeApplication.setAccessible(true);
        Application realApp = (Application) makeApplication.invoke(boundLoadedApk, false, null);

        setField(activityThread, "mInitialApplication", realApp);
        realApp.onCreate();
        Log.i(TAG, "原始 Application 启动完成: " + realAppName);
    }

    // ------------------------------------------------------------------
    // 反射辅助
    // ------------------------------------------------------------------

    private static Object currentActivityThread() throws Exception {
        Class<?> at = Class.forName("android.app.ActivityThread");
        Method m = at.getMethod("currentActivityThread");
        m.setAccessible(true);
        return m.invoke(null);
    }

    private Object getShellLoadedApk(Object activityThread) throws Exception {
        Object mPackages = getField(activityThread, "mPackages"); // ArrayMap<String, WeakReference<LoadedApk>>
        Method get = mPackages.getClass().getMethod("get", Object.class);
        Object weakRef = get.invoke(mPackages, getPackageName());
        Method refGet = Class.forName("java.lang.ref.Reference").getMethod("get");
        return refGet.invoke(weakRef);
    }

    private static Object getField(Object obj, String name) throws Exception {
        Field f = findField(obj.getClass(), name);
        f.setAccessible(true);
        return f.get(obj);
    }

    private static void setField(Object obj, String name, Object value) throws Exception {
        Field f = findField(obj.getClass(), name);
        f.setAccessible(true);
        f.set(obj, value);
    }

    /** 沿父类链查找字段，兼容不同 Android 版本字段所在的类层级 */
    private static Field findField(Class<?> cls, String name) throws NoSuchFieldException {
        Class<?> c = cls;
        while (c != null) {
            try {
                return c.getDeclaredField(name);
            } catch (NoSuchFieldException e) {
                c = c.getSuperclass();
            }
        }
        throw new NoSuchFieldException(name + " not found in " + cls);
    }
}
