package com.dexshell.demo;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

/** 原始 Activity，位于隐藏的原始 dex。能被拉起即证明 ClassLoader 已成功替换为原始 dex 加载器。 */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        String msg = "ACTIVITY_ONCREATE secondary=" + Secondary.ping();
        Log.i("DEXSHELL_DEMO", msg);

        TextView tv = new TextView(this);
        tv.setText("DexShell demo 运行中\n" + msg);
        tv.setTextSize(20);
        tv.setPadding(48, 160, 48, 48);
        setContentView(tv);
    }
}
