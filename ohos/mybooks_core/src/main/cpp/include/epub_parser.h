#pragma once

#include <string>

namespace mybooks {

struct EpubMetadata {
    bool valid = false;
    std::string title;
    std::string creator;
    std::string language;
    std::string identifier;
    std::string error;
};

/** Lightweight EPUB container/metadata extractor (ZIP + miniz inflate + OPF string parse). */
class EpubParser {
public:
    static EpubMetadata parseFile(const std::string &epubPath);
    static bool isValidEpub(const std::string &epubPath);
};

} // namespace mybooks
