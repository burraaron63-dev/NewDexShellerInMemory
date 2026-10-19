package com.dexshell.demo;

/** 故意单独放进 classes2.dex。主 dex（DemoApp/MainActivity）对它的调用就是「跨 dex 引用」，
 *  用来回归 API 26~28 链式 ClassLoader 断链 bug（本次 #1 修复点）。 */
public class Secondary {
    public static String ping() {
        return "SECONDARY_OK";
    }
}
