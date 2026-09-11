#pragma once

#include "http_client.h"
#include "json_store.h"
#include "talebook_api.h"

#include <string>

namespace talebook {

class SoNovelApi {
public:
    SoNovelApi(HttpClient &http, JsonStore &store);

    std::string searchAggregated(const std::string &keyword) const;
    std::string fetchBook(const std::string &paramsJson, const std::string &destPath) const;

private:
    HttpClient &http_;
    JsonStore &store_;
    TalebookApi helper_;
    void ensureBaseUrl() const;
};

} // namespace talebook
