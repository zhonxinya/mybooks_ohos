#include "json_store.h"

#include "third_party/cjson/cJSON.h"

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

bool saveObjectToFile(const std::string &path, cJSON *object)
{
    if (object == nullptr) {
        return false;
    }
    char *printed = cJSON_PrintUnformatted(object);
    if (printed == nullptr) {
        return false;
    }
    std::ofstream out(path, std::ios::trunc);
    if (!out.is_open()) {
        cJSON_free(printed);
        return false;
    }
    out << printed;
    cJSON_free(printed);
    return true;
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

JsonStore::JsonStore(std::string rootDir) : rootDir_(std::move(rootDir))
{
    mkdir(rootDir_.c_str(), 0755);
    mkdir((rootDir_ + "/secure").c_str(), 0755);
}

std::string JsonStore::pathFor(const std::string &name) const
{
    return rootDir_ + "/" + name + ".json";
}

std::string JsonStore::prefPath() const
{
    return rootDir_ + "/preferences.json";
}

std::string JsonStore::securePath() const
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
    std::ofstream out(pathFor(name), std::ios::trunc);
    if (!out.is_open()) {
        return false;
    }
    out << json;
    return true;
}

std::string JsonStore::readPref(const std::string &key, const std::string &defaultValue) const
{
    cJSON *object = loadObjectFromFile(prefPath());
    const std::string value = readStringField(object, key, defaultValue);
    cJSON_Delete(object);
    return value;
}

bool JsonStore::writePref(const std::string &key, const std::string &value) const
{
    cJSON *object = loadObjectFromFile(prefPath());
    const bool ok = writeStringField(object, key, value);
    const bool saved = ok && saveObjectToFile(prefPath(), object);
    cJSON_Delete(object);
    return saved;
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
    cJSON *object = loadObjectFromFile(prefPath());
    const cJSON *child = nullptr;
    cJSON_ArrayForEach(child, incoming)
    {
        if (child->string == nullptr || !cJSON_IsString(child) || child->valuestring == nullptr) {
            continue;
        }
        writeStringField(object, child->string, child->valuestring);
    }
    const bool saved = saveObjectToFile(prefPath(), object);
    cJSON_Delete(object);
    cJSON_Delete(incoming);
    return saved;
}

std::string JsonStore::readSecure(const std::string &key, const std::string &defaultValue) const
{
    cJSON *object = loadObjectFromFile(securePath());
    const std::string value = readStringField(object, key, defaultValue);
    cJSON_Delete(object);
    return value;
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
