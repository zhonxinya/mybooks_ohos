import { EncyclopediaService, SEARCH_ENGINES, SearchEngine } from '../services/EncyclopediaService';

/**
 * 搜索引擎设置区（AiSettingsPage「MCP」档内的独立小节，或独立档位）。
 *
 * 勾选参与 search_web 聚合的引擎（至少留一个）；结果条数上限 3–20。
 * 改动即存，下一次 search_web 调用生效（工具结果缓存会自然过期）。
 */
@Component
export struct AiSearchEngineSection {
  @State engines: SearchEngine[] = [];
  @State onArr: boolean[] = [];
  @State limit: number = 8;

  aboutToAppear(): void {
    this.engines = SEARCH_ENGINES.slice();
    const onArr: boolean[] = [];
    for (let i = 0; i < SEARCH_ENGINES.length; i++) {
      onArr.push(EncyclopediaService.isEngineEnabled(SEARCH_ENGINES[i].id));
    }
    this.onArr = onArr;
    this.limit = EncyclopediaService.searchLimit();
  }

  private toggle(index: number, on: boolean): void {
    const ok: boolean = EncyclopediaService.setEngineEnabled(this.engines[index].id, on);
    if (!ok) {
      this.toast('至少要保留一个搜索引擎');
      this.onArr = this.onArr.slice();
      return;
    }
    this.onArr[index] = on;
  }

  private setLimit(next: number): void {
    const clamped: number = Math.min(20, Math.max(3, next));
    this.limit = clamped;
    EncyclopediaService.setSearchLimit(clamped);
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_error) {
      // 提示失败不影响主流程
    }
  }

  build() {
    Column({ space: 12 }) {
      Text('AI 联网搜索（search_web）会并行查询勾选的引擎，结果按来源可信度与摘要完整度重排序后合并。')
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .width('100%');

      ForEach(this.engines, (engine: SearchEngine, index: number) => {
        Row({ space: 8 }) {
          Text(engine.label)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .layoutWeight(1);
          Toggle({ type: ToggleType.Switch, isOn: this.onArr[index] })
            .onChange((on: boolean) => this.toggle(index, on));
        }
        .width('100%');
      }, (engine: SearchEngine, index: number) => `${engine.id}-${this.onArr[index] ? 'on' : 'off'}`)

      Row({ space: 8 }) {
        Text('结果条数上限')
          .fontSize(13)
          .fontColor($r('app.color.text_secondary'));
        Blank();
        Text('−')
          .fontSize(18)
          .fontColor(this.limit > 3 ? $r('app.color.brand_primary') : $r('app.color.text_tertiary'))
          .padding({ left: 10, right: 10 })
          .onClick(() => this.setLimit(this.limit - 1));
        Text(`${this.limit}`)
          .fontSize(14)
          .fontColor($r('app.color.text_primary'));
        Text('＋')
          .fontSize(18)
          .fontColor(this.limit < 20 ? $r('app.color.brand_primary') : $r('app.color.text_tertiary'))
          .padding({ left: 10, right: 10 })
          .onClick(() => this.setLimit(this.limit + 1));
      }
      .width('100%');

      Text('提示：百度/Bing/360/搜狗为网页抓取通道，被反爬时该通道静默跳过；维基百科走官方 API 更稳定，但中文条目覆盖有限；DeepSeek 为官方搜索接口，需在「服务商」页配 DeepSeek Key 才生效。')
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }
}
