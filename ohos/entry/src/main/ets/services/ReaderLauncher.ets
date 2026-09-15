import { UIContext } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { READER_MODE_AUTO, READER_MODE_BUILTIN, READER_MODE_PREF_KEY, ReaderFormats } from 'reader';
import { TalebookService } from './TalebookService';

/**
 * 打开阅读器的参数（与 `pages/ReadKitReader` 的入参一致）。
 * 用显式接口而非 `Record<string, Object>`：ArkTS 不允许把无类型对象字面量传给通用 Object 参数。
 */
export interface ReaderOpenParams {
  filePath: string;
  bookId: string;
  bookTitle: string;
  format: string;
  /** 上次阅读位置（可空串，表示从头开始）。 */
  location: string;
}

/**
 * 阅读器启动入口（统一守卫）。
 *
 * 选择顺序（用户可在「设置 → 阅读 → 阅读器引擎」指定）：
 * 1. 用户选了「内置阅读器」且格式支持（EPUB / TXT / MOBI）→ 直接走 `pages/BuiltInReaderPage`；
 * 2. 否则设备有系统 ReaderKit → `pages/ReadKitReader`；
 * 3. 无 ReaderKit 但格式支持 → 回退内置阅读器（模块自研，见 `feature/reader`）；
 * 4. 其余格式（AZW3 等）→ 返回 false，由调用方提示。
 *
 * `@kit.ReaderKit` 由系统 HSP（`com.huawei.hmsapp.readerkit`）提供，**不是**本应用的依赖。
 * 环境缺少该 HSP 时，路由到 `pages/ReadKitReader` 会在加载其 `modules.abc` 时失败并
 * **native abort（cppcrash）**，应用直接被进程杀掉：
 *   `[LoadJSPandaFile] resolveBufferCallback get hsp buffer failed, hsp path: .../readerkit/...`
 * 该崩溃发生在 VM 层，页面内 try/catch 与路由处 try/catch 都无法拦截，因此只能在**跳转前**判断。
 *
 * ⚠️ 为什么不用「探测 HSP 文件/包是否存在」：应用沙箱把 `/data/storage/el1/bundle` 映射为
 * **本应用自己的** bundle 目录（实测 `context.bundleCodeDir` 就等于它），
 * 因此 stat 任何兄弟 HSP 路径都返回 `13900002`（真机也一样），据此判定会把真机的正常阅读拦掉。
 * 也不能用 `bundleManager.getBundleInfo(该 HSP)`：非系统应用调用返回 `201`（权限不足），
 * 无法区分「不存在」与「无权限」。故改用**设备环境**判定（见 `isAvailable`）。
 */
export class ReaderLauncher {
  /** 系统阅读器与内置阅读器都无法打开时的统一提示。 */
  static readonly UNAVAILABLE_MESSAGE: string =
    '当前环境不提供系统阅读器组件（ReaderKit），内置阅读器支持 EPUB / TXT / MOBI';

  /** 用户是否指定优先使用内置阅读器（设置 → 阅读 → 阅读器引擎）。 */
  static prefersBuiltin(): boolean {
    return TalebookService.prefGet(READER_MODE_PREF_KEY, READER_MODE_AUTO) === READER_MODE_BUILTIN;
  }

  /**
   * 当前环境是否提供 ReaderKit。
   *
   * 只判定两类**已确认拿不到该组件**的场景，而不是去证实它存在：
   * - **模拟器**：DevEco 模拟器镜像不含 `com.huawei.hmsapp.readerkit`（实测命中并崩溃过）。
   *   模拟器可用 `deviceInfo.hardwareModel === 'emulator'`（API 12+，无需权限）识别；
   *   `displayVersion` 亦形如 `emulator 6.1.0.115(...)`，两者取或以免漏判。
   * - **非 HarmonyOS 发行版**：ReaderKit 属华为侧组件，OpenHarmony 等发行版不预装。
   *
   * 判定刻意保守：只在明确命中上述场景时返回 false；取不到信息一律放行，
   * 避免把能正常阅读的华为真机拦掉。
   */
  static isAvailable(): boolean {
    if (ReaderLauncher.isEmulator()) {
      return false;
    }
    const distribution: string = deviceInfo.distributionOSName;
    // 取不到发行版名（空）时不拦；明确是其它发行版才拦
    return distribution.length === 0 || distribution === 'HarmonyOS';
  }

  /** 是否为模拟器（hardwareModel / displayVersion 任一命中即判定，避免漏判）。 */
  private static isEmulator(): boolean {
    if (deviceInfo.hardwareModel.toLowerCase() === 'emulator') {
      return true;
    }
    return deviceInfo.displayVersion.toLowerCase().indexOf('emulator') === 0;
  }

  /**
   * 打开阅读器。
   * @param uiContext 调用方所在页面的 UIContext（本类是静态工具，没有组件 `this`）。
   * @returns true 表示已跳转；false 表示系统 ReaderKit 与内置阅读器都无法打开本书
   *          （调用方应提示 `UNAVAILABLE_MESSAGE`）。
   * @throws 内部调用可能抛出异常，由调用方处理
   */
  static open(uiContext: UIContext, params: ReaderOpenParams): boolean {
    const builtinSupported: boolean = ReaderFormats.supports(params.format);
    if (builtinSupported && ReaderLauncher.prefersBuiltin()) {
      uiContext.getRouter().pushUrl({ url: 'pages/BuiltInReaderPage', params: params });
      return true;
    }
    if (ReaderLauncher.isAvailable()) {
      uiContext.getRouter().pushUrl({ url: 'pages/ReadKitReader', params: params });
      return true;
    }
    // 无 ReaderKit：EPUB / TXT / MOBI 交给内置阅读器（自研，不依赖系统组件）
    if (builtinSupported) {
      uiContext.getRouter().pushUrl({ url: 'pages/BuiltInReaderPage', params: params });
      return true;
    }
    return false;
  }
}
