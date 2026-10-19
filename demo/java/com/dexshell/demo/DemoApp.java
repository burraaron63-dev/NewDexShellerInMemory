package com.dexshell.demo;

import android.app.Application;
import android.util.Log;

/**
 * 被加固的「原始」Application。加固后由壳 StubApp 解密原始 dex、换 ClassLoader 后再启动它。
 * onCreate 里打一条唯一 marker，并跨 dex 调用 Secondary（Secondary 在 classes2.dex），
 * 以此在真机上证明：解壳成功 + 原始 Application 被正确启动 + 多 dex 互相可见。
 */
public class DemoApp extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Log.i("DEXSHELL_DEMO", "APP_ONCREATE pkg=" + getPackageName()
                + " secondary=" + Secondary.ping());
    }
}
