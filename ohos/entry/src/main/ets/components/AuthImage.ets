import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { TalebookService } from '../services/TalebookService';
import { CoverCache } from '../utils/CoverCache';

/** 未显式传 decode 尺寸且 layout 非数字时的默认解码宽（vp）。 */
const DEFAULT_DECODE_WIDTH_VP: number = 120;
/** 未显式传 decode 尺寸且 layout 非数字时的默认解码高（vp）。 */
const DEFAULT_DECODE_HEIGHT_VP: number = 170;

@Component
export struct AuthImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop imageWidth: Length = 56;
  @Prop imageHeight: Length = 80;
  /** 解码宽（vp）；0 表示从 imageWidth 数字或默认值推导。 */
  @Prop decodeWidthVp: number = 0;
  /** 解码高（vp）；0 表示从 imageHeight 数字或默认值推导。 */
  @Prop decodeHeightVp: number = 0;
  @Prop radius: Resource = $r('app.float.cover_radius');
  @State localPath: string = '';
  private loadToken: number = 0;

  aboutToAppear(): void {
    void this.loadImage();
  }

  private onUrlChanged(): void {
    this.localPath = '';
    void this.loadImage();
  }

  private hasCachedFile(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private resolveDecodeVp(explicit: number, layout: Length, fallback: number): number {
    if (explicit > 0) {
      return explicit;
    }
    if (typeof layout === 'number') {
      return layout as number;
    }
    return fallback;
  }

  private decodeWidthPx(): number {
    const widthVp = this.resolveDecodeVp(this.decodeWidthVp, this.imageWidth, DEFAULT_DECODE_WIDTH_VP);
    let widthPx = widthVp;
    try {
      widthPx = this.getUIContext().vp2px(widthVp);
    } catch (_error) {
    }
    return Math.max(1, Math.round(widthPx));
  }

  private decodeHeightPx(): number {
    const heightVp = this.resolveDecodeVp(this.decodeHeightVp, this.imageHeight, DEFAULT_DECODE_HEIGHT_VP);
    let heightPx = heightVp;
    try {
      heightPx = this.getUIContext().vp2px(heightVp);
    } catch (_error) {
    }
    return Math.max(1, Math.round(heightPx));
  }

  private async loadImage(): Promise<void> {
    if (this.url.length === 0) {
      return;
    }
    if (this.url.startsWith('file://') || this.url.startsWith('/data/')) {
      this.localPath = this.url;
      return;
    }
    const token = ++this.loadToken;
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    CoverCache.ensureDir(context);
    const resolved = TalebookService.resolveCoverUrl(this.url);
    const destPath = CoverCache.pathFor(context, resolved);
    if (this.hasCachedFile(destPath)) {
      this.localPath = destPath;
      return;
    }
    const envelope = await TalebookService.fetchImageCacheAsync(resolved, destPath);
    if (token !== this.loadToken) {
      return;
    }
    if (envelope.status >= 200 && envelope.status < 300) {
      this.localPath = String(envelope.body?.['filePath'] ?? destPath);
      // 淘汰放到下一事件循环，避免滚动中同步 listFile/stat 卡帧
      setTimeout(() => {
        CoverCache.maybeEvict(context);
      }, 0);
    }
  }

  build() {
    if (this.localPath.length > 0) {
      Image('file://' + this.localPath)
        .width(this.imageWidth)
        .height(this.imageHeight)
        .borderRadius(this.radius)
        .objectFit(ImageFit.Cover)
        .sourceSize({
          width: this.decodeWidthPx(),
          height: this.decodeHeightPx(),
        })
        .backgroundColor($r('app.color.cover_placeholder_bg'));
    } else {
      // 缓存未就绪：只占位，不挂网络 Image，避免网格滚动时全分辨率解码
      Column()
        .width(this.imageWidth)
        .height(this.imageHeight)
        .borderRadius(this.radius)
        .backgroundColor($r('app.color.cover_placeholder_bg'));
    }
  }
}
