import { DownloadTask } from '../services/TalebookService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { AppRouter } from '../utils/AppRouter';

/**
 * 常驻下载进度条：有排队/下载中任务时悬浮在底部 tab 栏上方（挂在 MainTabs）。
 * 一行表达「当前任务 + 进度 + 剩余数量」，点条体进下载管理页，X 取消当前任务
 * （与 DownloadManagerPage 同一 remove 语义，不做第二套取消实现）。
 *
 * 高频进度（downloadTasksTick 每 250ms）订阅刻意收在这个极小组件内部：
 * ArkUI 没有重绘隔离手段，缩小重建子树就是正解——主 Tabs 完全不感知。
 */
@Component
export struct DownloadFloatingBar {

  @StorageProp('downloadTasksTick') @Watch('refresh') tick: number = 0;
  /** 墨水屏档：转圈动画不渲染（沿用下载管理页取舍），线性条与文案仍表进度。 */
  @StorageProp('eink_mode') einkMode: boolean = false;
  @State visible: boolean = false;
  @State title: string = '';
  @State downloading: boolean = false;
  @State progress: number = 0;
  @State remaining: number = 0;
  @State activeId: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const tasks: DownloadTask[] = DownloadTaskService.getTasks();
    const active: DownloadTask[] = tasks.filter((t: DownloadTask) =>
      t.status === 'downloading' || t.status === 'pending');
    if (active.length === 0) {
      this.visible = false;
      return;
    }
    // 展示选 downloading 里进度最高的；全在排队就取队首（getTasks 排队序即数组序）
    let current: DownloadTask = active[0];
    for (let i = 1; i < active.length; i++) {
      const t: DownloadTask = active[i];
      if (t.status === 'downloading' &&
        (current.status !== 'downloading' || t.progress > current.progress)) {
        current = t;
      }
    }
    this.visible = true;
    this.title = current.title;
    this.downloading = current.status === 'downloading';
    this.progress = current.progress;
    this.remaining = active.length - 1;
    this.activeId = current.id;
  }

  /** 取消当前任务：与下载管理页同语义（remove 记录，进度回调随即失去落点）。 */
  private cancelCurrent(): void {
    if (this.activeId.length === 0) {
      return;
    }
    DownloadTaskService.remove(this.activeId);
    this.getUIContext().getPromptAction().showToast({ message: '任务已取消' });
    this.refresh();
  }

  build() {
    if (this.visible) {
      Row({ space: 10 }) {
        if (this.downloading && !this.einkMode) {
          LoadingProgress()
            .width(18)
            .height(18)
            .color($r('app.color.brand_primary'));
        } else if (!this.downloading) {
          SymbolGlyph($r('sys.symbol.hourglass'))
            .fontSize(16)
            .fontColor([$r('app.color.text_secondary')]);
        }
        Column({ space: 3 }) {
          Text(this.downloading
            ? `下载「${this.title}」${this.progress}%${this.remaining > 0 ? ` · 还有 ${this.remaining} 个` : ''}`
            : `排队中「${this.title}」${this.remaining > 0 ? ` · 共 ${this.remaining + 1} 个` : ''}`)
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          if (this.downloading) {
            Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color($r('app.color.brand_primary'));
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start);
        Stack() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(13)
            .fontColor([$r('app.color.text_secondary')]);
        }
        .width(28)
        .height(28)
        .borderRadius(14)
        .backgroundColor($r('app.color.page_background'))
        .onClick(() => this.cancelCurrent());
      }
      .width('100%')
      .padding({ left: 14, right: 10, top: 9, bottom: 9 })
      .borderRadius(14)
      .backgroundColor($r('app.color.card_background'))
      .shadow({ radius: 10, type: ShadowType.COLOR, color: $r('app.color.button_shadow'), offsetX: 0, offsetY: -2 })
      .onClick(() => {
        AppRouter.pushUrl(this.getUIContext(), { url: 'pages/DownloadManagerPage' }).catch(() => {
        });
      });
    }
  }
}
