import { image } from '@kit.ImageKit';

/**
 * 图片宽高比读取（纯计算，仅依赖 `@ohos.multimedia.image`，**不含任何 UI 调用**）。
 *
 * 独立成模块的原因：`@Concurrent` 函数只能使用 import 进来的符号或局部变量，
 * 因此这类工具必须放在可 import 的模块里，才能在 taskpool 子线程中被调用。
 */
export function imageAspect(path: string): number {
  try {
    const source = image.createImageSource(path);
    if (source === undefined) {
      return 0;
    }
    const info = source.getImageInfoSync();
    const size = info.size;
    source.release();
    if (size.width > 0 && size.height > 0) {
      return size.width / size.height;
    }
  } catch (_error) {
    return 0;
  }
  return 0;
}
