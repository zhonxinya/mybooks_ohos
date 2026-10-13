#include "apk_installer.h"

#ifdef __ANDROID__

#include <dlfcn.h>
#include <jni.h>

namespace {

JavaVM *g_javaVm = nullptr;
jclass g_installerClass = nullptr;

constexpr const char *kInstallerClass = "com/zhonxinya/talebook/ApkInstaller";
constexpr const char *kInstallMethod = "install";
constexpr const char *kInstallSignature = "(Ljava/lang/String;)Ljava/lang/String;";

// 取 JavaVM 有两条路：模块被 System.loadLibrary 加载时 JNI_OnLoad 已经给过；
// 否则（ArkUI-X 对 NAPI 模块多用 dlopen）退回 JNI 标准的 JNI_GetCreatedJavaVMs。
JavaVM *ResolveJavaVm()
{
    if (g_javaVm != nullptr) {
        return g_javaVm;
    }
    const char *candidates[] = {"libart.so", "libnativehelper.so"};
    for (const char *name : candidates) {
        void *handle = dlopen(name, RTLD_NOW | RTLD_NOLOAD);
        if (handle == nullptr) {
            handle = dlopen(name, RTLD_NOW);
        }
        if (handle == nullptr) {
            continue;
        }
        using GetCreatedJavaVmsFn = jint (*)(JavaVM **, jsize, jsize *);
        auto fn = reinterpret_cast<GetCreatedJavaVmsFn>(dlsym(handle, "JNI_GetCreatedJavaVMs"));
        if (fn != nullptr) {
            JavaVM *vm = nullptr;
            jsize count = 0;
            if (fn(&vm, 1, &count) == JNI_OK && count >= 1 && vm != nullptr) {
                g_javaVm = vm;
                return g_javaVm;
            }
        }
        dlclose(handle);
    }
    return nullptr;
}

/** 取安装桥接类；成功则缓存成全局引用（省去每次查找）。 */
jclass ResolveInstallerClass(JNIEnv *env)
{
    if (g_installerClass != nullptr) {
        return g_installerClass;
    }
    jclass local = env->FindClass(kInstallerClass);
    if (local == nullptr) {
        if (env->ExceptionCheck()) {
            env->ExceptionClear();
        }
        return nullptr;
    }
    g_installerClass = static_cast<jclass>(env->NewGlobalRef(local));
    env->DeleteLocalRef(local);
    return g_installerClass;
}

}  // namespace

// JNI_OnLoad 由 System.loadLibrary 触发（见 ApkInstaller.init），此刻的类加载器才是应用自身的，
// 从这里 FindClass 才能拿到应用类；若等到 ArkTS 的原生调用里再找，只会命中系统类加载器。
extern "C" JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved)
{
    (void)reserved;
    g_javaVm = vm;
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) == JNI_OK && env != nullptr) {
        ResolveInstallerClass(env);
    }
    return JNI_VERSION_1_6;
}

std::string InstallApkWithSystemInstaller(const std::string &contentUri)
{
    if (contentUri.empty()) {
        return "安装包地址为空";
    }
    JavaVM *vm = ResolveJavaVm();
    if (vm == nullptr) {
        return "无法获取 Java 虚拟机";
    }

    JNIEnv *env = nullptr;
    bool attached = false;
    const jint status = vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if (vm->AttachCurrentThread(&env, nullptr) != JNI_OK) {
            return "无法附加到 Java 线程";
        }
        attached = true;
    } else if (status != JNI_OK || env == nullptr) {
        return "无法获取 JNIEnv";
    }

    std::string result;
    jclass installerClass = ResolveInstallerClass(env);
    if (installerClass == nullptr) {
        result = "找不到安装桥接类";
    } else {
        jmethodID method = env->GetStaticMethodID(installerClass, kInstallMethod, kInstallSignature);
        if (method == nullptr) {
            env->ExceptionClear();
            result = "找不到安装方法";
        } else {
            jstring uri = env->NewStringUTF(contentUri.c_str());
            auto ret = static_cast<jstring>(env->CallStaticObjectMethod(installerClass, method, uri));
            if (env->ExceptionCheck()) {
                env->ExceptionClear();
                result = "调用安装器失败";
            } else if (ret != nullptr) {
                const char *chars = env->GetStringUTFChars(ret, nullptr);
                if (chars != nullptr) {
                    result.assign(chars);
                    env->ReleaseStringUTFChars(ret, chars);
                }
                env->DeleteLocalRef(ret);
            }
            if (uri != nullptr) {
                env->DeleteLocalRef(uri);
            }
        }
    }

    if (attached) {
        vm->DetachCurrentThread();
    }
    return result;
}

#else

std::string InstallApkWithSystemInstaller(const std::string &contentUri)
{
    (void)contentUri;
    return "应用内安装仅支持 Android";
}

#endif
