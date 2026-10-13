#ifndef MYBOOKS_SECURE_CRYPTO_H
#define MYBOOKS_SECURE_CRYPTO_H

#include <string>

namespace mybooks {

/**
 * 安全存储的加解密后端（AES-256-GCM）。
 *
 * ## 用途
 *
 * ArkUI-X 的 Android 端没有鸿蒙的 `@kit.AssetStoreKit`（关键资产存储服务），
 * 需要一个能力等价的加密落盘方案。密码类数据（账号密码、凭据）先经本类加密，
 * 再由 ArkTS 层写入 preferences，因此磁盘上不会出现明文密码。
 *
 * ## 密钥管理
 *
 * 主密钥为 32 字节随机值，存放在**身份根目录**下的 `.secure_master.key`
 * （权限 0600，先写临时文件再 rename 原子替换）。
 *
 * 与 Android Keystore 的差异需注意：Keystore 里密钥不可导出、由硬件保护；
 * 本实现依赖「应用私有目录 + 文件权限 + 应用沙箱隔离」保护密钥。
 * 若后续需要更强保护，可在此处改接 Android Keystore（经 JNI）而不影响调用方。
 *
 * ## 密文格式
 *
 * 十六进制字符串：`[12B IV][ciphertext][16B authTag]`，整体 hex 编码。
 * GCM 的 authTag 校验失败时 `open` 返回 false，**不返回部分明文**。
 *
 * 实现基于 mbedTLS 2.x 的 GCM API（`mbedtls_gcm_crypt_and_tag` /
 * `mbedtls_gcm_auth_decrypt`，两者均需显式的 `tag_len`）。
 */
class SecureCrypto {
public:
    /**
     * 加密。
     *
     * @param identityDir 身份根目录（密钥文件所在处），为空时直接失败
     * @param plain 明文（可含 \0，按长度处理）
     * @param outSealed 输出十六进制密文
     * @returns 成功返回 true；取不到密钥或加密失败返回 false
     */
    static bool seal(const std::string &identityDir, const std::string &plain, std::string &outSealed);

    /**
     * 解密。
     *
     * @param identityDir 身份根目录
     * @param sealed 十六进制密文
     * @param outPlain 输出明文（成功时必定被完整赋值）
     * @returns 成功返回 true；格式非法 / authTag 校验失败 / 密钥不匹配返回 false
     */
    static bool open(const std::string &identityDir, const std::string &sealed, std::string &outPlain);
};

} // namespace mybooks

#endif // MYBOOKS_SECURE_CRYPTO_H
