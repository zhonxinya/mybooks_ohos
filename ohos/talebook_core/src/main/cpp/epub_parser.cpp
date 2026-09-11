#include "epub_parser.h"

#include <fstream>
#include <sstream>
#include <vector>
#include <cstring>
#include <cstdint>
#include <algorithm>
#include <cstdlib>

#include "miniz.h"
#include "miniz_tinfl.h"

namespace talebook {

namespace {

#pragma pack(push, 1)
struct LocalFileHeader {
    uint32_t signature;
    uint16_t version;
    uint16_t flags;
    uint16_t method;
    uint16_t modTime;
    uint16_t modDate;
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t nameLen;
    uint16_t extraLen;
};
struct CentralDirHeader {
    uint32_t signature;
    uint16_t versionMade;
    uint16_t versionNeeded;
    uint16_t flags;
    uint16_t method;
    uint16_t modTime;
    uint16_t modDate;
    uint32_t crc32;
    uint32_t compressedSize;
    uint32_t uncompressedSize;
    uint16_t nameLen;
    uint16_t extraLen;
    uint16_t commentLen;
    uint16_t diskStart;
    uint16_t intAttr;
    uint32_t extAttr;
    uint32_t localHeaderOffset;
};
struct EndOfCentralDir {
    uint32_t signature;
    uint16_t diskNum;
    uint16_t startDisk;
    uint16_t diskEntries;
    uint16_t totalEntries;
    uint32_t centralDirSize;
    uint32_t centralDirOffset;
    uint16_t commentLen;
};
#pragma pack(pop)

std::vector<uint8_t> readFileBytes(const std::string &path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) return {};
    ifs.seekg(0, std::ios::end);
    const auto size = static_cast<size_t>(ifs.tellg());
    ifs.seekg(0, std::ios::beg);
    std::vector<uint8_t> data(size);
    ifs.read(reinterpret_cast<char *>(data.data()), static_cast<std::streamsize>(size));
    return data;
}

bool findEocd(const std::vector<uint8_t> &data, EndOfCentralDir &eocd, size_t &eocdPos) {
    if (data.size() < sizeof(EndOfCentralDir)) return false;
    const size_t maxBack = std::min<size_t>(data.size(), 65557);
    for (size_t i = data.size() - sizeof(EndOfCentralDir); i + 1 > data.size() - maxBack; --i) {
        uint32_t sig = 0;
        std::memcpy(&sig, data.data() + i, 4);
        if (sig == 0x06054b50) {
            std::memcpy(&eocd, data.data() + i, sizeof(EndOfCentralDir));
            eocdPos = i;
            return true;
        }
        if (i == 0) break;
    }
    return false;
}

/** Inflate raw deflate (ZIP method 8) using miniz tinfl. */
std::string inflateRaw(const uint8_t *src, size_t srcLen, size_t expectedUncompressed) {
    size_t outLen = 0;
    void *out = tinfl_decompress_mem_to_heap(
        src, srcLen, &outLen,
        TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
    if (!out) return "";
    if (expectedUncompressed > 0 && outLen != expectedUncompressed && outLen == 0) {
        std::free(out);
        return "";
    }
    std::string result(static_cast<char *>(out), outLen);
    std::free(out);
    return result;
}

std::string extractEntry(const std::vector<uint8_t> &data, const std::string &entryName) {
    EndOfCentralDir eocd {};
    size_t eocdPos = 0;
    if (!findEocd(data, eocd, eocdPos)) return "";

    size_t offset = eocd.centralDirOffset;
    for (uint16_t i = 0; i < eocd.totalEntries; ++i) {
        if (offset + sizeof(CentralDirHeader) > data.size()) break;
        CentralDirHeader cdh {};
        std::memcpy(&cdh, data.data() + offset, sizeof(CentralDirHeader));
        if (cdh.signature != 0x02014b50) break;
        offset += sizeof(CentralDirHeader);
        if (offset + cdh.nameLen > data.size()) break;
        std::string name(reinterpret_cast<const char *>(data.data() + offset), cdh.nameLen);
        offset += cdh.nameLen + cdh.extraLen + cdh.commentLen;
        if (name != entryName) continue;

        size_t local = cdh.localHeaderOffset;
        if (local + sizeof(LocalFileHeader) > data.size()) return "";
        LocalFileHeader lfh {};
        std::memcpy(&lfh, data.data() + local, sizeof(LocalFileHeader));
        if (lfh.signature != 0x04034b50) return "";

        size_t dataStart = local + sizeof(LocalFileHeader) + lfh.nameLen + lfh.extraLen;
        uint32_t compSize = lfh.compressedSize ? lfh.compressedSize : cdh.compressedSize;
        uint32_t uncompSize = lfh.uncompressedSize ? lfh.uncompressedSize : cdh.uncompressedSize;
        uint16_t method = lfh.method;

        // Data descriptor: sizes may be zero in local header when bit 3 is set
        if ((lfh.flags & 0x8) != 0) {
            compSize = cdh.compressedSize;
            uncompSize = cdh.uncompressedSize;
        }

        if (dataStart + compSize > data.size()) return "";

        if (method == 0) {
            return std::string(reinterpret_cast<const char *>(data.data() + dataStart), uncompSize);
        }
        if (method == 8) {
            return inflateRaw(data.data() + dataStart, compSize, uncompSize);
        }
        return "";
    }
    return "";
}

bool hasEntry(const std::vector<uint8_t> &data, const std::string &entryName) {
    EndOfCentralDir eocd {};
    size_t eocdPos = 0;
    if (!findEocd(data, eocd, eocdPos)) return false;
    size_t offset = eocd.centralDirOffset;
    for (uint16_t i = 0; i < eocd.totalEntries; ++i) {
        if (offset + sizeof(CentralDirHeader) > data.size()) break;
        CentralDirHeader cdh {};
        std::memcpy(&cdh, data.data() + offset, sizeof(CentralDirHeader));
        if (cdh.signature != 0x02014b50) break;
        offset += sizeof(CentralDirHeader);
        if (offset + cdh.nameLen > data.size()) break;
        std::string name(reinterpret_cast<const char *>(data.data() + offset), cdh.nameLen);
        offset += cdh.nameLen + cdh.extraLen + cdh.commentLen;
        if (name == entryName) return true;
    }
    return false;
}

std::string extractTag(const std::string &xml, const std::string &localName) {
    const std::vector<std::string> opens = {
        "<" + localName + ">",
        "<dc:" + localName + ">",
        "<dc:" + localName + " ",
    };
    for (const auto &open : opens) {
        size_t start = xml.find(open);
        if (start == std::string::npos) continue;
        start = xml.find('>', start);
        if (start == std::string::npos) continue;
        ++start;
        size_t end = xml.find("</" + localName + ">", start);
        if (end == std::string::npos) end = xml.find("</dc:" + localName + ">", start);
        if (end == std::string::npos) continue;
        return xml.substr(start, end - start);
    }
    return "";
}

} // namespace

bool EpubParser::isValidEpub(const std::string &epubPath) {
    auto data = readFileBytes(epubPath);
    if (data.size() < 4) return false;
    if (!(data[0] == 0x50 && data[1] == 0x4B)) return false;
    return hasEntry(data, "META-INF/container.xml") || hasEntry(data, "mimetype");
}

EpubMetadata EpubParser::parseFile(const std::string &epubPath) {
    EpubMetadata meta;
    auto data = readFileBytes(epubPath);
    if (data.empty()) {
        meta.error = "cannot read file";
        return meta;
    }
    if (!(data[0] == 0x50 && data[1] == 0x4B)) {
        meta.error = "not a zip/epub archive";
        return meta;
    }

    std::string container = extractEntry(data, "META-INF/container.xml");
    if (container.empty()) {
        if (hasEntry(data, "META-INF/container.xml")) {
            meta.error = "failed to decompress container.xml";
            return meta;
        }
        meta.error = "missing META-INF/container.xml";
        return meta;
    }

    std::string opfPath;
    size_t fp = container.find("full-path=\"");
    if (fp != std::string::npos) {
        fp += 11;
        size_t end = container.find('"', fp);
        if (end != std::string::npos) opfPath = container.substr(fp, end - fp);
    }
    if (opfPath.empty()) {
        meta.valid = true;
        meta.error = "opf path missing";
        return meta;
    }

    std::string opf = extractEntry(data, opfPath);
    if (opf.empty()) {
        meta.valid = true;
        meta.error = "opf missing or decompress failed";
        return meta;
    }

    meta.title = extractTag(opf, "title");
    meta.creator = extractTag(opf, "creator");
    meta.language = extractTag(opf, "language");
    meta.identifier = extractTag(opf, "identifier");
    meta.valid = true;
    return meta;
}

} // namespace talebook
