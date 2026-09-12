import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { DownloadRecord, TalebookService } from './TalebookService';
import { AccountManager } from './AccountManager';

const SUPPORTED_SUFFIXES: string[] = ['.epub', '.txt', '.mobi', '.azw', '.azw3'];
const MAX_FILE_SIZE: number = 300 * 1024 * 1024;

export class LocalBookService {
  /** @throws 内部调用可能抛出异常，由调用方处理 */
  static async pickAndImport(context: common.UIAbilityContext): Promise<DownloadRecord | null> {
    const options = new picker.DocumentSelectOptions();
    options.fileSuffixFilters = SUPPORTED_SUFFIXES;
    const documentPicker = new picker.DocumentViewPicker(context);
    const result = await documentPicker.select(options);
    if (!result || result.length === 0) {
      return null;
    }
    const srcPath = decodeURI(result[0]);
    return LocalBookService.importFile(context.filesDir, srcPath);
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  static async importFile(filesDir: string, srcPath: string): Promise<DownloadRecord> {
    if (srcPath.length === 0) {
      throw new Error('未选择文件');
    }
    const extension = LocalBookService.fileExtension(srcPath);
    if (!LocalBookService.isSupportedExtension(extension)) {
      throw new Error('不支持该格式，请选择 EPUB、TXT、MOBI 或 AZW 文件');
    }
    const fileSize = LocalBookService.fileSize(srcPath);
    if (fileSize <= 0) {
      throw new Error('文件无效或无法读取');
    }
    if (fileSize > MAX_FILE_SIZE) {
      throw new Error('文件超过 300MB');
    }

    const booksDir = AccountManager.booksDir(filesDir);
    LocalBookService.ensureDir(booksDir);

    const bookId = `local_${util.generateRandomUUID(true)}`;
    const destPath = `${booksDir}/${bookId}.${extension}`;
    await LocalBookService.copyFile(srcPath, destPath);

    const title = LocalBookService.fileTitle(srcPath);
    const record: DownloadRecord = {
      bookId: bookId,
      title: title,
      filePath: destPath,
      format: extension.toUpperCase(),
      downloadTime: Date.now(),
    };
    TalebookService.upsertDownloadRecord(record);
    return record;
  }

  static isSupportedExtension(extension: string): boolean {
    const normalized = extension.startsWith('.') ? extension : `.${extension}`;
    return SUPPORTED_SUFFIXES.includes(normalized.toLowerCase());
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private static ensureDir(path: string): void {
    try {
      if (!fs.accessSync(path)) {
        fs.mkdirSync(path, true);
      }
    } catch (_error) {
      fs.mkdirSync(path, true);
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private static async copyFile(srcPath: string, destPath: string): Promise<void> {
    let fileId = -1;
    try {
      const file = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      fileId = file.fd;
      await fs.copyFile(fileId, destPath, 0);
    } catch (_error) {
      throw new Error('复制文件失败');
    } finally {
      if (fileId >= 0) {
        fs.close(fileId);
      }
    }
  }

  /** @throws 内部调用可能抛出异常，由调用方处理 */
  private static fileSize(path: string): number {
    let fileId = -1;
    try {
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fileId = file.fd;
      const stat = fs.statSync(fileId);
      return stat.size;
    } catch (_error) {
      return -1;
    } finally {
      if (fileId >= 0) {
        fs.close(fileId);
      }
    }
  }

  private static fileExtension(path: string): string {
    const name = LocalBookService.fileBaseName(path);
    const dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex === name.length - 1) {
      return '';
    }
    return name.substring(dotIndex + 1).toLowerCase();
  }

  private static fileTitle(path: string): string {
    const name = LocalBookService.fileBaseName(path);
    const dotIndex = name.lastIndexOf('.');
    if (dotIndex <= 0) {
      return name;
    }
    return name.substring(0, dotIndex);
  }

  private static fileBaseName(path: string): string {
    const normalized = path.replace(/\\/g, '/');
    const parts = normalized.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : path;
  }
}
