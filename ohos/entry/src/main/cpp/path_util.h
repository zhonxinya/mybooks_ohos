#ifndef TALEBOOK_PATH_UTIL_H
#define TALEBOOK_PATH_UTIL_H

#include <cerrno>
#include <string>
#include <sys/stat.h>

namespace talebook {

/**
 * 递归创建目录，最后一层使用 finalMode。
 *
 * mkdir(2) 只能创建单层目录：账号身份根形如 `<filesDir>/accounts/<id>`，
 * 其父目录 `accounts` 不存在时会以 ENOENT 失败，于是凭据、Cookie、数据库
 * 全部静默无法落盘（表现为新增账号后必须手动登录、重启后配置丢失）。
 * 中间层统一 0755；末层保留调用方要求的权限（`secure` / `.cookies` 为 0700）。
 */
inline bool makeDirs(const std::string &path, mode_t finalMode = 0755)
{
    if (path.empty()) {
        return false;
    }
    for (size_t i = 1; i < path.size(); ++i) {
        if (path[i] != '/') {
            continue;
        }
        const std::string parent = path.substr(0, i);
        if (mkdir(parent.c_str(), 0755) != 0 && errno != EEXIST) {
            return false;
        }
    }
    return mkdir(path.c_str(), finalMode) == 0 || errno == EEXIST;
}

} // namespace talebook

#endif // TALEBOOK_PATH_UTIL_H
