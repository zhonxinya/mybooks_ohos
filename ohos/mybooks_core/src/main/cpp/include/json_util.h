#pragma once

#include <string>
#include <vector>
#include <map>
#include <optional>
#include <functional>
#include <cstdint>

namespace mybooks {

using JsonObject = std::map<std::string, std::string>;

std::string jsonEscape(const std::string &s);
std::string jsonStringify(const JsonObject &obj);
std::string jsonStringifyArray(const std::vector<std::string> &items);
std::optional<std::string> jsonGetString(const std::string &json, const std::string &key);
std::optional<int> jsonGetInt(const std::string &json, const std::string &key);
std::optional<double> jsonGetDouble(const std::string &json, const std::string &key);
std::optional<bool> jsonGetBool(const std::string &json, const std::string &key);
std::vector<std::string> jsonParseArray(const std::string &json);
JsonObject jsonParseObject(const std::string &json);

} // namespace mybooks
