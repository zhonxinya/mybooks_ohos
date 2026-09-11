import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

export interface PickedBookFile {
  name: string;
  size: number;
  localPath: string;
}

export interface PickBookResult {
  files: PickedBookFile[];
  skipped: string[];
}

/** 拉起系统文件选择器挑选书籍文件，拷贝到缓存目录后供上传使用 */
export class BookUploadService {
  /** 与服务端 SUPPORTED_EBOOK_FORMATS 保持一致 */
  static readonly SUPPORTED_SUFFIXES: string[] =
    ['.epub', '.mobi', '.azw3', '.azw', '.txt', '.pdf', '.docx'];

  static isSupportedName(name: string): boolean {
    const lower = name.toLowerCase();
    return BookUploadService.SUPPORTED_SUFFIXES.some((suffix: string) => lower.endsWith(suffix));
  }

  static async pickBookFiles(context: common.UIAbilityContext, maxCount: number = 10):
    Promise<PickBookResult> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = maxCount;
    options.fileSuffixFilters = BookUploadService.SUPPORTED_SUFFIXES;
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);

    const stageDir = `${context.cacheDir}/upload`;
    try {
      if (!fs.accessSync(stageDir)) {
        fs.mkdirSync(stageDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(stageDir, true);
    }

    const result: PickBookResult = { files: [], skipped: [] };
    for (let i = 0; i < uris.length; i++) {
      const picked = BookUploadService.stageUri(uris[i], stageDir, Date.now() + i);
      if (picked === null) {
        const name = BookUploadService.uriToName(uris[i]);
        result.skipped.push(name);
      } else {
        result.files.push(picked);
      }
    }
    return result;
  }

  static removeStagedFile(localPath: string): void {
    try {
      fs.unlinkSync(localPath);
    } catch (_error) {
    }
  }

  /** 标记书库已有变更，供图书管理页返回时刷新 */
  static markLibraryDirty(): void {
    AppStorage.setOrCreate('talebookLibraryDirty', true);
  }

  static consumeLibraryDirty(): boolean {
    const dirty = AppStorage.get<boolean>('talebookLibraryDirty') === true;
    if (dirty) {
      AppStorage.set('talebookLibraryDirty', false);
    }
    return dirty;
  }

  static formatSize(size: number): string {
    if (size >= 1024 * 1024) {
      return `${(size / 1024 / 1024).toFixed(1)} MB`;
    }
    if (size >= 1024) {
      return `${(size / 1024).toFixed(0)} KB`;
    }
    return `${size} B`;
  }

  /** 拉起系统文件选择器挑选头像图片，拷贝到缓存目录后供上传使用 */
  /** 打开系统文件选择器，单选克隆音色音频（mp3/wav，≤7MB），复制到缓存目录供上传使用 */
  static readonly CLONE_AUDIO_SUFFIXES: string[] = ['.mp3', '.wav'];
  static readonly CLONE_AUDIO_MAX_BYTES: number = 7 * 1024 * 1024;

  static async pickAudioClone(context: common.UIAbilityContext): Promise<PickedBookFile | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = BookUploadService.CLONE_AUDIO_SUFFIXES;
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const stageDir = `${context.cacheDir}/upload`;
    try {
      if (!fs.accessSync(stageDir)) {
        fs.mkdirSync(stageDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(stageDir, true);
    }
    const name = BookUploadService.uriToName(uris[0]);
    const lower = name.toLowerCase();
    const ok = BookUploadService.CLONE_AUDIO_SUFFIXES.some((suffix: string) => lower.endsWith(suffix));
    if (!ok) {
      return null;
    }
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(src.fd).size;
      if (size > BookUploadService.CLONE_AUDIO_MAX_BYTES) {
        return null;
      }
      const safeName = name.replace(/[\/\\]/g, '_');
      const destPath = `${stageDir}/clone_${Date.now()}_${safeName}`;
      fs.copyFileSync(src.fd, destPath);
      return { name: safeName, size: size, localPath: destPath };
    } finally {
      fs.closeSync(src.fd);
    }
  }

  /** 通用单选文件并拷贝到缓存目录（图章/SSL 等管理上传复用）。 */
  static async pickStagedFile(
    context: common.UIAbilityContext,
    suffixes: string[],
    stagedPrefix: string,
  ): Promise<PickedBookFile | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = suffixes;
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const stageDir = `${context.cacheDir}/upload`;
    try {
      if (!fs.accessSync(stageDir)) {
        fs.mkdirSync(stageDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(stageDir, true);
    }
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(src.fd).size;
      const rawName = BookUploadService.uriToName(uris[0]);
      const safeName = rawName.replace(/[\/\\]/g, '_');
      const destPath = `${stageDir}/${stagedPrefix}_${Date.now()}_${safeName}`;
      fs.copyFileSync(src.fd, destPath);
      return { name: safeName, size: size, localPath: destPath };
    } finally {
      fs.closeSync(src.fd);
    }
  }

  /** 打开系统文件选择器，单选 PDF，复制到缓存目录供上传使用 */
  static async pickPdfFile(context: common.UIAbilityContext): Promise<PickedBookFile | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.pdf'];
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const stageDir = `${context.cacheDir}/upload`;
    try {
      if (!fs.accessSync(stageDir)) {
        fs.mkdirSync(stageDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(stageDir, true);
    }
    const name = BookUploadService.uriToName(uris[0]);
    if (!name.toLowerCase().endsWith('.pdf')) {
      return null;
    }
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(src.fd).size;
      const safeName = name.replace(/[\/\\]/g, '_');
      const destPath = `${stageDir}/pdf_${Date.now()}_${safeName}`;
      fs.copyFileSync(src.fd, destPath);
      return { name: safeName, size: size, localPath: destPath };
    } finally {
      fs.closeSync(src.fd);
    }
  }

  static async pickAvatarImage(context: common.UIAbilityContext): Promise<PickedBookFile | null> {
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.jpg', '.jpeg', '.png', '.webp'];
    const viewPicker = new picker.DocumentViewPicker(context);
    const uris = await viewPicker.select(options);
    if (uris.length === 0) {
      return null;
    }
    const stageDir = `${context.cacheDir}/upload`;
    try {
      if (!fs.accessSync(stageDir)) {
        fs.mkdirSync(stageDir, true);
      }
    } catch (_error) {
      fs.mkdirSync(stageDir, true);
    }
    const src = fs.openSync(uris[0], fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(src.fd).size;
      const ext = '.png';
      const destPath = `${stageDir}/avatar_${Date.now()}${ext}`;
      fs.copyFileSync(src.fd, destPath);
      return { name: `avatar${ext}`, size: size, localPath: destPath };
    } finally {
      fs.closeSync(src.fd);
    }
  }

  private static uriToName(uri: string): string {
    const raw = uri.substring(uri.lastIndexOf('/') + 1);
    try {
      return decodeURIComponent(raw);
    } catch (_error) {
      return raw;
    }
  }

  private static stageUri(uri: string, stageDir: string, uniqueId: number): PickedBookFile | null {
    const name = BookUploadService.uriToName(uri);
    if (!BookUploadService.isSupportedName(name)) {
      return null;
    }
    const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = fs.statSync(src.fd).size;
      const safeName = name.replace(/[\/\\]/g, '_');
      const destPath = `${stageDir}/${uniqueId}_${safeName}`;
      fs.copyFileSync(src.fd, destPath);
      return { name: safeName, size: size, localPath: destPath };
    } finally {
      fs.closeSync(src.fd);
    }
  }
}
