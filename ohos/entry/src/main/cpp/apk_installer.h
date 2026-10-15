#ifndef MYBOOKS_APK_INSTALLER_H
#define MYBOOKS_APK_INSTALLER_H

#include <string>

// 把已下载好的 APK 交给系统安装器（仅 Android）。
// contentUri 形如 content://<authority>/updates/<name>.apk，由壳工程的 ApkFileProvider 提供
// （类与方法见 android-overlay/java/com/zhonxinya/mybooks/android/）。
// 返回空串表示已发起安装；否则返回错误描述，供 UI 直接展示。
// HarmonyOS 端没有应用内安装能力，固定返回错误描述。
std::string InstallApkWithSystemInstaller(const std::string &contentUri);

// 读电池状态（仅 Android，壳工程的 BatteryReader.read 经 BatteryManager 取值）。
// 成功返回 JSON 形如 {"level":87,"charging":true}；失败/不支持返回空串。
// HarmonyOS 端由 ArkTS 直接用系统 batteryInfo 插件，不经此桥。
std::string ReadBatteryJson();

// 用系统默认应用打开外部链接（仅 Android，壳工程的 ExternalLinkOpener.open 构造
// ACTION_VIEW Intent）。返回空串表示已发起；否则返回错误描述供 UI 展示。
// HarmonyOS 端由 ArkTS 直接用隐式 Want（viewData）拉起，不经此桥。
std::string OpenUrlWithSystemBrowser(const std::string &url);

#endif  // MYBOOKS_APK_INSTALLER_H
