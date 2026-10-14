package com.zhonxinya.mybooks.android;

import android.content.Context;
import android.os.BatteryManager;

/**
 * 读取电池状态，供 ArkTS 阅读页页脚显示。
 *
 * ArkUI-X 的 Android SDK 没有 batteryinfo 插件（调 batteryInfo 会抛
 * "Cannot read property batterySOC of undefined"），故经 libentry 的原生桥
 * （apiGetBatteryInfo）调到这里，补上鸿蒙端由系统插件提供的能力。
 *
 * 上下文与 ApkInstaller 同源：ApkFileProvider.onCreate 在进程启动时执行。
 */
public final class BatteryReader {
    private static Context appContext;

    private BatteryReader() {
    }

    /** 由 ApkFileProvider.onCreate 调用，记录应用上下文。 */
    static void init(Context context) {
        if (context != null) {
            appContext = context.getApplicationContext();
        }
    }

    /**
     * @return JSON 形如 {"level":87,"charging":true}；无法读取时返回空串
     */
    public static String read() {
        final Context context = appContext;
        if (context == null) {
            return "";
        }
        try {
            BatteryManager manager =
                (BatteryManager) context.getSystemService(Context.BATTERY_SERVICE);
            if (manager == null) {
                return "";
            }
            int level = manager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY);
            if (level < 0 || level > 100) {
                // 取不到容量时该属性返回 Integer.MIN_VALUE，按不可用处理
                return "";
            }
            boolean charging = manager.isCharging();
            return "{\"level\":" + level + ",\"charging\":" + charging + "}";
        } catch (Exception e) {
            return "";
        }
    }
}
