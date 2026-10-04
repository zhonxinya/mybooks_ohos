import { PageScaffold, LegalDocument, LegalSection } from '../components';

/**
 * 开源许可页。
 *
 * 清单与 `ohos/third_party/README.md` 保持一致：native 层 vendored 的第三方库，
 * 以及 entry 模块预编译的 libcurl。运行时无第三方 SDK（无统计/广告/崩溃上报）。
 */
const LICENSE_SECTIONS: LegalSection[] = [
  {
    title: '本应用自身',
    paragraphs: [
      'talebook —— HarmonyOS 原生多源聚合阅读器',
      '许可证：BSD 2-Clause License',
      '版权：Copyright (c) 2026 zhonxinya；Copyright (c) 2025 PoxenStudio；Copyright (c) 2022 Rex',
      '说明：客户端源码以 BSD 2-Clause 许可开源。随发行版内置的第三方组件依各自许可发布，详见下方清单。'
    ]
  },
  {
    title: 'cJSON',
    paragraphs: [
      '版本：1.7.19　许可证：MIT',
      '来源：https://github.com/DaveGamble/cJSON',
      '用途：entry 模块的 JSON 读写（preferences、安全存储、Talebook / SoNovel 接口）。'
    ]
  },
  {
    title: 'curl',
    paragraphs: [
      '版本：8.12.1（entry 模块编译期头文件）；8.5.0（mybooks_core 静态编译源码）　许可证：curl License',
      '来源：https://curl.se　许可全文：https://curl.se/docs/copyright.html',
      '用途：HTTP/HTTPS 请求、Cookie 会话、流式下载、SoNovel SSE。mybooks_core 以 mbedTLS 作为 TLS 后端静态编译；entry 模块链接预编译的 libcurl.so（OpenSSL 系 TLS 后端）。',
      '注意：上述两处 curl 版本不同，安全评估需分别进行。'
    ]
  },
  {
    title: 'SQLite',
    paragraphs: [
      '版本：3.46.1（amalgamation 3460100）　许可证：Public Domain（公有领域）',
      '来源：https://www.sqlite.org　声明全文：https://www.sqlite.org/copyright.html',
      '用途：下载记录、阅读历史、书签与键值数据的本地持久化。'
    ]
  },
  {
    title: 'Mbed TLS',
    paragraphs: [
      '版本：2.28.9 LTS　许可证：Apache-2.0',
      '来源：https://www.trustedfirmware.org/projects/mbed-tls　许可全文见源码目录 ohos/third_party/mbedtls/LICENSE',
      '用途：mybooks_core 中 curl 的 TLS 后端。',
      '提示：本项目已记录该版本存在一项待修复问题（以 IP 形式访问自建服务端时，证书主体可能不被校验，对应 CVE-2025-27809），建议升级至 2.28.10 及以上版本。'
    ]
  },
  {
    title: 'miniz',
    paragraphs: [
      '版本：3.0.2　许可证：MIT',
      '来源：https://github.com/richgel999/miniz',
      '用途：EPUB 容器中 deflate（method 8）条目的解压。'
    ]
  },
  {
    title: 'tinyxml2',
    paragraphs: [
      '版本：10.0.0　许可证：zlib License',
      '来源：https://github.com/leethomason/tinyxml2',
      '用途：为 EPUB OPF XML 解析所预留的解析库。'
    ]
  },
  {
    title: '构建期依赖（不随应用分发）',
    paragraphs: [
      '@ohos/hypium 1.0.6：HarmonyOS 官方单元测试框架，仅用于工程测试，不打包进应用产物。'
    ]
  },
  {
    title: '关于第三方服务',
    paragraphs: [
      '本应用不含任何第三方运行时 SDK，不接入统计分析、广告追踪或崩溃上报服务。应用的许可义务仅来自上表所列的静态链接第三方代码。'
    ]
  }
];

@Entry
@Component
struct OpenSourceLicensesPage {
  build() {
    Column() {
      PageScaffold({
        title: '开源许可',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    LegalDocument({ sections: LICENSE_SECTIONS });
  }
}
