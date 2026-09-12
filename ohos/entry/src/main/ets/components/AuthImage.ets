import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { TalebookService } from '../services/TalebookService';
import { CoverCache } from '../utils/CoverCache';

@Component
export struct AuthImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  @Prop imageWidth: Length = 56;
  @Prop imageHeight: Length = 80;
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
      CoverCache.maybeEvict(context);
    }
  }

  build() {
    if (this.localPath.length > 0) {
      Image('file://' + this.localPath)
        .width(this.imageWidth)
        .height(this.imageHeight)
        .borderRadius(this.radius)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.cover_placeholder_bg'));
    } else if (this.url.length > 0) {
      Image(this.url)
        .width(this.imageWidth)
        .height(this.imageHeight)
        .borderRadius(this.radius)
        .objectFit(ImageFit.Cover)
        .backgroundColor($r('app.color.cover_placeholder_bg'));
    }
  }
}
