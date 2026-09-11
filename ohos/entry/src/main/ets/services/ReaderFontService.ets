import { fileIo as fs } from '@kit.CoreFileKit';
import { ReaderFontCatalog, ReaderFontOption } from '../models/ReaderFontCatalog';
import { TalebookService } from './TalebookService';

export interface ReaderFontResolve {
  fontName: string;
  fontPath: string;
  selectFontPath: string;
}

export class ReaderFontService {
  private static fontsDir: string = '';

  static init(filesDir: string): void {
    const dir = `${filesDir}/fonts`;
    ReaderFontService.fontsDir = dir;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
    } catch (_error) {
      try {
        fs.mkdirSync(dir, true);
      } catch (_mkdirError) {
      }
    }
  }

  static listOptions(): ReaderFontOption[] {
    return ReaderFontCatalog.listOptions();
  }

  static localPath(fontId: string): string {
    const option = ReaderFontCatalog.findById(fontId);
    const ext = option?.ext ?? 'woff2';
    return `${ReaderFontService.fontsDir}/${fontId}.${ext}`;
  }

  static isCached(fontId: string): boolean {
    if (fontId === ReaderFontCatalog.SYSTEM_ID || fontId.length === 0) {
      return true;
    }
    const path = ReaderFontService.localPath(fontId);
    try {
      if (!fs.accessSync(path)) {
        return false;
      }
      const stat = fs.statSync(path);
      return stat.size > 1024;
    } catch (_error) {
      return false;
    }
  }

  static resolveForReader(fontId: string): ReaderFontResolve {
    const option = ReaderFontCatalog.findById(fontId);
    if (option === null || option.id === ReaderFontCatalog.SYSTEM_ID) {
      return { fontName: 'system', fontPath: '', selectFontPath: '' };
    }
    const urls = ReaderFontCatalog.downloadUrls(option);
    if (urls.length === 0) {
      return { fontName: 'system', fontPath: '', selectFontPath: '' };
    }
    const path = ReaderFontService.localPath(option.id);
    if (!ReaderFontService.isCached(option.id)) {
      return { fontName: 'system', fontPath: '', selectFontPath: '' };
    }
    return {
      fontName: option.fontName,
      fontPath: path,
      selectFontPath: path,
    };
  }

  static async ensureCached(fontId: string): Promise<ReaderFontResolve> {
    if (fontId === ReaderFontCatalog.SYSTEM_ID || fontId.length === 0) {
      return { fontName: 'system', fontPath: '', selectFontPath: '' };
    }
    const option = ReaderFontCatalog.findById(fontId);
    if (option === null) {
      throw new Error('未知字体');
    }
    const urls = ReaderFontCatalog.downloadUrls(option);
    if (urls.length === 0) {
      throw new Error('未知字体');
    }
    if (ReaderFontService.fontsDir.length === 0) {
      throw new Error('字体缓存目录未初始化');
    }

    const destPath = ReaderFontService.localPath(option.id);
    if (ReaderFontService.isCached(option.id)) {
      return {
        fontName: option.fontName,
        fontPath: destPath,
        selectFontPath: destPath,
      };
    }

    let lastError: string = '字体下载失败';
    for (let i = 0; i < urls.length; i++) {
      try {
        await ReaderFontService.downloadOnce(urls[i], destPath);
        if (ReaderFontService.isCached(option.id)) {
          return {
            fontName: option.fontName,
            fontPath: destPath,
            selectFontPath: destPath,
          };
        }
        lastError = '字体文件无效';
      } catch (error) {
        lastError = `${error}`;
        ReaderFontService.deleteFileQuiet(destPath);
      }
    }
    ReaderFontService.deleteFileQuiet(destPath);
    throw new Error(lastError.length > 0 ? lastError : '字体下载失败');
  }

  private static async downloadOnce(url: string, destPath: string): Promise<void> {
    ReaderFontService.deleteFileQuiet(destPath);
    const envelope = await TalebookService.fetchImageCacheAsync(url, destPath);
    if (!TalebookService.isApiSuccess(envelope)) {
      ReaderFontService.deleteFileQuiet(destPath);
      const message = envelope.error.length > 0 ? envelope.error : '字体下载失败';
      throw new Error(message);
    }
  }

  private static deleteFileQuiet(path: string): void {
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (_error) {
    }
  }
}
