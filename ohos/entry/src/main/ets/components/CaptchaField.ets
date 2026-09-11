import { CaptchaApi, CaptchaImage, captchaErrorMessage } from '../services/CaptchaApi';

/** 验证码输入变化回调：页面据此把最新输入随表单一并提交（表单字段名 `captcha_code`）。 */
export type CaptchaCodeListener = (code: string) => void;

/** 验证码取图/校验失败回调：页面据此展示统一错误提示。 */
export type CaptchaMessageListener = (message: string) => void;

/**
 * 可复用图形验证码字段（输入框 + 图片 + 点击刷新）。
 *
 * 端点：`GET /api/captcha/image`（返回 base64 data URL 与 secure cookie 答案）、
 * `POST /api/captcha/verify`（form：provider + captcha_code）。
 * 图片随响应内联返回，不需要像 AuthImage 那样另行鉴权下载二进制。
 *
 * 使用约定：
 * - 仅在 `ServerRegistry.supports(ServerFeature.CAPTCHA)` 且 `CaptchaApi.isEnabled(scene)` 为真时渲染；
 * - 页面通过 `onCodeChange` 接收当前输入，并在提交表单时把 `captcha_code` 一并发出；
 * - 页面自增 `refreshToken` 即可要求换一张（切换场景、校验失败后）。
 */
@Component
export struct CaptchaField {
  /** 自增即可触发换图（`@Watch` 监听）。 */
  @Prop @Watch('onRefreshTokenChanged') refreshToken: number = 0;
  onCodeChange?: CaptchaCodeListener;
  onMessage?: CaptchaMessageListener;
  @State code: string = '';
  @State image: string = '';
  @State loading: boolean = true;
  @State error: string = '';

  aboutToAppear(): void {
    void this.loadImage();
  }

  private onRefreshTokenChanged(): void {
    void this.loadImage();
  }

  private emitCode(): void {
    if (this.onCodeChange !== undefined) {
      this.onCodeChange(this.code);
    }
  }

  private emitMessage(message: string): void {
    if (this.onMessage !== undefined) {
      this.onMessage(message);
    }
  }

  private async loadImage(): Promise<void> {
    this.loading = true;
    this.error = '';
    this.image = '';
    this.code = '';
    this.emitCode();
    try {
      const result: CaptchaImage = await CaptchaApi.fetchImage();
      this.image = result.image;
    } catch (error) {
      this.error = captchaErrorMessage(error);
      this.emitMessage(this.error);
    } finally {
      this.loading = false;
    }
  }

  @Builder
  imageSlot() {
    if (this.loading) {
      Column() {
        LoadingProgress()
          .width(20)
          .height(20)
          .color($r('app.color.brand_primary'));
      }
      .width(120)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.page_background'))
      .borderRadius(6);
    } else if (this.image.length > 0) {
      Image(this.image)
        .width(120)
        .height(40)
        .borderRadius(6)
        .objectFit(ImageFit.Contain)
        .backgroundColor($r('app.color.page_background'))
        .onClick(() => {
          void this.loadImage();
        });
    } else {
      Column() {
        Text('点击重试')
          .fontSize(12)
          .fontColor($r('app.color.brand_primary'));
      }
      .width(120)
      .height(40)
      .justifyContent(FlexAlign.Center)
      .backgroundColor($r('app.color.page_background'))
      .borderRadius(6)
      .onClick(() => {
        void this.loadImage();
      });
    }
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 10 }) {
        TextInput({ placeholder: '验证码', text: this.code })
          .maxLength(6)
          .height(44)
          .layoutWeight(1)
          .borderRadius(8)
          .backgroundColor($r('app.color.page_background'))
          .onChange((value: string) => {
            this.code = value;
            this.emitCode();
          });
        this.imageSlot();
      }
      .width('100%')
      .alignItems(VerticalAlign.Center);

      Text(this.error.length > 0 ? this.error : '点击图片可刷新验证码')
        .fontSize(11)
        .fontColor(this.error.length > 0 ? $r('app.color.error') : $r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%');
  }
}
