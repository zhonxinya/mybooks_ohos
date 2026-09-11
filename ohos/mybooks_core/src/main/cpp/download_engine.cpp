#include "download_engine.h"
#include "http_client.h"
#include "epub_parser.h"

#include <fstream>
#include <algorithm>
#include <cctype>
#include <sys/stat.h>

namespace mybooks {

static bool isHtmlHeader(const unsigned char *header, size_t len) {
    return len > 9 && header[0] == 0x3c && header[1] == 0x21 && header[2] == 0x64 &&
           header[3] == 0x6f && header[4] == 0x63 && header[5] == 0x74 && header[6] == 0x79 &&
           header[7] == 0x70 && header[8] == 0x65 && header[9] == 0x20;
}

std::string DownloadEngine::validateDownloadedFile(const std::string &filePath,
                                                   const std::string &fileExtension) {
    struct stat st {};
    if (stat(filePath.c_str(), &st) != 0 || st.st_size < 1024) {
        return "file too small or missing";
    }

    std::ifstream ifs(filePath, std::ios::binary);
    unsigned char header[100] = {};
    ifs.read(reinterpret_cast<char *>(header), sizeof(header));
    size_t readLen = static_cast<size_t>(ifs.gcount());
    if (readLen < 16) return "header read failed";

    std::string format = fileExtension;
    std::transform(format.begin(), format.end(), format.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    bool isHtml = isHtmlHeader(header, readLen);
    if (format == "epub") {
        if (!(header[0] == 0x50 && header[1] == 0x4B)) {
            return isHtml ? "html instead of epub" : "invalid epub header";
        }
        if (!EpubParser::isValidEpub(filePath)) {
            return "epub container invalid";
        }
    } else if (format == "mobi" || format == "azw" || format == "azw3") {
        std::string headStr(reinterpret_cast<char *>(header),
                            reinterpret_cast<char *>(header) + readLen);
        if (headStr.find("BOOKMOBI") == std::string::npos &&
            headStr.find("TEXtREAd") == std::string::npos) {
            return isHtml ? "html instead of mobi" : "invalid mobi header";
        }
    } else if (format == "txt" && isHtml) {
        return "html instead of txt";
    }
    return "";
}

/** 清洗书名/扩展名派生的文件名，避免路径分隔符导致目录穿越或覆盖意外文件。 */
static std::string sanitizeFileName(const std::string &name) {
    std::string out;
    out.reserve(name.size());
    for (char c : name) {
        const unsigned char uc = static_cast<unsigned char>(c);
        if (c == '/' || c == '\\' || c == ':' || uc < 0x20) {
            out.push_back('_');
        } else {
            out.push_back(c);
        }
    }
    return out.empty() ? "book" : out;
}

std::vector<std::string> DownloadEngine::buildCandidateUrls(const std::string &downloadUrl,
                                                              const std::string &fileExtension) {
    std::vector<std::string> candidates;
    candidates.push_back(downloadUrl);

    std::string lowerExt = fileExtension;
    std::transform(lowerExt.begin(), lowerExt.end(), lowerExt.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    size_t dotIndex = downloadUrl.rfind('.');
    if (dotIndex != std::string::npos && dotIndex > 0) {
        candidates.push_back(downloadUrl.substr(0, dotIndex) + "." + lowerExt);
    }

    size_t apiPos = downloadUrl.find("/api/book/");
    if (apiPos != std::string::npos) {
        size_t lastSlash = downloadUrl.rfind('/');
        if (lastSlash != std::string::npos && lastSlash + 1 < downloadUrl.size()) {
            std::string last = downloadUrl.substr(lastSlash + 1);
            size_t idDot = last.rfind('.');
            if (idDot != std::string::npos) {
                std::string bookId = last.substr(0, idDot);
                candidates.push_back("/api/book/" + bookId + "/download?format=" + lowerExt);
            }
        }
    }

    std::sort(candidates.begin(), candidates.end());
    candidates.erase(std::unique(candidates.begin(), candidates.end()), candidates.end());
    return candidates;
}

DownloadResult DownloadEngine::downloadFile(
    const std::string &downloadUrl, const std::string &fileName,
    const std::string &fileExtension, const std::string &filesDir, const std::string &baseUrl,
    std::function<void(double)> onProgress) {
    DownloadResult result;
    HttpClient::instance().setBaseUrl(baseUrl);

    const std::string safeName = sanitizeFileName(fileName);
    const std::string safeExt = sanitizeFileName(fileExtension);
    std::string savePath = filesDir + "/" + safeName + "." + safeExt;

    struct stat st {};
    if (stat(savePath.c_str(), &st) == 0) {
        if (validateDownloadedFile(savePath, fileExtension).empty()) {
            result.success = true;
            result.filePath = savePath;
            return result;
        }
    }

    auto urls = buildCandidateUrls(downloadUrl, fileExtension);
    std::string lastError;
    for (const auto &url : urls) {
        auto resp = HttpClient::instance().downloadToFile(url, savePath, onProgress);
        if (!resp.error.empty()) {
            lastError = resp.error;
            continue;
        }
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
            lastError = "HTTP " + std::to_string(resp.statusCode);
            continue;
        }
        std::string validation = validateDownloadedFile(savePath, fileExtension);
        if (validation.empty()) {
            result.success = true;
            result.filePath = savePath;
            return result;
        }
        lastError = validation;
    }

    result.error = lastError.empty() ? "download failed" : lastError;
    return result;
}

} // namespace mybooks
