#include "json_store.h"

#include "cjson/cJSON.h"
#include "path_util.h"

#include <cstdio>
#include <fstream>
#include <sstream>
#include <sys/stat.h>

namespace talebook {
namespace {

cJSON *loadObjectFromFile(const std::string &path)
{
    std::ifstream in(path);
    if (!in.is_open()) {
        return cJSON_CreateObject();
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    const std::string content = ss.str();
    if (content.empty()) {
        return cJSON_CreateObject();
    }
    cJSON *parsed = cJSON_Parse(content.c_str());
    return parsed != nullptr ? parsed : cJSON_CreateObject();
}

/**
 * 原子写：先写临时文件再 rename 替换。
 * 直接 trunc 原文件时，若写入中断或磁盘满，会让 preferences.json /
 * secure/storage.json 变成空或截断，丢失服务端地址与凭据配置。
 */
bool writeFileAtomic(const std::string &path, const std::string &content)
{
    const std::string tmpPath = path + ".tmp";
    {
        std::ofstream out(tmpPath, std::ios::trunc);
        if (!out.is_open()) {
            return false;
        }
        out << content;
        out.flush();
        if (!out.good()) {
            out.close();
            std::remove(tmpPath.c_str());
            return false;
        }
    }
    if (std::rename(tmpPath.c_str(), path.c_str()) != 0) {
        std::remove(tmpPath.c_str());
        return false;
    }
    return true;
}

bool saveObjectToFile(const std::string &path, cJSON *object)
{
    if (object == nullptr) {
        return false;
    }
    char *printed = cJSON_PrintUnformatted(object);
    if (printed == nullptr) {
        return false;
    }
    const std::string content = printed;
    cJSON_free(printed);
    return writeFileAtomic(path, content);
}

std::string readStringField(cJSON *object, const std::string &key, const std::string &defaultValue)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(object, key.c_str());
    if (item == nullptr || !cJSON_IsString(item) || item->valuestring == nullptr) {
        return defaultValue;
    }
    return item->valuestring;
}

bool writeStringField(cJSON *object, const std::string &key, const std::string &value)
{
    cJSON *existing = cJSON_GetObjectItemCaseSensitive(object, key.c_str());
    if (existing != nullptr) {
        cJSON_ReplaceItemInObject(object, key.c_str(), cJSON_CreateString(value.c_str()));
        return true;
    }
    return cJSON_AddStringToObject(object, key.c_str(), value.c_str()) != nullptr;
}

} // namespace

JsonStore::JsonStore(std::string rootDir) : rootDir_(std::move(rootDir)), identityDir_(rootDir_)
{
    makeDirs(rootDir_);
    // secure 目录保存登录凭据等敏感数据，仅限应用自身访问
    makeDirs(rootDir_ + "/secure", 0700);
}

JsonStore::~JsonStore()
{
    std::lock_guard<std::mutex> lock(prefMutex_);
    if (prefObject_ != nullptr) {
        cJSON_Delete(prefObject_);
        prefObject_ = nullptr;
    }
}

void JsonStore::setIdentityDir(const std::string &dir)
{
    // 空目录回退全局根，保证单账号场景行为不变
    identityDir_ = dir.empty() ? rootDir_ : dir;
    // 账号身份根是多层目录（accounts/<id>），必须递归创建：
    // 单层 mkdir 会因父目录不存在而失败，导致凭据/下载记录/历史/书签全部静默无法读写
    makeDirs(identityDir_);
    // secure 目录保存登录凭据等敏感数据，仅限应用自身访问
    makeDirs(identityDir_ + "/secure", 0700);
}

std::string JsonStore::pathFor(const std::string &name) const
{
    return identityDir_ + "/" + name + ".json";
}

std::string JsonStore::prefPath() const
{
    return rootDir_ + "/preferences.json";
}

std::string JsonStore::securePath() const
{
    return identityDir_ + "/secure/storage.json";
}

std::string JsonStore::globalSecurePath() const
{
    return rootDir_ + "/secure/storage.json";
}

std::string JsonStore::read(const std::string &name, const std::string &defaultValue) const
{
    std::ifstream in(pathFor(name));
    if (!in.is_open()) {
        return defaultValue;
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    const std::string data = ss.str();
    return data.empty() ? defaultValue : data;
}

bool JsonStore::write(const std::string &name, const std::string &json) const
{
    return writeFileAtomic(pathFor(name), json);
}

void JsonStore::ensurePrefLocked() const
{
    if (prefLoaded_ && prefObject_ != nullptr) {
        return;
    }
    if (prefObject_ != nullptr) {
        cJSON_Delete(prefObject_);
    }
    prefObject_ = loadObjectFromFile(prefPath());
    prefLoaded_ = true;
}

bool JsonStore::commitPrefLocked(cJSON *updated) const
{
    if (updated == nullptr) {
        return false;
    }
    if (!saveObjectToFile(prefPath(), updated)) {
        cJSON_Delete(updated);
        return false;
    }
    if (prefObject_ != nullptr) {
        cJSON_Delete(prefObject_);
    }
    prefObject_ = updated;
    prefLoaded_ = true;
    return true;
}

std::string JsonStore::readPref(const std::string &key, const std::string &defaultValue) const
{
    std::lock_guard<std::mutex> lock(prefMutex_);
    ensurePrefLocked();
    return readStringField(prefObject_, key, defaultValue);
}

bool JsonStore::writePref(const std::string &key, const std::string &value) const
{
    std::lock_guard<std::mutex> lock(prefMutex_);
    ensurePrefLocked();
    const cJSON *existing = cJSON_GetObjectItemCaseSensitive(prefObject_, key.c_str());
    if (existing != nullptr && cJSON_IsString(existing) && existing->valuestring != nullptr &&
        value == existing->valuestring) {
        return true;
    }
    cJSON *updated = cJSON_Duplicate(prefObject_, true);
    if (updated == nullptr || !writeStringField(updated, key, value)) {
        cJSON_Delete(updated);
        return false;
    }
    return commitPrefLocked(updated);
}

bool JsonStore::writePrefsBatch(const std::string &jsonObject) const
{
    cJSON *incoming = cJSON_Parse(jsonObject.c_str());
    if (incoming == nullptr || !cJSON_IsObject(incoming)) {
        if (incoming != nullptr) {
            cJSON_Delete(incoming);
        }
        return false;
    }
    std::lock_guard<std::mutex> lock(prefMutex_);
    ensurePrefLocked();
    cJSON *updated = cJSON_Duplicate(prefObject_, true);
    if (updated == nullptr) {
        cJSON_Delete(incoming);
        return false;
    }
    bool changed = false;
    const cJSON *child = nullptr;
    cJSON_ArrayForEach(child, incoming)
    {
        if (child->string == nullptr || !cJSON_IsString(child) || child->valuestring == nullptr) {
            continue;
        }
        const cJSON *existing = cJSON_GetObjectItemCaseSensitive(prefObject_, child->string);
        if (existing != nullptr && cJSON_IsString(existing) && existing->valuestring != nullptr &&
            std::string(existing->valuestring) == child->valuestring) {
            continue;
        }
        if (!writeStringField(updated, child->string, child->valuestring)) {
            cJSON_Delete(updated);
            cJSON_Delete(incoming);
            return false;
        }
        changed = true;
    }
    cJSON_Delete(incoming);
    if (!changed) {
        cJSON_Delete(updated);
        return true;
    }
    return commitPrefLocked(updated);
}

std::string JsonStore::readSecure(const std::string &key, const std::string &defaultValue) const
{
    cJSON *object = loadObjectFromFile(securePath());
    const std::string value = readStringField(object, key, defaultValue);
    cJSON_Delete(object);
    return value;
}

std::string JsonStore::readSecureGlobal(const std::string &key, const std::string &defaultValue) const
{
    cJSON *object = loadObjectFromFile(globalSecurePath());
    const std::string value = readStringField(object, key, defaultValue);
    cJSON_Delete(object);
    return value;
}

bool JsonStore::writeSecureGlobal(const std::string &key, const std::string &value) const
{
    cJSON *object = loadObjectFromFile(globalSecurePath());
    const bool ok = writeStringField(object, key, value);
    const bool saved = ok && saveObjectToFile(globalSecurePath(), object);
    cJSON_Delete(object);
    return saved;
}

bool JsonStore::writeSecure(const std::string &key, const std::string &value) const
{
    cJSON *object = loadObjectFromFile(securePath());
    const bool ok = writeStringField(object, key, value);
    const bool saved = ok && saveObjectToFile(securePath(), object);
    cJSON_Delete(object);
    return saved;
}

} // namespace talebook
