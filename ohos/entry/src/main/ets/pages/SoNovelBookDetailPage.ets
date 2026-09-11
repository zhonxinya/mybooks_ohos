import { router } from '@kit.ArkUI';
import { PageScaffold, PrimaryButton, SecondaryButton } from '../components';
import { SoNovelBookPayload } from '../services/TalebookService';
import { DownloadTaskService } from '../services/DownloadTaskService';
import { SoNovelMerge } from '../utils/SoNovelMerge';

@Entry
@Component
struct SoNovelBookDetailPage {
  @State title: string = '';
  @State author: string = '';
  @State sourceName: string = '';
  @State category: string = '';
  @State latestChapter: string = '';
  @State lastUpdateTime: string = '';
  @State statusText: string = '';
  @State enqueueing: boolean = false;
  private payload: SoNovelBookPayload = {
    sourceId: 0,
    sourceName: '',
    url: '',
    bookName: '',
    author: '',
  };

  aboutToAppear(): void {
    const params = router.getParams() as Record<string, Object>;
    this.payload = {
      sourceId: Number(params['sourceId'] ?? 0),
      sourceName: String(params['sourceName'] ?? ''),
      url: String(params['url'] ?? ''),
      bookName: String(params['bookName'] ?? ''),
      author: String(params['author'] ?? ''),
      category: String(params['category'] ?? ''),
      latestChapter: String(params['latestChapter'] ?? ''),
      lastUpdateTime: String(params['lastUpdateTime'] ?? ''),
      status: String(params['status'] ?? ''),
      format: 'epub',
      language: 'zh-CN',
    };
    this.title = this.payload.bookName;
    this.author = this.payload.author;
    this.sourceName = this.payload.sourceName;
    this.category = this.payload.category ?? '';
    this.latestChapter = this.payload.latestChapter ?? '';
    this.lastUpdateTime = this.payload.lastUpdateTime ?? '';
    this.statusText = this.payload.status ?? '';
  }

  private startDownload(): void {
    if (this.enqueueing) {
      return;
    }
    if (this.payload.sourceId <= 0 || this.payload.url.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '书源信息不完整' });
      return;
    }
    this.enqueueing = true;
    try {
      const existing = DownloadTaskService.getTasks().find((task) =>
        task.payload !== undefined &&
        task.payload.sourceId === this.payload.sourceId &&
        task.payload.url === this.payload.url &&
        (task.status === 'pending' || task.status === 'downloading'));
      DownloadTaskService.enqueue(this.payload);
      DownloadTaskService.processQueue();
      if (existing !== undefined) {
        this.getUIContext().getPromptAction().showToast({ message: '已在下载队列中' });
      } else if (SoNovelMerge.isUnstableSource(this.payload.sourceId)) {
        this.getUIContext().getPromptAction().showToast({
          message: '已加入队列。顶点小说书源不稳定，如下载失败请换其他书源',
        });
      } else {
        this.getUIContext().getPromptAction().showToast({ message: '已加入下载队列，由服务器下载' });
      }
      router.pushUrl({ url: 'pages/DownloadManagerPage' });
    } finally {
      this.enqueueing = false;
    }
  }

  @Builder
  metaRow(label: string, value: string) {
    if (value.length > 0) {
      Row() {
        Text(label)
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width(72);
        Text(value)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1);
      }
      .width('100%');
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '书籍详情',
        showBack: true,
        content: () => {
          this.detailContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  detailContent() {
    Column({ space: 16 }) {
      Column({ space: 8 }) {
        Text(this.title.length > 0 ? this.title : '未知书名')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'));
        if (this.author.length > 0) {
          Text(this.author)
            .fontSize(15)
            .fontColor($r('app.color.text_secondary'));
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      Column({ space: 10 }) {
        this.metaRow('书源', this.sourceName);
        this.metaRow('分类', this.category);
        this.metaRow('状态', this.statusText);
        this.metaRow('最新章节', this.latestChapter);
        this.metaRow('更新时间', this.lastUpdateTime);
      }
      .width('100%')
      .padding($r('app.float.page_padding'))
      .borderRadius($r('app.float.card_radius'))
      .backgroundColor($r('app.color.card_background'));

      if (SoNovelMerge.isUnstableSource(this.payload.sourceId)) {
        Text('该书源（顶点小说）近期不稳定，下载失败时可尝试搜索同名书并选择其他书源')
          .fontSize(12)
          .fontColor('#E84026')
          .width('100%');
      }

      PrimaryButton({
        label: this.enqueueing ? '加入队列中...' : '下载 EPUB',
        buttonEnabled: !this.enqueueing,
        onTap: () => this.startDownload(),
      });

      SecondaryButton({
        label: '查看下载管理',
        onTap: () => router.pushUrl({ url: 'pages/DownloadManagerPage' }),
      });
    }
    .padding($r('app.float.page_padding'));
  }
}
