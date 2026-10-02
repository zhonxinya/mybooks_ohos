#pragma once

#include <map>
#include <mutex>
#include <string>

struct cJSON;

namespace talebook {

class JsonStore {
public:
    explicit JsonStore(std::string rootDir);
    ~JsonStore();

    /**
     * 账号身份根目录：secure 凭据与各 JSON blob（下载记录/阅读历史/书签）的落盘位置；
     * 会话 Cookie 目录由 TalebookCore 一并向该目录切换。
     * 默认与全局根（preferences.json 所在目录）相同，因此既有单账号安装升级后无需迁移文件。
     */
    void setIdentityDir(const std::string &dir);
    std::string identityDir() const { return identityDir_; }

    std::string read(const std::string &name, const std::string &defaultValue = "[]") const;
    bool write(const std::string &name, const std::string &json) const;
    std::string readPref(const std::string &key, const std::string &defaultValue = "") const;
    bool writePref(const std::string &key, const std::string &value) const;
    /** 一次加载/保存 preferences.json，批量写入多个键（JSON object 字符串） */
    bool writePrefsBatch(const std::string &jsonObject) const;
    std::string readSecure(const std::string &key, const std::string &defaultValue = "") const;
    bool writeSecure(const std::string &key, const std::string &value) const;
    /**
     * 全局凭据读写：固定落在全局根（不随账号身份根变化）。
     * 用于 SoNovel 等与账号无关的全局服务配置。
     */
    std::string readSecureGlobal(const std::string &key, const std::string &defaultValue = "") const;
    bool writeSecureGlobal(const std::string &key, const std::string &value) const;

private:
    std::string rootDir_;
    /** 账号身份根；为空时回退 rootDir_（兼容单账号）。 */
    std::string identityDir_;
    std::string pathFor(const std::string &name) const;
    std::string prefPath() const;
    std::string securePath() const;
    std::string globalSecurePath() const;
    /** 把 preferences.json 载入内存；之后的读写都走这份缓存。调用方须已持有 prefMutex_。 */
    void ensurePrefLocked() const;
    /** 用 updated 替换缓存并落盘。失败时不改缓存，并释放 updated。调用方须已持有 prefMutex_。 */
    bool commitPrefLocked(struct cJSON *updated) const;

    mutable std::mutex prefMutex_;
    mutable struct cJSON *prefObject_ = nullptr;
    mutable bool prefLoaded_ = false;

    /** secure 凭据文件的进程内读缓存：ensureBaseUrl 等热点读免每次读盘 + cJSON 解析。 */
    struct SecureCache {
        bool valid = false;
        std::map<std::string, std::string> fields;
    };
    /** 保护两个 SecureCache：UI 线程与 NAPI 工作线程并发读写。 */
    mutable std::mutex secureMutex_;
    mutable SecureCache secureCache_;
    mutable SecureCache globalSecureCache_;

    /** 带缓存读：缓存未命中时读盘解析整个文件并摊平为 string 字段表。 */
    std::string readCached(SecureCache &cache, const std::string &path, const std::string &key,
                           const std::string &defaultValue) const;
    /** 写入成功后失效对应缓存，下次读取重新加载。 */
    void invalidate(SecureCache &cache) const;
};

} // namespace talebook
