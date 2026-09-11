#pragma once

#include <string>

namespace talebook {

class JsonStore {
public:
    explicit JsonStore(std::string rootDir);

    std::string read(const std::string &name, const std::string &defaultValue = "[]") const;
    bool write(const std::string &name, const std::string &json) const;
    std::string readPref(const std::string &key, const std::string &defaultValue = "") const;
    bool writePref(const std::string &key, const std::string &value) const;
    /** 一次加载/保存 preferences.json，批量写入多个键（JSON object 字符串） */
    bool writePrefsBatch(const std::string &jsonObject) const;
    std::string readSecure(const std::string &key, const std::string &defaultValue = "") const;
    bool writeSecure(const std::string &key, const std::string &value) const;

private:
    std::string rootDir_;
    std::string pathFor(const std::string &name) const;
    std::string prefPath() const;
    std::string securePath() const;
};

} // namespace talebook
