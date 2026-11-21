import { webview } from '@kit.ArkWeb';

/**
 * 隐藏渲染器：fetch_url 的类浏览器降级通道。
 * HTTP 直连拿到 JS 空壳/反爬拦截页时，改用 ArkWeb（对话页上的 1vp 透明组件）
 * 真渲染后提取 body innerText。本服务只管 controller 与等待链，组件生命周期归页面。
 */
export class BrowserRenderService {
  private static ctrl: webview.WebviewController | null = null;
  private static waiter: ((text: string) => void) | null = null;
  private static timer: number = -1;
  /** innerText 提取上限（字符）：纯文本只需控模型上下文预算。 */
  private static readonly MAX_TEXT: number = 12000;

  static attach(ctrl: webview.WebviewController): void {
    BrowserRenderService.ctrl = ctrl;
  }

  static detach(): void {
    BrowserRenderService.settle('');
    BrowserRenderService.ctrl = null;
  }

  /** 渲染器是否就绪（页面未挂组件时调用方走 HTTP 错误文案）。 */
  static isReady(): boolean {
    return BrowserRenderService.ctrl !== null;
  }

  /** 加载 url 并等渲染完成提取正文；超时/无组件/失败一律回 ''，不抛。 */
  static render(url: string, timeoutMs: number = 20000): Promise<string> {
    const ctrl: webview.WebviewController | null = BrowserRenderService.ctrl;
    if (ctrl === null) {
      return Promise.resolve('');
    }
    // 已有等待先收敛（工具回路串行，理论不重入；防御旧链永挂）
    BrowserRenderService.settle('');
    return new Promise<string>((resolve: (t: string) => void): void => {
      BrowserRenderService.waiter = resolve;
      BrowserRenderService.timer = setTimeout((): void => {
        BrowserRenderService.settle('');
      }, timeoutMs);
      try {
        ctrl.loadUrl(url);
      } catch (error) {
        BrowserRenderService.settle('');
      }
    });
  }

  /** 页面 onPageEnd 回调转接：留 600ms 给异步渲染稳定再提取。 */
  static onPageEnd(): void {
    if (BrowserRenderService.waiter === null) {
      return;
    }
    setTimeout((): void => {
      BrowserRenderService.extract();
    }, 600);
  }

  private static extract(): void {
    const ctrl: webview.WebviewController | null = BrowserRenderService.ctrl;
    if (ctrl === null) {
      BrowserRenderService.settle('');
      return;
    }
    const js: string = 'document.body && document.body.innerText ? ' +
      `document.body.innerText.substring(0, ${BrowserRenderService.MAX_TEXT}) : ''`;
    ctrl.runJavaScript(js).then((result: string): void => {
      let text: string = result;
      // runJavaScript 字符串结果带 JSON 引号
      if (text.startsWith('"') && text.endsWith('"')) {
        try {
          text = String(JSON.parse(text));
        } catch (error) {
          text = text.slice(1, -1);
        }
      }
      BrowserRenderService.settle(text);
    }).catch((): void => {
      BrowserRenderService.settle('');
    });
  }

  private static settle(text: string): void {
    if (BrowserRenderService.timer >= 0) {
      clearTimeout(BrowserRenderService.timer);
      BrowserRenderService.timer = -1;
    }
    const waiter: ((text: string) => void) | null = BrowserRenderService.waiter;
    BrowserRenderService.waiter = null;
    if (waiter !== null) {
      waiter(text);
    }
  }
}
