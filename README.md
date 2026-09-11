# talebook

HarmonyOS 原生多源聚合阅读器（ArkTS UI + C++ 核心层），是 [MyBooks (Talebook)](https://github.com/PoxenStudio/mybooks/) 的鸿蒙客户端。

> 本项目仅提供服务端客户端，自身不包含、不提供任何电子书内容。

## 架构

- **ArkTS**：页面、导航、Reader Kit 阅读器 UI
- **C++ NAPI**（`ohos/entry/src/main/cpp/`）：HTTP、Cookie、持久化、Talebook/SoNovel API
- **Reader Kit**：EPUB / TXT / MOBI / AZW / AZW3 原生阅读

## 关联项目

本客户端需配合自建的服务端使用，仓库本身不含任何服务端代码。

| 项目 | 说明 | 与本项目的关系 |
|---|---|---|
| [PoxenStudio/mybooks](https://github.com/PoxenStudio/mybooks/) | 📚 MyBooks：简单好用的个人图书管理系统（原 PoxenStudio/Talebook），基于 Calibre + Vue，BSD-2-Clause | **书库服务端**，提供书架、阅读进度、下载等能力 |
| [freeok/so-novel](https://github.com/freeok/so-novel) | SoNovel：通用的网页内容处理与导出工具，可导出 EPUB / TXT / PDF，AGPL-3.0 | **聚合搜索服务端**，提供 `search/aggregated` 与 `book-fetch` 接口 |
| [talebook/talebook](https://github.com/talebook/talebook) | MyBooks 的上游项目 | 上游 |

两个服务均**独立部署、通过 HTTP 调用**，本项目不含其代码，也不内置任何书源或内容。

### MyBooks 服务端

1. 部署并启动 MyBooks，参见其[项目首页](https://github.com/PoxenStudio/mybooks/)与[使用指南](https://github.com/PoxenStudio/mybooks/blob/develop/document/UserGuide.zh_CN.md)
2. 在本应用「设置 → 附加服务」填入服务地址
3. 登录 Talebook 账号

### SoNovel 服务端（可选）

用于「聚合搜索」功能。以 Docker 为例（默认端口 `7765`）：

```yaml
services:
  sonovel:
    image: ghcr.io/freeok/sonovel:latest
    container_name: sonovel
    ports:
      - "7765:7765"
    environment:
      JAVA_OPTS: "-Dmode=web"
    volumes:
      - sonovel_data:/sonovel
    restart: unless-stopped

volumes:
  sonovel_data:
```

部署完成后，在本应用「设置 → 附加服务」填入其地址（如 `http://<ip>:7765`）。
更多部署方式（Windows / Linux / Homebrew / Scoop / 源码构建）见 [so-novel 文档](https://github.com/freeok/so-novel)。

> SoNovel 为可选功能。未配置服务地址时，聚合搜索页会提示「请先配置 SoNovel 服务地址」并提供跳转入口，此时不会发起任何请求；不影响 MyBooks 书库功能。

## 构建

```powershell
# 完整构建（含清理）
.\scripts\build.ps1

# 增量快速构建
.\scripts\quick-build.ps1

# 构建并安装到真机
.\scripts\build-and-install.ps1 -Launch
```

等价 hvigor 命令（在 `ohos/` 目录下）：

```powershell
..\scripts\hvigorw.ps1 assembleHap -p product=default -p buildMode=debug --no-daemon
```

构建产物：`ohos/entry/build/default/outputs/default/` 下的 `entry-default-*.hap`

依赖：需存在 `ohos/entry/libs/arm64-v8a/libcurl.so`（见 `third_party/README.md`），
且首次构建前需在 `ohos/` 目录执行 `ohpm install --all` 生成 `oh_modules`。

或在 DevEco Studio 中打开 `ohos/` 目录构建。

> `ohos/build-profile.json5` 为本地工程配置（已被 `.gitignore` 排除）。若缺失，hvigor 会报
> `0304035 Not Found`，可参照 `ohos/build-profile.ci.json5` 重建。

## 签名

本仓库**不含任何签名证书与密钥**，默认构建产出未签名 HAP（`entry-default-unsigned.hap`），仅可用于编译校验。

需要安装到真机时，配置自动签名：

1. DevEco Studio 打开 `ohos/` 目录
2. `File → Project Structure → Signing Configs`，勾选 `Automatically generate signature`
3. 重新构建，产物为 `entry-default-signed.hap`，可用 `.\scripts\install.ps1` 安装

签名材料由 DevEco 写入 `ohos/build-profile.json5`（该文件已被 `.gitignore` 排除，不会误提交）。
模板见根目录 `build-profile.json5.template` 与 `local.properties.template`。

## 配置

1. 设置 → 附加服务 → 配置 Talebook / SoNovel 服务器地址
2. 设置 → 登录 Talebook 账号
3. 书架页查看本地下载书籍，点击阅读打开 Reader Kit

## 目录

```
ohos/entry/src/main/
├── cpp/           # C++ NAPI 核心
├── ets/pages/     # ArkTS 页面
├── ets/services/  # TalebookService / ReadKitSession
└── ets/components/
```

## 法律声明与免责声明

**请在使用前完整阅读以下内容。下载、编译、安装或使用本项目，即视为已知悉并同意本声明。**

### 一、项目性质

1. 本项目是 [MyBooks (Talebook)](https://github.com/PoxenStudio/mybooks/) 的**客户端**，仅提供界面与访问能力，**不包含任何电子书、书源或内容数据**。
2. 本项目**没有也不会维护、运营任何公开的书籍网站或在线书库**，与任何第三方内容提供站点无关联、无合作关系。
3. 本项目需连接**使用者自行部署、自行拥有合法授权**的 MyBooks / Talebook 服务端方可使用。服务端的部署、内容来源与合规性由使用者自行负责。
4. [SoNovel (so-novel)](https://github.com/freeok/so-novel) 为独立第三方项目（AGPL-3.0），本项目仅通过 HTTP 调用其接口，未包含、未修改其任何代码。其书源规则、内容来源与合规性由该项目的使用者自行负责。
5. 聚合搜索功能仅提供技术接口调用能力，**不内置任何书源地址、不预置任何服务端**，相关地址由使用者自行配置。
6. 未配置服务地址时，本应用**不会向该服务发起任何请求**（对应功能页会提示前往配置），且不内置任何默认地址。

### 二、使用限制

1. 本项目**仅供个人学习、研究与合法自有藏书管理使用**，不适用于站点搭建或对外提供公开服务。
2. **严禁**将本项目用于任何侵犯著作权的行为，包括但不限于：传播盗版电子书、搭建公开的侵权书库、规避技术保护措施。
3. **严禁**将本项目用于违反所在地法律法规的任何用途。
4. 中国境内，个人不得进行在线出版活动，**维护公开的书籍网站属违法违规行为**。请务必仅作个人使用。
5. 使用者应确保对所访问、存储、传播的内容拥有合法权利，并自行承担由此产生的全部法律责任。

### 三、免责条款

1. 本项目按**"原样"（AS IS）**提供，不附带任何明示或暗示的担保，包括但不限于对适销性、特定用途适用性及不侵权的担保。
2. 作者及贡献者**不对**因使用或无法使用本项目所导致的任何直接、间接、偶然、特殊或后果性损害承担责任，包括但不限于数据丢失、设备损坏、法律纠纷或经济损失。
3. 作者及贡献者**不对**使用者的任何行为承担连带责任，亦无义务对使用者上传、下载、存储或传播的内容进行审查或监控。
4. 第三方服务（包括但不限于 [MyBooks](https://github.com/PoxenStudio/mybooks/) 服务端、[SoNovel](https://github.com/freeok/so-novel)、SMTP、TTS 及各类第三方 API）的可用性、准确性与合法性，由其提供方负责，本项目不作任何保证。使用此类第三方项目时，除遵守本项目声明外，还须遵守其各自的许可证与免责声明（如 so-novel 的 [法律免责声明](https://github.com/freeok/so-novel/blob/main/bundle/DISCLAIMER.md)）。

### 四、第三方组件

本项目在 `ohos/talebook_core/third_party/` 与 `ohos/entry/src/main/cpp/third_party/` 目录下以 vendoring 方式引入以下开源库，其著作权与许可证归各自作者所有，使用需遵守各自的许可条款：

| 组件 | 许可证 | 用途 |
|---|---|---|
| [cJSON](https://github.com/DaveGamble/cJSON) | MIT | JSON 读写 |
| [libcurl](https://curl.se/libcurl/) | curl license | HTTP / HTTPS 通信 |
| [mbedTLS](https://github.com/MbedTLS/mbedtls) | Apache-2.0 或 GPL-2.0-or-later（双许可） | TLS 支持 |
| [SQLite](https://sqlite.org/) | Public Domain | 本地数据存储 |
| [miniz](https://github.com/richgel999/miniz) | MIT | 压缩解压 |

### 五、其他

1. "Talebook"、"MyBooks" 等名称及相关标识的权利归其各自权利人所有，本项目仅为说明关联关系而引用。
2. 本项目遵循 [MyBooks](https://github.com/PoxenStudio/mybooks/) 的开源精神，坚持开源免费，不提供任何形式的商业授权或付费服务。
3. [SoNovel](https://github.com/freeok/so-novel) 等关联项目为各自独立的开源项目，其著作权、许可证与运营均由各自作者负责，与本项目无隶属或合作关系；本项目对其不作任何担保，亦不参与其运营。
4. 若权利人认为本项目存在侵权内容，请提交 [Issue](https://github.com/zhonxinya/mybooks_ohos/issues)，我们将在核实后及时处理。
5. 本声明未尽事宜，适用所在地法律法规；如本声明任何条款被认定无效，不影响其余条款的效力。

