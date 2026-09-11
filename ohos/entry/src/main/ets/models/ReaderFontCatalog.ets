/**
 * 阅读器预设字体目录。
 * 中文优先用 jsDelivr @fontsource 简体/繁体包；霞鹜系列走 GitHub Release + 镜像。
 */
export interface ReaderFontOption {
  id: string;
  name: string;
  url: string;
  mirrors?: string[];
  fontName: string;
  ext?: string;
}

function fontsource(
  id: string,
  name: string,
  pkg: string,
  file: string,
  fontName: string,
  ext: string = 'woff2',
): ReaderFontOption {
  const primary = `https://cdn.jsdelivr.net/npm/@fontsource/${pkg}@5.2.5/files/${file}.${ext}`;
  const mirror = `https://unpkg.com/@fontsource/${pkg}@5.2.5/files/${file}.${ext}`;
  const mirrors: string[] = [mirror];
  if (ext === 'woff2') {
    mirrors.push(`https://cdn.jsdelivr.net/npm/@fontsource/${pkg}@5.2.5/files/${file}.woff`);
  }
  return {
    id: id,
    name: name,
    url: primary,
    mirrors: mirrors,
    fontName: fontName,
    ext: ext,
  };
}

function githubRelease(
  id: string,
  name: string,
  releaseUrl: string,
  fontName: string,
  ext: string,
): ReaderFontOption {
  return {
    id: id,
    name: name,
    url: releaseUrl,
    mirrors: [
      `https://ghfast.top/${releaseUrl}`,
      `https://mirror.ghproxy.com/${releaseUrl}`,
    ],
    fontName: fontName,
    ext: ext,
  };
}

export class ReaderFontCatalog {
  static readonly SYSTEM_ID: string = 'system';

  private static readonly OPTIONS: ReaderFontOption[] = [
    {
      id: 'system',
      name: '系统默认',
      url: '',
      fontName: 'system',
    },

    // —— 中文正文 ——
    fontsource('source_han_serif', '思源宋体', 'noto-serif-sc',
      'noto-serif-sc-chinese-simplified-400-normal', 'NotoSerifSC'),
    fontsource('source_han_serif_bold', '思源宋体粗', 'noto-serif-sc',
      'noto-serif-sc-chinese-simplified-700-normal', 'NotoSerifSCBold'),
    fontsource('source_han_sans', '思源黑体', 'noto-sans-sc',
      'noto-sans-sc-chinese-simplified-400-normal', 'NotoSansSC'),
    fontsource('source_han_sans_medium', '思源黑体中', 'noto-sans-sc',
      'noto-sans-sc-chinese-simplified-500-normal', 'NotoSansSCMedium'),
    fontsource('source_han_sans_bold', '思源黑体粗', 'noto-sans-sc',
      'noto-sans-sc-chinese-simplified-700-normal', 'NotoSansSCBold'),
    githubRelease('lxgw_wenkai', '霞鹜文楷',
      'https://github.com/lxgw/LxgwWenKai/releases/download/v1.500/LXGWWenKai-Regular.ttf',
      'LXGWWenKai', 'ttf'),
    githubRelease('lxgw_wenkai_light', '霞鹜文楷细',
      'https://github.com/lxgw/LxgwWenKai/releases/download/v1.500/LXGWWenKai-Light.ttf',
      'LXGWWenKaiLight', 'ttf'),
    githubRelease('lxgw_wenkai_medium', '霞鹜文楷中',
      'https://github.com/lxgw/LxgwWenKai/releases/download/v1.500/LXGWWenKai-Medium.ttf',
      'LXGWWenKaiMedium', 'ttf'),
    githubRelease('lxgw_neo_xihei', '霞鹜新晰黑',
      'https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.305/LXGWNeoXiHei.ttf',
      'LXGWNeoXiHei', 'ttf'),
    githubRelease('lxgw_neo_zhisong', '霞鹜新致宋',
      'https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.067/LXGWNeoZhiSong.ttf',
      'LXGWNeoZhiSong', 'ttf'),

    // —— 中文展示 / 手写 ——
    fontsource('zcool_xiaowei', '站酷小薇', 'zcool-xiaowei',
      'zcool-xiaowei-chinese-simplified-400-normal', 'ZCOOLXiaoWei'),
    fontsource('zcool_kuaile', '站酷快乐体', 'zcool-kuaile',
      'zcool-kuaile-chinese-simplified-400-normal', 'ZCOOLKuaiLe'),
    fontsource('zcool_qingke', '站酷庆科黄油体', 'zcool-qingke-huangyou',
      'zcool-qingke-huangyou-chinese-simplified-400-normal', 'ZCOOLQingKeHuangYou'),
    fontsource('ma_shan_zheng', '马善政楷书', 'ma-shan-zheng',
      'ma-shan-zheng-chinese-simplified-400-normal', 'MaShanZheng'),
    fontsource('zhi_mang_xing', '志芒星', 'zhi-mang-xing',
      'zhi-mang-xing-chinese-simplified-400-normal', 'ZhiMangXing'),
    fontsource('long_cang', '龙藏体', 'long-cang',
      'long-cang-chinese-simplified-400-normal', 'LongCang'),
    fontsource('liu_jian_mao_cao', '刘建毛草', 'liu-jian-mao-cao',
      'liu-jian-mao-cao-chinese-simplified-400-normal', 'LiuJianMaoCao'),

    // —— 繁体中文 ——
    fontsource('noto_sans_tc', '思源黑体繁', 'noto-sans-tc',
      'noto-sans-tc-chinese-traditional-400-normal', 'NotoSansTC'),
    fontsource('noto_serif_tc', '思源宋体繁', 'noto-serif-tc',
      'noto-serif-tc-chinese-traditional-400-normal', 'NotoSerifTC'),
    fontsource('noto_sans_hk', '思源黑体港', 'noto-sans-hk',
      'noto-sans-hk-chinese-hongkong-400-normal', 'NotoSansHK'),

    // —— 日文 ——
    fontsource('noto_sans_jp', 'Noto 黑体日', 'noto-sans-jp',
      'noto-sans-jp-japanese-400-normal', 'NotoSansJP'),
    fontsource('noto_serif_jp', 'Noto 宋体日', 'noto-serif-jp',
      'noto-serif-jp-japanese-400-normal', 'NotoSerifJP'),
    fontsource('zen_maru_gothic', 'Zen 圆黑', 'zen-maru-gothic',
      'zen-maru-gothic-japanese-400-normal', 'ZenMaruGothic'),
    fontsource('shippori_mincho', 'しっぽり明朝', 'shippori-mincho',
      'shippori-mincho-japanese-400-normal', 'ShipporiMincho'),
    fontsource('sawarabi_mincho', 'さわらび明朝', 'sawarabi-mincho',
      'sawarabi-mincho-japanese-400-normal', 'SawarabiMincho'),
    fontsource('mplus_rounded', 'M+ 圆体', 'm-plus-rounded-1c',
      'm-plus-rounded-1c-japanese-400-normal', 'MPlusRounded1c'),

    // —— 韩文 ——
    fontsource('noto_sans_kr', 'Noto 黑体韩', 'noto-sans-kr',
      'noto-sans-kr-korean-400-normal', 'NotoSansKR'),

    // —— 西文衬线 / 无衬线（双语或英文书） ——
    fontsource('source_serif_4', 'Source Serif', 'source-serif-4',
      'source-serif-4-latin-400-normal', 'SourceSerif4'),
    fontsource('source_sans_3', 'Source Sans', 'source-sans-3',
      'source-sans-3-latin-400-normal', 'SourceSans3'),
    fontsource('lora', 'Lora', 'lora',
      'lora-latin-400-normal', 'Lora'),
    fontsource('merriweather', 'Merriweather', 'merriweather',
      'merriweather-latin-400-normal', 'Merriweather'),
    fontsource('playfair_display', 'Playfair Display', 'playfair-display',
      'playfair-display-latin-400-normal', 'PlayfairDisplay'),
    fontsource('ibm_plex_serif', 'IBM Plex Serif', 'ibm-plex-serif',
      'ibm-plex-serif-latin-400-normal', 'IBMPlexSerif'),
    fontsource('ibm_plex_sans', 'IBM Plex Sans', 'ibm-plex-sans',
      'ibm-plex-sans-latin-400-normal', 'IBMPlexSans'),
    fontsource('crimson_pro', 'Crimson Pro', 'crimson-pro',
      'crimson-pro-latin-400-normal', 'CrimsonPro'),
    fontsource('jetbrains_mono', 'JetBrains Mono', 'jetbrains-mono',
      'jetbrains-mono-latin-400-normal', 'JetBrainsMono'),
    fontsource('fira_code', 'Fira Code', 'fira-code',
      'fira-code-latin-400-normal', 'FiraCode'),
    fontsource('caveat', 'Caveat', 'caveat',
      'caveat-latin-400-normal', 'Caveat'),
    fontsource('patrick_hand', 'Patrick Hand', 'patrick-hand',
      'patrick-hand-latin-400-normal', 'PatrickHand'),
  ];

  static listOptions(): ReaderFontOption[] {
    return ReaderFontCatalog.OPTIONS.slice();
  }

  static findById(fontId: string): ReaderFontOption | null {
    for (let i = 0; i < ReaderFontCatalog.OPTIONS.length; i++) {
      if (ReaderFontCatalog.OPTIONS[i].id === fontId) {
        return ReaderFontCatalog.OPTIONS[i];
      }
    }
    return null;
  }

  static downloadUrls(option: ReaderFontOption): string[] {
    const urls: string[] = [];
    if (option.url.length > 0) {
      urls.push(option.url);
    }
    const mirrors = option.mirrors ?? [];
    for (let i = 0; i < mirrors.length; i++) {
      if (mirrors[i].length > 0 && urls.indexOf(mirrors[i]) < 0) {
        urls.push(mirrors[i]);
      }
    }
    return urls;
  }
}
