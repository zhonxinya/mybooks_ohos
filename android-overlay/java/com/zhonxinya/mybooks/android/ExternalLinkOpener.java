package com.zhonxinya.mybooks.android;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

/**
 * 用系统默认应用打开 http(s) 链接（仅 Android）。
 *
 * 为什么不走 ArkTS 的 startAbility：ArkUI-X 的隐式 Want（viewAction + uri）在 Android 上先在
 * 自身 bundle 里解析目标，解析不到就直接抛 Internal error，压根到不了平台侧——与 ApkInstaller
 * 遇到的是同一个限制。故改由 ArkTS 经 libentry 的原生桥（apiOpenExternalUrl）调到这里。
 *
 * 上下文与 ApkInstaller / BatteryReader 同源：ApkFileProvider.onCreate 在进程启动时执行。
 */
public final class ExternalLinkOpener {
    private static Context appContext;

    private ExternalLinkOpener() {
    }

    /** 由 ApkFileProvider.onCreate 调用，记录应用上下文。 */
    static void init(Context context) {
        if (context != null) {
            appContext = context.getApplicationContext();
        }
    }

    /**
     * 打开外部链接。
     *
     * @param url 仅接受 http/https
     * @return 空串表示已发起；否则为可直接展示的错误描述
     */
    public static String open(String url) {
        if (url == null || url.isEmpty()) {
            return "链接不可用";
        }
        // 只放行 http/https：本方法的入参可能来自服务端下发的数据，
        // 放开任意协议等于允许用 file:// intent:// 之类的 URI 触发其它应用的行为
        final String lower = url.toLowerCase();
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            return "链接协议不受支持";
        }
        final Context context = appContext;
        if (context == null) {
            return "应用上下文未就绪";
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse(url));
            // 从 Application Context 启动 Activity 必须带 NEW_TASK
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            context.startActivity(intent);
            return "";
        } catch (ActivityNotFoundException e) {
            return "没有可打开该链接的应用";
        } catch (Exception e) {
            return "打开链接失败：" + e.getMessage();
        }
    }
}
