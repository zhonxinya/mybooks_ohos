#include "json_util.h"

#include <sstream>
#include <cctype>

namespace talebook {

static bool isWhitespace(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; }

std::string jsonEscape(const std::string &s) {
    std::ostringstream oss;
    for (char c : s) {
        switch (c) {
        case '"': oss << "\\\""; break;
        case '\\': oss << "\\\\"; break;
        case '\n': oss << "\\n"; break;
        case '\r': oss << "\\r"; break;
        case '\t': oss << "\\t"; break;
        default: oss << c; break;
        }
    }
    return oss.str();
}

std::string jsonStringify(const JsonObject &obj) {
    std::ostringstream oss;
    oss << '{';
    bool first = true;
    for (const auto &kv : obj) {
        if (!first) oss << ',';
        first = false;
        oss << '"' << jsonEscape(kv.first) << "\":\"" << jsonEscape(kv.second) << '"';
    }
    oss << '}';
    return oss.str();
}

std::string jsonStringifyArray(const std::vector<std::string> &items) {
    std::ostringstream oss;
    oss << '[';
    for (size_t i = 0; i < items.size(); ++i) {
        if (i > 0) oss << ',';
        oss << items[i];
    }
    oss << ']';
    return oss.str();
}

static size_t skipWs(const std::string &json, size_t pos) {
    while (pos < json.size() && isWhitespace(json[pos])) ++pos;
    return pos;
}

static std::optional<std::string> parseJsonStringValue(const std::string &json, size_t &pos) {
    pos = skipWs(json, pos);
    if (pos >= json.size() || json[pos] != '"') return std::nullopt;
    ++pos;
    std::ostringstream val;
    while (pos < json.size()) {
        char c = json[pos++];
        if (c == '"') return val.str();
        if (c == '\\' && pos < json.size()) {
            char esc = json[pos++];
            switch (esc) {
            case '"': val << '"'; break;
            case '\\': val << '\\'; break;
            case 'n': val << '\n'; break;
            case 'r': val << '\r'; break;
            case 't': val << '\t'; break;
            default: val << esc; break;
            }
        } else {
            val << c;
        }
    }
    return std::nullopt;
}

std::optional<std::string> jsonGetString(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    pos += needle.size();
    pos = skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ':') return std::nullopt;
    ++pos;
    pos = skipWs(json, pos);
    if (pos < json.size() && json[pos] == '"') return parseJsonStringValue(json, pos);
    return std::nullopt;
}

std::optional<int> jsonGetInt(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    pos += needle.size();
    pos = skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ':') return std::nullopt;
    ++pos;
    pos = skipWs(json, pos);
    size_t end = pos;
    while (end < json.size() && (std::isdigit(json[end]) || json[end] == '-')) ++end;
    if (end == pos) return std::nullopt;
    return std::stoi(json.substr(pos, end - pos));
}

std::optional<double> jsonGetDouble(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    pos += needle.size();
    pos = skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ':') return std::nullopt;
    ++pos;
    pos = skipWs(json, pos);
    size_t end = pos;
    while (end < json.size() &&
           (std::isdigit(json[end]) || json[end] == '-' || json[end] == '.')) ++end;
    if (end == pos) return std::nullopt;
    return std::stod(json.substr(pos, end - pos));
}

std::optional<bool> jsonGetBool(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    size_t pos = json.find(needle);
    if (pos == std::string::npos) return std::nullopt;
    pos += needle.size();
    pos = skipWs(json, pos);
    if (pos >= json.size() || json[pos] != ':') return std::nullopt;
    ++pos;
    pos = skipWs(json, pos);
    if (json.compare(pos, 4, "true") == 0) return true;
    if (json.compare(pos, 5, "false") == 0) return false;
    return std::nullopt;
}

std::vector<std::string> jsonParseArray(const std::string &json) {
    std::vector<std::string> result;
    size_t pos = skipWs(json, 0);
    if (pos >= json.size() || json[pos] != '[') return result;
    ++pos;
    while (pos < json.size()) {
        pos = skipWs(json, pos);
        if (pos < json.size() && json[pos] == ']') break;
        if (json[pos] == '{') {
            int depth = 0;
            size_t start = pos;
            do {
                if (json[pos] == '{') ++depth;
                else if (json[pos] == '}') --depth;
                ++pos;
            } while (pos < json.size() && depth > 0);
            result.push_back(json.substr(start, pos - start));
        } else if (json[pos] == '"') {
            auto val = parseJsonStringValue(json, pos);
            if (val) result.push_back("\"" + jsonEscape(*val) + "\"");
        } else {
            size_t start = pos;
            while (pos < json.size() && json[pos] != ',' && json[pos] != ']') ++pos;
            result.push_back(json.substr(start, pos - start));
        }
        pos = skipWs(json, pos);
        if (pos < json.size() && json[pos] == ',') ++pos;
    }
    return result;
}

JsonObject jsonParseObject(const std::string &json) {
    JsonObject obj;
    size_t pos = skipWs(json, 0);
    if (pos >= json.size() || json[pos] != '{') return obj;
    ++pos;
    while (pos < json.size()) {
        pos = skipWs(json, pos);
        if (pos < json.size() && json[pos] == '}') break;
        auto keyOpt = parseJsonStringValue(json, pos);
        if (!keyOpt) break;
        pos = skipWs(json, pos);
        if (pos >= json.size() || json[pos] != ':') break;
        ++pos;
        pos = skipWs(json, pos);
        if (pos < json.size() && json[pos] == '"') {
            auto val = parseJsonStringValue(json, pos);
            if (val) obj[*keyOpt] = *val;
        } else {
            size_t start = pos;
            while (pos < json.size() && json[pos] != ',' && json[pos] != '}') ++pos;
            obj[*keyOpt] = json.substr(start, pos - start);
        }
        pos = skipWs(json, pos);
        if (pos < json.size() && json[pos] == ',') ++pos;
    }
    return obj;
}

} // namespace talebook
