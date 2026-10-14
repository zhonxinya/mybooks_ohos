package com.zhonxinya.mybooks.android;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;

/**
 * 应用内升级的最后一步：把下载好的 APK 交给系统安装器。
 *
 * 为什么不走 ArkTS 的 startAbility：ArkUI-X 的隐式 Want（viewAction + uri）在 Android 上
 * 先在自身 bundle 里解析目标，解析不到就直接抛 Internal error，根本到不了平台侧
 * （实测连打开 https 链接都会失败）。故改由 ArkTS 经本模块的原生桥（libentry.so 的
 * apiInstallApk）调用这里。
 *
 * 上下文从哪来：不用 @hide 的 ActivityThread，而是复用自己的 ContentProvider——
 * ApkFileProvider 在进程启动时会被系统创建，其 onCreate 拿到的就是 Application Context。
 */
public final class ApkInstaller {
    private static final String APK_MIME = "application/vnd.android.package-archive";

    private static Context appContext;

    private ApkInstaller() {
    }

    /** 由 ApkFileProvider.onCreate 调用，记录应用上下文。 */
    static void init(Context context) {
        if (context != null) {
            appContext = context.getApplicationContext();
        }
        // 走 System.loadLibrary 触发 libentry.so 的 JNI_OnLoad：只有那一刻的类加载器是应用自身的，
        // 原生侧才能在那里把本类缓存成全局引用。之后从 ArkTS 线程过来的原生调用再 FindClass
        // 只会命中系统类加载器，找不到应用类（实测报「找不到安装桥接类」）。
        try {
            System.loadLibrary("entry");
        } catch (UnsatisfiedLinkError e) {
            // 加载失败不致命：原生侧仍有 FindClass 兜底
        }
    }

    /**
     * 唤起系统安装器。
     *
     * @param contentUri 形如 content://&lt;authority&gt;/updates/xxx.apk
     * @return 空串表示已发起；否则为可直接展示的错误描述
     */
    public static String install(String contentUri) {
        final Context context = appContext;
        if (context == null) {
            return "应用上下文未就绪";
        }
        if (contentUri == null || contentUri.isEmpty()) {
            return "安装包地址为空";
        }
        try {
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(Uri.parse(contentUri), APK_MIME);
            // provider 是 exported=false，靠这里的一次性读授权让安装器能读到安装包
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            context.startActivity(intent);
            return "";
        } catch (ActivityNotFoundException e) {
            return "系统没有可用的安装器";
        } catch (Exception e) {
            return "唤起安装器失败：" + e.getMessage();
        }
    }
}
