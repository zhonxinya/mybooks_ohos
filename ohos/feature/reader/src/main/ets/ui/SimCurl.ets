/**
 * 仿真翻页的折痕几何（纯函数，便于单独推演、日志核对）。
 *
 * 模型：折痕**过当前手指位置 `F`**，方向**垂直于拖动方向**。
 * - 折痕落在手指上 ⇒ 拖多远折痕就走多远，跟手 1:1（与最初的实现手感一致）；
 * - 斜向拖动时折痕随之倾斜 ⇒ 从不同区域、不同方向起手，卷页效果不一样；
 * - 手指按下点 `T` 用来判定哪一侧是被抓住、要卷起来的纸：`T` 所在的一侧卷起露出新页，
 *   另一侧仍是平摊的当前页。
 *
 * 折痕倾斜角做了钳制（与竖直方向夹角 ≤ `MAX_TILT_TAN`），避免斜向拖拽时折痕被压成水平、
 * 整页看起来「横着被撕开」。
 */

/** 折痕与竖直方向的最大倾角（tan 值）：≈35°。 */
const MAX_TILT_TAN: number = 0.7;
/** 拖动距离小于该值（vp）时视为还没真正起手：退回竖直折痕，避免抖动放大成斜折。 */
const MIN_DRAG_FOR_TILT: number = 6;
/**
 * 折痕弯曲幅度上限（vp）：真实纸被拉起时折痕不是直线，中间会朝「还没卷走的一侧」鼓出来。
 * 幅度按拖动进度 0 → 上限 渐变，起手时仍是近似直线。
 */
const FOLD_BULGE_VP: number = 18;
/** 弯曲幅度达到上限所需的拖动进度（占内容区宽度的比例）。 */
const BULGE_FULL_PROGRESS: number = 0.35;

interface FoldCore {
  dirX: number;
  dirY: number;
  midX: number;
  midY: number;
  centerX: number;
  centerY: number;
  span: number;
  rotationDeg: number;
  peelSign: number;
  tilted: boolean;
}

export interface CurlFold {
  dirX: number;
  dirY: number;
  midX: number;
  midY: number;
  centerX: number;
  centerY: number;
  span: number;
  rotationDeg: number;
  peelSign: number;
  tilted: boolean;
  /** 未卷走的一侧（当前页可见部分）的裁剪路径。 */
  frontPath: string;
  /** 被卷起的一侧（翻过去、露出新页）的裁剪路径。 */
  peelPath: string;
}

/** 半平面判定：ret > 0 表示点在折痕法线正侧。 */
function sideOf(px: number, py: number, midX: number, midY: number, dirX: number, dirY: number): number {
  return dirX * (py - midY) - dirY * (px - midX);
}

/** 线段与折痕的交点参数（`sideOf` 在两端的取值一正一负时有效）。 */
function crossParam(aVal: number, bVal: number): number {
  const denom = aVal - bVal;
  return denom === 0 ? 0 : aVal / denom;
}

/**
 * 页面矩形与半平面的交集多边形（Sutherland–Hodgman，只裁一条边，最多 5 个顶点）。
 * `keepSign > 0` 表示保留 `sideOf >= 0` 的一侧。
 */
function rectHalfPlane(
  width: number,
  height: number,
  midX: number,
  midY: number,
  dirX: number,
  dirY: number,
  keepSign: number,
): number[] {
  const xs: number[] = [0, width, width, 0];
  const ys: number[] = [0, 0, height, height];
  const out: number[] = [];
  for (let i = 0; i < 4; i++) {
    const j = (i + 1) % 4;
    const ax = xs[i];
    const ay = ys[i];
    const bx = xs[j];
    const by = ys[j];
    const aVal = keepSign * sideOf(ax, ay, midX, midY, dirX, dirY);
    const bVal = keepSign * sideOf(bx, by, midX, midY, dirX, dirY);
    const aIn = aVal >= 0;
    const bIn = bVal >= 0;
    if (aIn) {
      out.push(ax);
      out.push(ay);
    }
    if (aIn !== bIn) {
      const t = crossParam(aVal, bVal);
      out.push(ax + (bx - ax) * t);
      out.push(ay + (by - ay) * t);
    }
  }
  return out;
}

/** 多边形 → SVG path 命令（保留一位小数，够用且日志可读）。 */
function polygonPath(points: number[]): string {
  if (points.length < 6) {
    return 'M0 0 Z';
  }
  let path = '';
  for (let i = 0; i + 1 < points.length; i += 2) {
    const x = Math.round(points[i] * 10) / 10;
    const y = Math.round(points[i + 1] * 10) / 10;
    path += `${i === 0 ? 'M' : 'L'}${x} ${y} `;
  }
  return `${path}Z`;
}

/** 折痕在页面矩形内的可见段：返回 [起点参数, 终点参数]（沿 `dir` 方向）。 */
function foldSpanParams(
  width: number,
  height: number,
  midX: number,
  midY: number,
  dirX: number,
  dirY: number,
): number[] {
  // 板法（slab）：分别求 x、y 方向上的参数区间再取交
  let tMin = -1e9;
  let tMax = 1e9;
  if (Math.abs(dirX) > 1e-6) {
    const t1 = (0 - midX) / dirX;
    const t2 = (width - midX) / dirX;
    tMin = Math.max(tMin, Math.min(t1, t2));
    tMax = Math.min(tMax, Math.max(t1, t2));
  } else if (midX < 0 || midX > width) {
    return [0, 0];
  }
  if (Math.abs(dirY) > 1e-6) {
    const t1 = (0 - midY) / dirY;
    const t2 = (height - midY) / dirY;
    tMin = Math.max(tMin, Math.min(t1, t2));
    tMax = Math.min(tMax, Math.max(t1, t2));
  } else if (midY < 0 || midY > height) {
    return [0, 0];
  }
  if (tMax <= tMin) {
    return [0, 0];
  }
  return [tMin, tMax];
}

/**
 * 计算当前拖拽状态下的折痕几何。
 *
 * @param width 内容区宽（vp）
 * @param height 内容区高（vp）
 * @param touchX/touchY 手指按下点（vp，内容区坐标系）
 * @param dx/dy 相对按下点的累计位移（vp）
 */
function foldCore(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
): FoldCore {
  const fingerX = touchX + dx;
  const fingerY = touchY + dy;
  // 折痕过手指：这样「拖多远、折痕走多远」，跟手是 1:1
  const midX = fingerX;
  const midY = fingerY;
  // 折痕方向 = 拖动方向的法线
  let dirX = -dy;
  let dirY = dx;
  const length = Math.sqrt(dirX * dirX + dirY * dirY);
  let tilted = false;
  if (length < MIN_DRAG_FOR_TILT) {
    // 还没真正起手（或纯竖直拖动）：退回竖直折痕
    dirX = 0;
    dirY = 1;
  } else {
    dirX = dirX / length;
    dirY = dirY / length;
    // 与竖直方向夹角钳制：|dirX / dirY| <= MAX_TILT_TAN
    if (Math.abs(dirY) < 1e-3) {
      dirX = 0;
      dirY = dirY >= 0 ? 1 : -1;
    } else if (Math.abs(dirX / dirY) > MAX_TILT_TAN) {
      const sign = dirX >= 0 ? 1 : -1;
      dirX = sign * MAX_TILT_TAN * Math.abs(dirY);
      const norm = Math.sqrt(dirX * dirX + dirY * dirY);
      dirX = dirX / norm;
      dirY = dirY / norm;
    }
    tilted = true;
  }
  // 统一让 dirY > 0：折痕方向取反是同一条直线，但渐变带按固定朝向摆放
  if (dirY < 0) {
    dirX = -dirX;
    dirY = -dirY;
  }
  const span = foldSpanParams(width, height, midX, midY, dirX, dirY);
  const centerT = (span[0] + span[1]) / 2;
  const touchSide = sideOf(touchX, touchY, midX, midY, dirX, dirY);
  const core: FoldCore = {
    dirX: dirX,
    dirY: dirY,
    midX: midX,
    midY: midY,
    centerX: midX + dirX * centerT,
    centerY: midY + dirY * centerT,
    span: span[1] - span[0],
    rotationDeg: Math.atan2(-dirX, dirY) * 180 / Math.PI,
    peelSign: touchSide >= 0 ? 1 : -1,
    tilted: tilted,
  };
  return core;
}

/**
 * 计算当前拖拽状态下的折痕几何（含两侧裁剪路径，供 `clipShape` 用）。
 *
 * @param width 内容区宽（vp）
 * @param height 内容区高（vp）
 * @param touchX/touchY 手指按下点（vp，内容区坐标系）
 * @param dx/dy 相对按下点的累计位移（vp）
 */
export function curlFoldGeometry(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
): CurlFold {
  const core: FoldCore = foldCore(width, height, touchX, touchY, dx, dy);
  const front = rectHalfPlane(width, height, core.midX, core.midY, core.dirX, core.dirY, -core.peelSign);
  const peel = rectHalfPlane(width, height, core.midX, core.midY, core.dirX, core.dirY, core.peelSign);
  const fold: CurlFold = {
    dirX: core.dirX,
    dirY: core.dirY,
    midX: core.midX,
    midY: core.midY,
    centerX: core.centerX,
    centerY: core.centerY,
    span: core.span,
    rotationDeg: core.rotationDeg,
    peelSign: core.peelSign,
    tilted: core.tilted,
    frontPath: polygonPath(front),
    peelPath: polygonPath(peel),
  };
  return fold;
}

/** 折痕一侧的渐变带摆放参数（位置是带子的左上角，vp）。 */
export interface BandPlacement {
  x: number;
  y: number;
  width: number;
  length: number;
  rotationDeg: number;
}

/**
 * 把一条宽 `bandWidth` 的渐变带贴到折痕的一侧：
 * `onPeelSide = true` 贴在卷起那一侧（新页上，作投影），否则贴在当前页一侧（卷边/高光）。
 * 带子沿折痕方向摆放并按折痕角度旋转；`distanceVp` 是带子中心到折痕的垂直距离
 * （传 0 则默认取半个带宽，即内边缘正好贴住折痕）。
 */
export function bandPlacement(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
  bandWidth: number,
  onPeelSide: boolean,
  distanceVp: number,
): BandPlacement {
  const core: FoldCore = foldCore(width, height, touchX, touchY, dx, dy);
  // 折痕法线：cross(dir, n) = +1，所以 +n 是 peelSign 为正的那一侧
  const nx: number = -core.dirY;
  const ny: number = core.dirX;
  const sideSign: number = onPeelSide ? core.peelSign : -core.peelSign;
  const distance: number = distanceVp > 0 ? distanceVp : bandWidth / 2;
  const cx: number = core.centerX + nx * sideSign * distance;
  const cy: number = core.centerY + ny * sideSign * distance;
  // 带子比折痕段略长，旋转后两端仍能盖满折痕
  const length: number = core.span + bandWidth;
  const placement: BandPlacement = {
    x: cx - bandWidth / 2,
    y: cy - length / 2,
    width: bandWidth,
    length: length,
    rotationDeg: core.rotationDeg,
  };
  return placement;
}








/** 折痕曲线：直线弦的两个端点 + 凸向「当前页一侧」的二次贝塞尔控制点。 */
export interface FoldCurve {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
  /** 二次贝塞尔控制点：曲线中点位于弦的哪一侧由它决定。 */
  cx: number;
  cy: number;
  /** 弯曲幅度（vp）：弦中点到曲线中点的距离，0 表示直线折痕。 */
  bulge: number;
  /** 单位法线（指向 peel 侧）：偏移带子用。 */
  nx: number;
  ny: number;
  peelSign: number;
}

/**
 * 计算折痕曲线。
 *
 * 弦 = 折痕直线与页面矩形的交线段（用 foldCore 的跨度参数求出端点）；
 * 控制点取弦中点沿法线偏移 2*bulge、方向指向「当前页一侧」——二次贝塞尔的中点
 * 正好在控制点的一半处，所以曲线中点离弦的距离就是 bulge。
 */
export function foldCurveGeometry(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
): FoldCurve {
  const core: FoldCore = foldCore(width, height, touchX, touchY, dx, dy);
  const span: number[] = foldSpanParams(width, height, core.midX, core.midY, core.dirX, core.dirY);
  const x0: number = core.midX + core.dirX * span[0];
  const y0: number = core.midY + core.dirY * span[0];
  const x1: number = core.midX + core.dirX * span[1];
  const y1: number = core.midY + core.dirY * span[1];
  // 法线：cross(dir, n) = +1 ⇒ +n 是 peelSign 为正的一侧
  const nx: number = -core.dirY * core.peelSign;
  const ny: number = core.dirX * core.peelSign;
  const progress: number = Math.min(1, Math.abs(dx) / Math.max(1, width * BULGE_FULL_PROGRESS));
  const bulge: number = FOLD_BULGE_VP * progress;
  // 控制点沿 -n（当前页一侧）偏移：曲线中点凸向未卷走的一侧
  const mx: number = (x0 + x1) / 2;
  const my: number = (y0 + y1) / 2;
  const curve: FoldCurve = {
    x0: x0,
    y0: y0,
    x1: x1,
    y1: y1,
    cx: mx - nx * bulge * 2,
    cy: my - ny * bulge * 2,
    bulge: bulge,
    nx: nx,
    ny: ny,
    peelSign: core.peelSign,
  };
  return curve;
}

/**
 * 当前页可见区域的裁剪路径：先按弦裁半平面，再把落在弦上的那条直边换成二次贝塞尔。
 * 这样正文的裁切边界就是一条弯的折痕（纸张卷曲的关键），而不是直线。
 */
export function foldFrontPath(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
): string {
  const core: FoldCore = foldCore(width, height, touchX, touchY, dx, dy);
  const curve: FoldCurve = foldCurveGeometry(width, height, touchX, touchY, dx, dy);
  const poly: number[] = rectHalfPlane(width, height, core.midX, core.midY, core.dirX, core.dirY, -core.peelSign);
  // 找出多边形里落在弦上的两个点（sideOf ≈ 0），它们之间的直边要换成贝塞尔
  let firstOnLine: number = -1;
  let secondOnLine: number = -1;
  const count: number = poly.length / 2;
  for (let i = 0; i < count; i++) {
    const px: number = poly[i * 2];
    const py: number = poly[i * 2 + 1];
    if (Math.abs(sideOf(px, py, core.midX, core.midY, core.dirX, core.dirY)) < 0.5) {
      if (firstOnLine < 0) {
        firstOnLine = i;
      } else {
        secondOnLine = i;
      }
    }
  }
  if (firstOnLine < 0 || secondOnLine < 0 || curve.bulge <= 0.2) {
    return polygonPath(poly);
  }
  // 沿多边形顺序输出，把「弦上两点之间的那段直边」替换成 Q 曲线
  const fmt = (v: number): string => `${Math.round(v * 10) / 10}`;
  let path: string = '';
  let started: boolean = false;
  for (let step = 0; step <= count; step++) {
    const i: number = step % count;
    const px: number = poly[i * 2];
    const py: number = poly[i * 2 + 1];
    if (!started) {
      path += `M${fmt(px)} ${fmt(py)} `;
      started = true;
    } else {
      path += `L${fmt(px)} ${fmt(py)} `;
    }
    if (i === firstOnLine) {
      // 从弦上第一点起，用贝塞尔画到弦上第二点
      path += `Q${fmt(curve.cx)} ${fmt(curve.cy)} ${fmt(poly[secondOnLine * 2])} ${fmt(poly[secondOnLine * 2 + 1])} `;
      // 跳过中间被替代的顶点
      step = secondOnLine - 1;
      if (step < i) {
        break;
      }
    }
  }
  return `${path}Z`;
}

/** 折痕渐变带的一小段（用短直带拼出曲线带，避免依赖 Canvas 绘制）。 */
export interface FoldBandSegment {
  /** 段的左上角（vp）。 */
  x: number;
  y: number;
  width: number;
  length: number;
  /** 该段的倾角（度）。 */
  rotationDeg: number;
  /** 配色标记：0 = 投影（peel 侧），1 = 卷边柱面（当前页侧），2 = 柱面高光。 */
  kind: number;
}

/**
 * 把「沿折痕曲线、贴在一侧的渐变带」拆成若干短直段。
 *
 * 曲线用二次贝塞尔采样：第 i 段取相邻两个采样点，段心偏离折痕 `distanceVp`（沿法线、指向
 * `onPeelSide` 决定的一侧），段长按两点距离，段倾角按两点连线方向 —— 这样曲线带由短直段拼出，
 * 不需要 Canvas，也不会因为曲线而让阴影/卷边与折痕错位。
 */
export function foldBandSegments(
  width: number,
  height: number,
  touchX: number,
  touchY: number,
  dx: number,
  dy: number,
  bandWidth: number,
  onPeelSide: boolean,
  distanceVp: number,
  kind: number,
  segments: number,
): FoldBandSegment[] {
  const curve: FoldCurve = foldCurveGeometry(width, height, touchX, touchY, dx, dy);
  const side: number = onPeelSide ? curve.peelSign : -curve.peelSign;
  const nx: number = curve.nx * side;
  const ny: number = curve.ny * side;
  const out: FoldBandSegment[] = [];
  const step: number = 1 / Math.max(1, segments);
  for (let i = 0; i < segments; i++) {
    const t0: number = i * step;
    const t1: number = (i + 1) * step;
    const x0: number = bezierAt(curve.x0, curve.cx, curve.x1, t0);
    const y0: number = bezierAt(curve.y0, curve.cy, curve.y1, t0);
    const x1: number = bezierAt(curve.x0, curve.cx, curve.x1, t1);
    const y1: number = bezierAt(curve.y0, curve.cy, curve.y1, t1);
    const midX: number = (x0 + x1) / 2 + nx * distanceVp;
    const midY: number = (y0 + y1) / 2 + ny * distanceVp;
    const segLen: number = Math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0)) + 2;
    // 段的方向：把竖直带（长轴沿 y）转到两点连线方向
    const rotation: number = Math.atan2(-(x1 - x0), y1 - y0) * 180 / Math.PI;
    out.push({
      x: midX - bandWidth / 2,
      y: midY - segLen / 2,
      width: bandWidth,
      length: segLen,
      rotationDeg: rotation,
      kind: kind,
    });
  }
  return out;
}

/** 二次贝塞尔单点求值。 */
function bezierAt(p0: number, c: number, p1: number, t: number): number {
  const u: number = 1 - t;
  return u * u * p0 + 2 * u * t * c + t * t * p1;
}
