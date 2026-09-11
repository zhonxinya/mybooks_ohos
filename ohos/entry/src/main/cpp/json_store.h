#pragma once

#include <string>

namespace talebook {

class JsonStore {
public:
    explicit JsonStore(std::string rootDir);

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
};

} // namespace talebook
