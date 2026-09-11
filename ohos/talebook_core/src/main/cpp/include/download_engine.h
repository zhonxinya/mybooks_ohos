#pragma once

#include <string>
#include <vector>
#include <functional>

namespace talebook {

struct DownloadResult {
    bool success = false;
    std::string filePath;
    std::string error;
};

class DownloadEngine {
public:
    static DownloadResult downloadFile(
        const std::string &downloadUrl,
        const std::string &fileName,
        const std::string &fileExtension,
        const std::string &filesDir,
        const std::string &baseUrl,
        std::function<void(double)> onProgress = nullptr);

    static std::string validateDownloadedFile(const std::string &filePath,
                                              const std::string &fileExtension);
    static std::vector<std::string> buildCandidateUrls(const std::string &downloadUrl,
                                                       const std::string &fileExtension);
};

} // namespace talebook
