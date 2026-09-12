import { common } from '@kit.AbilityKit';
import {
  PageScaffold, FilterChips, FilterChipItem, LoadingState, EmptyState,
  PrimaryButton, SecondaryButton, AuthImage
} from '../components';
import { TalebookService } from '../services/TalebookService';
import { ServerFeature, ServerRegistry } from '../services/ServerProfile';
import { BookUploadService, PickedBookFile } from '../services/BookUploadService';
import {
  AuthorMetaApi, AuthorMetaRecord, AUTHOR_AVATAR_SUFFIXES, AUTHOR_BIO_MAX_LENGTH,
  authorMetaMessage, isAuthorMetaOk
} from '../services/AuthorMetaApi';

/**
 * 作者 / 出版商元数据维护（mybooks 专有，门控 ServerFeature.AUTHOR_META_EDIT）。
 * 作者页：查询作者信息（简介/地区/头像）→ 保存简介 → 上传头像 → 更新该作者书籍元数据。
 * 出版商页：更新该出版商名下书籍的元数据。
 */
@Entry
@Component
struct AuthorMetaPage {
  @State loading: boolean = true;
  @State selectedTab: number = 0;
  /** 作者页输入框中的名字 */
  @State authorName: string = '';
  /** 作者页已完成查询的名字（所有作者操作都作用于该名字） */
  @State queriedAuthor: string = '';
  @State infoLoaded: boolean = false;
  @State infoExists: boolean = false;
  @State infoRegion: string = '';
  @State infoCreateTime: string = '';
  @State bioDraft: string = '';
  /** 头像破缓存版本号（上传成功后更新，驱动 AuthImage 重新拉取） */
  @State avatarVersion: string = '';
  /** 出版商页输入框中的名字 */
  @State publisherName: string = '';
  /** 进行中的操作标识（'' 表示空闲），用于禁用按钮并显示进度文案 */
  @State busyAction: string = '';

  private tabs: FilterChipItem[] = [
    { label: '作者', value: 0 },
    { label: '出版商', value: 1 },
  ];

  aboutToAppear(): void {
    void this.load();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  /** 门控：非 mybooks 服务端不支持作者元数据维护。 */
  private supported(): boolean {
    return ServerRegistry.supports(ServerFeature.AUTHOR_META_EDIT);
  }

  private idle(): boolean {
    return this.busyAction.length === 0;
  }

  private async load(): Promise<void> {
    this.loading = true;
    try {
      if (!this.supported()) {
        return;
      }
      if (!TalebookService.ensureTalebookConfigured()) {
        this.toast('请先配置服务器地址');
        return;
      }
      await TalebookService.ensureAuthenticated();
    } finally {
      this.loading = false;
    }
  }

  private async queryAuthor(): Promise<void> {
    if (!this.idle()) {
      return;
    }
    const name = this.authorName.trim();
    if (name.length === 0) {
      this.toast('请先输入作者名');
      return;
    }
    this.busyAction = 'query';
    try {
      const authed = await TalebookService.ensureAuthenticated();
      if (!authed) {
        this.toast('登录已失效，请重新登录');
        return;
      }
      const rsp = await AuthorMetaApi.getAuthorInfo(name);
      if (!isAuthorMetaOk(rsp)) {
        this.toast(authorMetaMessage(rsp, '查询作者信息失败'));
        return;
      }
      const author: AuthorMetaRecord | null = rsp.author;
      this.queriedAuthor = name;
      this.infoLoaded = true;
      this.infoExists = author !== null;
      this.infoRegion = author !== null ? author.region : '';
      this.infoCreateTime = author !== null ? author.createTime : '';
      this.bioDraft = author !== null ? author.bio : '';
      this.avatarVersion = `${Date.now()}`;
      this.toast(author !== null ? '已加载作者信息' : '服务端暂无该作者记录，保存简介后将创建');
    } catch (error) {
      this.toast(`查询失败：${error}`);
    } finally {
      this.busyAction = '';
    }
  }

  private async saveBio(): Promise<void> {
    if (!this.idle()) {
      return;
    }
    const name = this.queriedAuthor;
    if (name.length === 0) {
      this.toast('请先查询作者');
      return;
    }
    if (this.bioDraft.length > AUTHOR_BIO_MAX_LENGTH) {
      this.toast(`简介内容过长（最多 ${AUTHOR_BIO_MAX_LENGTH} 字）`);
      return;
    }
    this.busyAction = 'bio';
    try {
      const rsp = await AuthorMetaApi.saveAuthorBio(name, this.bioDraft);
      if (!isAuthorMetaOk(rsp)) {
        this.toast(authorMetaMessage(rsp, '保存简介失败'));
        return;
      }
      const author: AuthorMetaRecord | null = rsp.author;
      if (author !== null) {
        this.infoExists = true;
        this.infoRegion = author.region;
        this.infoCreateTime = author.createTime;
        this.bioDraft = author.bio;
      }
      this.toast(authorMetaMessage(rsp, '简介已保存'));
    } catch (error) {
      this.toast(`保存失败：${error}`);
    } finally {
      this.busyAction = '';
    }
  }

  private async uploadAvatar(): Promise<void> {
    if (!this.idle()) {
      return;
    }
    const name = this.queriedAuthor;
    if (name.length === 0) {
      this.toast('请先查询作者');
      return;
    }
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let file: PickedBookFile | null = null;
    try {
      file = await BookUploadService.pickStagedFile(
        context, AUTHOR_AVATAR_SUFFIXES, 'author_avatar');
    } catch (_error) {
      this.toast('无法打开文件选择器');
      return;
    }
    if (file === null) {
      return;
    }
    this.busyAction = 'avatar';
    try {
      this.toast('正在上传头像…');
      const rsp = await AuthorMetaApi.uploadAuthorAvatar(name, file.localPath, file.name);
      if (!isAuthorMetaOk(rsp)) {
        this.toast(authorMetaMessage(rsp, '头像上传失败'));
        return;
      }
      this.avatarVersion = `${Date.now()}`;
      this.toast(authorMetaMessage(rsp, '头像已更新'));
    } catch (error) {
      this.toast(`头像上传失败：${error}`);
    } finally {
      BookUploadService.removeStagedFile(file.localPath);
      this.busyAction = '';
    }
  }

  private async updateAuthorBooks(): Promise<void> {
    if (!this.idle()) {
      return;
    }
    const name = this.queriedAuthor.length > 0 ? this.queriedAuthor : this.authorName.trim();
    if (name.length === 0) {
      this.toast('请先输入作者名');
      return;
    }
    this.busyAction = 'authorBooks';
    try {
      const rsp = await AuthorMetaApi.updateAuthorBooks(name);
      if (!isAuthorMetaOk(rsp)) {
        this.toast(authorMetaMessage(rsp, '提交失败'));
        return;
      }
      this.toast(authorMetaMessage(rsp, `已提交「${name}」名下书籍的元数据更新`));
    } catch (error) {
      this.toast(`提交失败：${error}`);
    } finally {
      this.busyAction = '';
    }
  }

  private async updatePublisherBooks(): Promise<void> {
    if (!this.idle()) {
      return;
    }
    const name = this.publisherName.trim();
    if (name.length === 0) {
      this.toast('请先输入出版商名');
      return;
    }
    this.busyAction = 'publisherBooks';
    try {
      const rsp = await AuthorMetaApi.updatePublisherBooks(name);
      if (!isAuthorMetaOk(rsp)) {
        this.toast(authorMetaMessage(rsp, '提交失败'));
        return;
      }
      this.toast(authorMetaMessage(rsp, `已提交「${name}」名下书籍的元数据更新`));
    } catch (error) {
      this.toast(`提交失败：${error}`);
    } finally {
      this.busyAction = '';
    }
  }

  build() {
    Column() {
      PageScaffold({
        title: '作者元数据',
        showBack: true,
        content: () => {
          this.pageContent();
        },
      });
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  pageContent() {
    Column() {
      if (!this.supported()) {
        EmptyState({
          message: `${ServerRegistry.profile().displayName} 服务端不支持作者元数据维护`,
        });
      } else {
        FilterChips({
          items: this.tabs,
          selected: $selectedTab,
        });
        if (this.loading) {
          LoadingState({});
        } else if (this.selectedTab === 0) {
          this.authorPane();
        } else {
          this.publisherPane();
        }
      }
    }
    .width('100%')
    .height('100%');
  }

  @Builder
  fieldLabel(text: string) {
    Text(text)
      .fontSize(14)
      .fontWeight(FontWeight.Medium)
      .fontColor($r('app.color.text_primary'))
      .width('100%');
  }

  @Builder
  authorPane() {
    Scroll() {
      Column({ space: 12 }) {
        Text('输入作者名后查询简介 / 地区 / 头像；可编辑简介、上传头像，或提交刷新该作者名下书籍的元数据。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        Row({ space: 8 }) {
          TextInput({ placeholder: '作者名', text: this.authorName })
            .layoutWeight(1)
            .height(40)
            .borderRadius(8)
            .backgroundColor($r('app.color.card_background'))
            .onChange((value: string) => {
              this.authorName = value;
            });
          SecondaryButton({
            label: this.busyAction === 'query' ? '查询中…' : '查询',
            fullWidth: false,
            compact: true,
            buttonEnabled: this.idle(),
            onTap: () => {
              void this.queryAuthor();
            },
          });
        }
        .width('100%');

        if (this.infoLoaded) {
          Column({ space: 12 }) {
            Row({ space: 12 }) {
              AuthImage({
                url: AuthorMetaApi.authorAvatarPath(this.queriedAuthor, this.avatarVersion),
                imageWidth: 72,
                imageHeight: 72,
                radius: $r('app.float.card_radius'),
              });
              Column({ space: 4 }) {
                Text(this.queriedAuthor)
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'));
                Text(this.infoExists
                  ? (this.infoRegion.length > 0 ? `地区：${this.infoRegion}` : '地区：未填写')
                  : '服务端暂无该作者记录')
                  .fontSize(12)
                  .fontColor($r('app.color.text_secondary'));
                if (this.infoCreateTime.length > 0) {
                  Text(`创建时间：${this.infoCreateTime}`)
                    .fontSize(11)
                    .fontColor($r('app.color.text_tertiary'));
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1);
            }
            .width('100%');
          }
          .width('100%')
          .padding($r('app.float.card_padding'))
          .borderRadius($r('app.float.card_radius'))
          .backgroundColor($r('app.color.card_background'));

          this.fieldLabel(`简介（${this.bioDraft.length}/${AUTHOR_BIO_MAX_LENGTH}）`);
          TextArea({ text: this.bioDraft, placeholder: '作者简介' })
            .width('100%')
            .height(140)
            .borderRadius(8)
            .backgroundColor($r('app.color.card_background'))
            .onChange((value: string) => {
              this.bioDraft = value;
            });
          Row({ space: 12 }) {
            PrimaryButton({
              label: this.busyAction === 'bio' ? '保存中…' : '保存简介',
              fullWidth: false,
              buttonEnabled: this.idle(),
              onTap: () => {
                void this.saveBio();
              },
            })
              .layoutWeight(1);
            SecondaryButton({
              label: this.busyAction === 'avatar' ? '上传中…' : '上传头像',
              fullWidth: false,
              buttonEnabled: this.idle(),
              onTap: () => {
                void this.uploadAvatar();
              },
            })
              .layoutWeight(1);
          }
          .width('100%');

          this.fieldLabel('书籍元数据');
          SecondaryButton({
            label: this.busyAction === 'authorBooks' ? '提交中…' : '更新该作者书籍',
            buttonEnabled: this.idle(),
            onTap: () => {
              void this.updateAuthorBooks();
            },
          });
          Text('提交后服务端会重新抓取该作者名下书籍的元数据（单次最多 40 本），稍后刷新查看。')
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%');
        }
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off);
  }

  @Builder
  publisherPane() {
    Scroll() {
      Column({ space: 12 }) {
        Text('输入出版商名后提交，服务端会重新抓取该出版商名下书籍的元数据。')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'))
          .width('100%');

        TextInput({ placeholder: '出版商名', text: this.publisherName })
          .width('100%')
          .height(40)
          .borderRadius(8)
          .backgroundColor($r('app.color.card_background'))
          .onChange((value: string) => {
            this.publisherName = value;
          });

        SecondaryButton({
          label: this.busyAction === 'publisherBooks' ? '提交中…' : '更新该出版商书籍',
          buttonEnabled: this.idle(),
          onTap: () => {
            void this.updatePublisherBooks();
          },
        });
        Text('提交后服务端会重新抓取该出版商名下书籍的元数据（单次最多 40 本），稍后刷新查看。')
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%');
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 24 })
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off);
  }
}
