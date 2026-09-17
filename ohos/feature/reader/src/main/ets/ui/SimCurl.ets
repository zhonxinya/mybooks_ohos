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







