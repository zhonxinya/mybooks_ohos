#include "sonovel_api.h"

#include "third_party/cjson/cJSON.h"

#include <cctype>
#include <iomanip>
#include <sstream>

namespace talebook {
namespace {

std::string urlEncodeFormValue(const std::string &value)
{
    std::ostringstream ss;
    for (const unsigned char ch : value) {
        if (std::isalnum(ch) || ch == '-' || ch == '_' || ch == '.' || ch == '~') {
            ss << static_cast<char>(ch);
        } else if (ch == ' ') {
            ss << '+';
        } else {
            ss << '%' << std::uppercase << std::hex << std::setw(2) << std::setfill('0')
               << static_cast<int>(ch) << std::nouppercase << std::dec;
        }
    }
    return ss.str();
}

std::string jsonStringField(cJSON *json, const char *key)
{
    const cJSON *item = cJSON_GetObjectItemCaseSensitive(json, key);
    if (cJSON_IsString(item) && item->valuestring != nullptr) {
        return item->valuestring;
    }
    return "";
}

void appendQueryParam(std::ostringstream &query, const std::string &key, const std::string &value)
{
    if (value.empty()) {
        return;
    }
    if (!query.str().empty()) {
        query << '&';
    }
    query << key << '=' << urlEncodeFormValue(value);
}

} // namespace

SoNovelApi::SoNovelApi(HttpClient &http, JsonStore &store)
    : http_(http), store_(store), helper_(http, store)
{}

void SoNovelApi::ensureBaseUrl() const
{
    const std::string url = store_.readSecure("sonovel_url", "");
    if (!url.empty()) {
        const_cast<HttpClient &>(http_).setBaseUrl("sonovel", url);
    }
}

std::string SoNovelApi::searchAggregated(const std::string &keyword) const
{
    ensureBaseUrl();
    return helper_.wrapResponse(http_.get("sonovel", "/search/aggregated",
                                          "kw=" + urlEncodeFormValue(keyword), 30, 120));
}

std::string SoNovelApi::fetchBook(const std::string &paramsJson, const std::string &destPath) const
{
    ensureBaseUrl();
    cJSON *json = cJSON_Parse(paramsJson.c_str());
    if (json == nullptr) {
        return helper_.wrapResponse({0, "", "参数无效"});
    }

    const cJSON *sourceIdItem = cJSON_GetObjectItemCaseSensitive(json, "sourceId");
    const int sourceId = cJSON_IsNumber(sourceIdItem) ? sourceIdItem->valueint : 0;
    const std::string sourceName = jsonStringField(json, "sourceName");
    const std::string url = jsonStringField(json, "url");
    const std::string bookName = jsonStringField(json, "bookName");
    const std::string author = jsonStringField(json, "author");
    const std::string format = jsonStringField(json, "format");
    const std::string language = jsonStringField(json, "language");

    if (sourceId <= 0 || sourceName.empty() || url.empty() || bookName.empty() || author.empty()) {
        cJSON_Delete(json);
        return helper_.wrapResponse({0, "", "缺少必要参数"});
    }

    std::ostringstream query;
    query << "sourceId=" << sourceId;
    appendQueryParam(query, "sourceName", sourceName);
    appendQueryParam(query, "url", url);
    appendQueryParam(query, "bookName", bookName);
    appendQueryParam(query, "author", author);
    appendQueryParam(query, "category", jsonStringField(json, "category"));
    appendQueryParam(query, "latestChapter", jsonStringField(json, "latestChapter"));
    appendQueryParam(query, "lastUpdateTime", jsonStringField(json, "lastUpdateTime"));
    appendQueryParam(query, "status", jsonStringField(json, "status"));
    appendQueryParam(query, "format", format.empty() ? "epub" : format);
    appendQueryParam(query, "language", language.empty() ? "zh-CN" : language);
    cJSON_Delete(json);

    return helper_.wrapResponse(http_.downloadToFile("sonovel", "/book-fetch", destPath, query.str()));
}

} // namespace talebook
