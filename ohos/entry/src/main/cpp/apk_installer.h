#ifndef MYBOOKS_APK_INSTALLER_H
#define MYBOOKS_APK_INSTALLER_H

#include <string>

// 把已下载好的 APK 交给系统安装器（仅 Android）。
// contentUri 形如 content://<authority>/updates/<name>.apk，由壳工程的 ApkFileProvider 提供。
// 返回空串表示已发起安装；否则返回错误描述，供 UI 直接展示。
// HarmonyOS 端没有应用内安装能力，固定返回错误描述。
std::string InstallApkWithSystemInstaller(const std::string &contentUri);

#endif  // MYBOOKS_APK_INSTALLER_H
