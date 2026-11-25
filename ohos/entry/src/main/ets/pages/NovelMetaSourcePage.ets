import { common } from '@kit.AbilityKit';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { PageScaffold, PrimaryButton, SecondaryButton, SectionTitle } from '../components';
import { Reader3Native } from '../services/Reader3Native';
import { ErrorFormat } from '../utils/ErrorFormat';

/**
 * 导入文件最大读取字节数。Legado 整包导出（数千条、带注释与图标 url）常超 2MB，
 * 上限过低会把 JSON 拦腰截断成「不是有效的 JSON」——按 8MB 放宽，超限明确报错而非截断。
 */
const IMPORT_FILE_MAX_BYTES: number = 8 * 1024 * 1024;

/**
 * 元数据源规则（网文元数据用的 Legado 书源库）导入页。
 *
 * 书源属用户数据，不随应用分发；导入后写入应用沙箱 files 目录并即时刷新
 * Reader3Native 缓存，get_novel_meta 即优先按书源规则提取（未命中走站点规则兜底）。
 * 参考 reader-ohos 的「导入与订阅」页，取其本地文件 + URL 两通道；
 * 订阅管理/导出/默认书源不在本功能范围。
 */
@Entry
@Component
struct NovelMetaSourcePage {
  @State sourceCount: number = 0;
  @State busy: boolean = false;
  @State statusText: string = '';
  @State statusOk: boolean = false;
  @State importUrl: string = '';

  aboutToAppear(): void {
    void this.refreshCount();
  }

  private async refreshCount(): Promise<void> {
    this.sourceCount = await Reader3Native.count();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  private finish(ok: boolean, message: string): void {
    this.statusOk = ok;
    this.statusText = message;
    void this.refreshCount();
  }

  private async runImport(task: string, work: () => Promise<number>): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.statusText = '';
    try {
      const count: number = await work();
      this.finish(true, `${task}成功，共 ${count} 条书源`);
      this.toast(`${task}成功`);
    } catch (error) {
      const message: string = ErrorFormat.message(error);
      this.finish(false, `${task}失败：${message}`);
    } finally {
      this.busy = false;
    }
  }

  private async pickImportFile(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    options.fileSuffixFilters = ['.json', '.txt'];
    let uris: string[] = [];
    try {
      const viewPicker = new picker.DocumentViewPicker(context);
      uris = await viewPicker.select(options);
    } catch (error) {
      this.toast(`选择文件失败：${ErrorFormat.message(error)}`);
      return;
    }
    if (uris.length === 0) {
      return;
    }
    const text: string = await this.readTextFile(uris[0]);
    if (text.length === 0) {
      if (this.statusText.length === 0) {
        this.finish(false, '导入失败：文件为空或无法读取');
      }
      return;
    }
    await this.runImport('文件导入', async (): Promise<number> => Reader3Native.importFromText(text));
  }

  private async readTextFile(uri: string): Promise<string> {
    try {
      const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
      try {
        const stat = await fs.stat(file.fd);
        const size: number = Number(stat.size);
        if (size <= 0) {
          return '';
        }
        if (size > IMPORT_FILE_MAX_BYTES) {
          // 绝不截断读取：截半的 JSON 只会得到莫名的「不是有效的 JSON」
          throw new Error(`文件约 ${Math.round(size / 1048576)}MB，超过 ${IMPORT_FILE_MAX_BYTES / 1048576}MB 上限`);
        }
        const buffer = new ArrayBuffer(size);
        const readLength: number = await fs.read(file.fd, buffer, { offset: 0, length: size });
        const decoder = util.TextDecoder.create('utf-8', { ignoreBOM: true });
        return decoder.decodeToString(new Uint8Array(buffer, 0, readLength));
      } finally {
        await fs.close(file.fd);
      }
    } catch (error) {
      const message: string = ErrorFormat.message(error);
      this.finish(false, `导入失败：读取文件失败（${message}）`);
      return '';
    }
  }

  private async importFromUrl(): Promise<void> {
    const url: string = this.importUrl.trim();
    if (url.length === 0) {
      this.finish(false, '请输入书源 JSON 链接');
      return;
    }
    if (!/^https?:\/\/\S+$/.test(url)) {
      this.finish(false, '链接需为 http(s) 地址');
      return;
    }
    await this.runImport('URL 导入', async (): Promise<number> => Reader3Native.importFromUrl(url));
    if (this.statusOk) {
      this.importUrl = '';
    }
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 16 }) {
        Text('网文元数据提取使用 Legado 书源规则：导入书源 JSON（Legado「整包导出」文件）后，'
          + '查询网文元数据将优先按书源规则抓取详情页；未导入或未命中时仍按内置站点规则解析。')
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(22)
          .width('100%')

        Column({ space: 8 }) {
          Row() {
            Text('已导入书源')
              .fontSize(15)
              .fontColor($r('app.color.text_primary'))
            Blank()
            Text(`${this.sourceCount} 条`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.sourceCount > 0 ? $r('app.color.brand_primary') : $r('app.color.text_secondary'))
          }
          .width('100%')
          Text('书源文件保存在本机应用数据目录，不随应用分发、不上传服务器。')
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')
        }
        .width('100%')
        .padding(16)
        .borderRadius($r('app.float.card_radius'))
        .backgroundColor($r('app.color.card_background'))

        Column({ space: 12 }) {
          PrimaryButton({
            label: this.busy ? '导入中…' : '从本地文件导入',
            buttonEnabled: !this.busy,
            onTap: () => {
              void this.pickImportFile();
            },
          })
          Row({ space: 8 }) {
            TextInput({ placeholder: '粘贴书源 JSON 链接 https://…', text: this.importUrl })
              .fontSize(14)
              .height(40)
              .layoutWeight(1)
              .enabled(!this.busy)
              .enterKeyType(EnterKeyType.Done)
              .onChange((value: string) => {
                this.importUrl = value;
              })
              // 回车即导入，省一次按钮点击（移动端粘贴链接后的自然操作）
              .onSubmit(() => {
                void this.importFromUrl();
              })
            SecondaryButton({
              label: 'URL 导入',
              buttonEnabled: !this.busy && this.importUrl.trim().length > 0,
              fullWidth: false,
              onTap: () => {
                void this.importFromUrl();
              },
            })
          }
          .width('100%')
        }
        .width('100%')

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(this.statusOk ? $r('app.color.success') : $r('app.color.error'))
            .width('100%')
            .padding(12)
            .borderRadius($r('app.float.card_radius'))
            .backgroundColor($r('app.color.card_background'))
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 32 })
    }
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
    .width('100%')
    .height('100%')
  }

  build() {
    Column() {
      PageScaffold({
        title: '元数据源规则',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
