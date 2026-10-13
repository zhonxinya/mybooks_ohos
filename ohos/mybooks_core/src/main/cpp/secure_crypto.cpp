#include "secure_crypto.h"

#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <sys/types.h>

#include <mbedtls/gcm.h>
#include <mbedtls/md.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/platform_util.h>

namespace mybooks {
namespace {

/** AES-GCM 参数（标准取值，见 NIST SP 800-38D）。 */
constexpr size_t kIvLen = 12;
constexpr size_t kTagLen = 16;
constexpr size_t kKeyLen = 32;   // AES-256

/** 密钥文件权限：仅属主可读写。 */
constexpr mode_t kKeyFileMode = 0600;

std::string KeyPath(const std::string &identityDir) {
    if (identityDir.empty()) return std::string();
    return identityDir + "/.secure_master.key";
}

/**
 * 读取或生成设备主密钥。
 *
 * 密钥为 32 字节随机值，存放在身份根目录下的 `.secure_master.key`（0600）。
 * 与 Android Keystore 的差异：这里密钥是**文件**，保护依赖文件系统权限与
 * 应用沙箱隔离（Android 上应用私有目录其它应用不可读）。
 * 若文件损坏或长度非法，重新生成（旧密文将无法解密，由调用方决定如何处理）。
 */
bool LoadOrCreateKey(const std::string &identityDir, std::vector<unsigned char> &key) {
    const std::string path = KeyPath(identityDir);
    if (path.empty()) return false;

    FILE *fp = std::fopen(path.c_str(), "rb");
    if (fp != nullptr) {
        unsigned char buf[kKeyLen];
        size_t n = std::fread(buf, 1, kKeyLen, fp);
        std::fclose(fp);
        if (n == kKeyLen) {
            key.assign(buf, buf + kKeyLen);
            return true;
        }
        // 长度不对：视为损坏，重建
    }

    // 生成新密钥（mbedtls CTR_DRBG + 熵源）
    mbedtls_entropy_context entropy;
    mbedtls_ctr_drbg_context drbg;
    mbedtls_entropy_init(&entropy);
    mbedtls_ctr_drbg_init(&drbg);
    bool ok = false;
    if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                              reinterpret_cast<const unsigned char *>("mybooks-secure"), 17) == 0) {
        key.resize(kKeyLen);
        ok = mbedtls_ctr_drbg_random(&drbg, key.data(), kKeyLen) == 0;
    }
    mbedtls_ctr_drbg_free(&drbg);
    mbedtls_entropy_free(&entropy);
    if (!ok) return false;

    // 落盘（先写临时文件再 rename，避免半截文件）
    const std::string tmp = path + ".tmp";
    FILE *out = std::fopen(tmp.c_str(), "wb");
    if (out == nullptr) return false;
    size_t written = std::fwrite(key.data(), 1, kKeyLen, out);
    std::fclose(out);
    if (written != kKeyLen) {
        std::remove(tmp.c_str());
        return false;
    }
    if (std::rename(tmp.c_str(), path.c_str()) != 0) {
        std::remove(tmp.c_str());
        return false;
    }
    chmod(path.c_str(), kKeyFileMode);
    return true;
}

std::vector<unsigned char> FromHex(const std::string &hex) {
    std::vector<unsigned char> out;
    if (hex.size() % 2 != 0) return out;
    out.reserve(hex.size() / 2);
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    };
    for (size_t i = 0; i < hex.size(); i += 2) {
        int hi = nibble(hex[i]);
        int lo = nibble(hex[i + 1]);
        if (hi < 0 || lo < 0) return std::vector<unsigned char>();
        out.push_back(static_cast<unsigned char>((hi << 4) | lo));
    }
    return out;
}

std::string ToHex(const unsigned char *data, size_t len) {
    static const char *digits = "0123456789abcdef";
    std::string out;
    out.reserve(len * 2);
    for (size_t i = 0; i < len; ++i) {
        out.push_back(digits[(data[i] >> 4) & 0xF]);
        out.push_back(digits[data[i] & 0xF]);
    }
    return out;
}

} // namespace

bool SecureCrypto::seal(const std::string &identityDir, const std::string &plain,
                        std::string &outSealed) {
    std::vector<unsigned char> key;
    if (!LoadOrCreateKey(identityDir, key)) return false;

    unsigned char iv[kIvLen];
    {
        mbedtls_entropy_context entropy;
        mbedtls_ctr_drbg_context drbg;
        mbedtls_entropy_init(&entropy);
        mbedtls_ctr_drbg_init(&drbg);
        if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
                                  reinterpret_cast<const unsigned char *>("mybooks-iv"), 10) != 0 ||
            mbedtls_ctr_drbg_random(&drbg, iv, kIvLen) != 0) {
            mbedtls_ctr_drbg_free(&drbg);
            mbedtls_entropy_free(&entropy);
            return false;
        }
        mbedtls_ctr_drbg_free(&drbg);
        mbedtls_entropy_free(&entropy);
    }

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int rc = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key.data(), kKeyLen * 8);
    std::vector<unsigned char> cipher(plain.size());
    unsigned char tag[kTagLen];
    if (rc == 0) {
        rc = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, plain.size(), iv, kIvLen,
                                       nullptr, 0,
                                       reinterpret_cast<const unsigned char *>(plain.data()),
                                       cipher.data(), kTagLen, tag);
    }
    mbedtls_gcm_free(&gcm);
    if (rc != 0) return false;

    outSealed = ToHex(iv, kIvLen) + ToHex(cipher.data(), cipher.size()) + ToHex(tag, kTagLen);
    return true;
}

bool SecureCrypto::open(const std::string &identityDir, const std::string &sealed,
                        std::string &outPlain) {
    if (sealed.size() < (kIvLen + kTagLen) * 2) return false;

    std::vector<unsigned char> key;
    if (!LoadOrCreateKey(identityDir, key)) return false;

    const std::vector<unsigned char> iv = FromHex(sealed.substr(0, kIvLen * 2));
    if (iv.size() != kIvLen) return false;
    const std::vector<unsigned char> blob = FromHex(sealed.substr(kIvLen * 2));
    if (blob.size() < kTagLen) return false;

    const size_t bodyLen = blob.size() - kTagLen;
    // 尾部 16 字节是 authTag，其余是密文本体
    const unsigned char *tagPtr = blob.data() + bodyLen;

    mbedtls_gcm_context gcm;
    mbedtls_gcm_init(&gcm);
    int rc = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key.data(), kKeyLen * 8);
    std::vector<unsigned char> plain(bodyLen);
    if (rc == 0) {
        // mbedTLS 2.x 签名：(ctx, length, iv, iv_len, add, add_len, tag, tag_len, input, output)
        rc = mbedtls_gcm_auth_decrypt(&gcm, bodyLen, iv.data(), kIvLen, nullptr, 0,
                                      tagPtr, kTagLen, blob.data(), plain.data());
    }
    mbedtls_gcm_free(&gcm);
    // auth_decrypt 失败说明密文被篡改或密钥不匹配，绝不返回部分明文
    if (rc != 0) return false;

    outPlain.assign(reinterpret_cast<const char *>(plain.data()), bodyLen);
    return true;
}

} // namespace mybooks
