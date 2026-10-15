package com.zhonxinya.mybooks.android;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.database.Cursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;

import java.io.File;
import java.io.FileNotFoundException;

/**
 * 只读暴露 <filesDir>/updates/*.apk，供系统安装器通过 content:// 读取应用内下载好的安装包。
 *
 * 为什么需要它：Android 7 起禁止把 file:// URI 交给其它应用（FileUriExposedException），
 * 而 ArkUI-X 的 Want→Intent 映射（StageActivity#startActivity）只会 setData，不会附加
 * FLAG_GRANT_READ_URI_PERMISSION。改为由 ApkInstaller 自己构造 Intent 并把读授权随 Intent
 * 一次性授给安装器后，本 provider 保持 exported="false"（只允许本进程或已授权方读取）。
 *
 * 暴露范围仅限 filesDir/updates 下的 .apk（安装包本身就是公开发布物），不接受其它路径。
 */
public class ApkFileProvider extends ContentProvider {
    /** 与 AndroidManifest.xml 中 android:authorities 的后缀保持一致。 */
    public static final String AUTHORITY_SUFFIX = ".apkprovider";

    private static final String APK_MIME = "application/vnd.android.package-archive";
    private static final String APK_SUFFIX = ".apk";
    private static final String UPDATES_DIR = "updates";
    /**
     * ArkUI-X 会把应用的 filesDir 映射成 &lt;getFilesDir()&gt;/files（见 StageApplicationDelegate#createStagePath
     * 里的 setFileDir），与 ArkTS 侧 context.filesDir 是同一个目录，安装包就写在这里。
     */
    private static final String ARKUIX_FILES_SUBDIR = "files";

    @Override
    public boolean onCreate() {
        // provider 在进程启动时由系统创建，比页面更早拿到 Application Context；
        // 安装时要用它 startActivity，见 ApkInstaller
        ApkInstaller.init(getContext());
        // 电池状态读取同理，见 BatteryReader
        BatteryReader.init(getContext());
        // 外链打开同理，见 ExternalLinkOpener
        ExternalLinkOpener.init(getContext());
        return true;
    }

    @Override
    public String getType(Uri uri) {
        // 只提供 APK：显式返回 MIME，安装器据此匹配 application/vnd.android.package-archive
        return APK_MIME;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        return ParcelFileDescriptor.open(resolve(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    /** 把 URI 收敛到 <filesDir>/updates/<name>.apk；越界或不存在一律视为未找到。 */
    private File resolve(Uri uri) throws FileNotFoundException {
        if (getContext() == null) {
            throw new FileNotFoundException("provider not attached: " + uri);
        }
        String name = uri.getLastPathSegment();
        if (name == null || !name.endsWith(APK_SUFFIX) || name.contains("..") || name.contains("/")) {
            throw new FileNotFoundException("unsupported path: " + uri);
        }
        File file = new File(new File(new File(getContext().getFilesDir(), ARKUIX_FILES_SUBDIR),
            UPDATES_DIR), name);
        if (!file.isFile()) {
            throw new FileNotFoundException("missing apk: " + file);
        }
        return file;
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs,
                        String sortOrder) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] selectionArgs) {
        return 0;
    }
}
