import { TalebookCoreService } from './TalebookCoreService';

/**
 * 人机验证（captcha）API —— talebook 上游专有，mybooks 无对应端点。
 *
 * 端点核对依据：docs/talebook/webserver/handlers/captcha.py::routes()
 *   GET  /api/captcha/config → CaptchaConfigHandler.get（未启用时为 `config: null`；启用时含 provider/enabled/scenes）
 *   GET  /api/captcha/image  → CaptchaImageHandler.get（返回 `image`（`data:image/png;base64,...`）与 `captcha_id`，
 *                              同时以 secure cookie `captcha_answer` 记录答案，2 分钟过期）
 *   POST /api/captcha/verify → CaptchaVerifyHandler.post（form：`provider` + `captcha_code`；失败返回
 *                              `captcha.invalid` / `captcha.expired`）
 *
 * 校验字段核对依据：docs/talebook/webserver/handlers/user.py::check_captcha
 *   `/api/user/sign_in`、`/api/user/sign_up`、`/api/user/reset`、`/api/welcome` 均通过
 *   `get_argument("captcha_code")` 取值并直接与 cookie 中的答案比对 —— 因此客户端只需在
 *   **表单体**里追加 `captcha_code`（大写），无需额外凭据。
 *
 * 场景开关核对依据：docs/talebook/app/components/... 与 plugins/captcha/__init__.get_captcha_config
 *   `scenes = { register, login, welcome, reset }`，对应 settings.py 的 `CAPTCHA_ENABLE_FOR_*`。
 */

/** 场景名：登录。 */
export const CAPTCHA_SCENE_LOGIN: string = 'login';
/** 场景名：注册。 */
export const CAPTCHA_SCENE_REGISTER: string = 'register';
/** 场景名：重置密码。 */
export const CAPTCHA_SCENE_RESET: string = 'reset';
/** 场景名：访问码（上游 `/api/welcome`，客户端当前未调用该端点）。 */
export const CAPTCHA_SCENE_WELCOME: string = 'welcome';

/** 图形验证码 provider 名（plugins/captcha/image_captcha.py::ImageCaptchaProvider.name）。 */
export const CAPTCHA_PROVIDER_IMAGE: string = 'image';

/** 各场景的启用开关（上游 `config.scenes`）。 */
export interface CaptchaScenes {
  login: boolean;
  register: boolean;
  reset: boolean;
  welcome: boolean;
}

/** 验证码配置（上游 `config`；未启用时上游整体返回 null）。 */
export interface CaptchaConfig {
  /** 当前 provider：`image`（图形）或 `geetest`（极验）。 */
  provider: string;
  captchaId: string;
  sdkUrl: string;
  enabled: boolean;
  scenes: CaptchaScenes;
}

/** 验证码图片（上游 `/api/captcha/image` 响应）。 */
export interface CaptchaImage {
  /** `data:image/png;base64,...`，可直接交给 ArkUI `Image` 渲染。 */
  image: string;
  captchaId: string;
}

function asString(value: Object | undefined | null, fallback: string = ''): string {
  if (value === undefined || value === null) {
    return fallback;
  }
  const text = String(value);
  return text === 'undefined' || text === 'null' ? fallback : text;
}

function asBoolean(value: Object | undefined | null, fallback: boolean): boolean {
  if (value === undefined || value === null) {
    return fallback;
  }
  return String(value).toLowerCase() === 'true';
}

function isMissing(value: Object | undefined | null): boolean {
  return value === undefined || value === null;
}

/** `{err, msg}` 约定：err 为空或 `ok` 视为成功。 */
function isOk(err: string): boolean {
  return err.length === 0 || err === 'ok';
}

function envelopeOf(raw: string): Record<string, Object> {
  try {
    return JSON.parse(raw) as Record<string, Object>;
  } catch (_error) {
    throw new Error('验证码接口返回的响应无法解析');
  }
}

/** 解析响应并校验 `{err, msg}`；失败时抛出带服务端提示的错误。 */
function ensureOk(raw: string): Record<string, Object> {
  const parsed = envelopeOf(raw);
  const err = asString(parsed['err']);
  if (!isOk(err)) {
    throw new Error(asString(parsed['msg'], err));
  }
  return parsed;
}

function parseScenes(raw: Object | undefined): CaptchaScenes {
  if (isMissing(raw)) {
    return { login: false, register: false, reset: false, welcome: false };
  }
  const node = raw as Record<string, Object>;
  return {
    login: asBoolean(node[CAPTCHA_SCENE_LOGIN], false),
    register: asBoolean(node[CAPTCHA_SCENE_REGISTER], false),
    reset: asBoolean(node[CAPTCHA_SCENE_RESET], false),
    welcome: asBoolean(node[CAPTCHA_SCENE_WELCOME], false),
  };
}

/** 读取指定场景的开关；未知场景按未启用处理。 */
function sceneEnabled(scenes: CaptchaScenes, scene: string): boolean {
  if (scene === CAPTCHA_SCENE_LOGIN) {
    return scenes.login;
  }
  if (scene === CAPTCHA_SCENE_REGISTER) {
    return scenes.register;
  }
  if (scene === CAPTCHA_SCENE_RESET) {
    return scenes.reset;
  }
  if (scene === CAPTCHA_SCENE_WELCOME) {
    return scenes.welcome;
  }
  return false;
}

/** 错误对象 → 提示文案（与页面既有写法一致）。 */
export function captchaErrorMessage(error: Object): string {
  return error instanceof Error ? error.message : `${error}`;
}

export class CaptchaApi {
  /**
   * GET /api/captcha/config —— 查询验证码配置（是否启用、类型、各场景开关）。
   *
   * 上游未配置 `CAPTCHA_PROVIDER`（或 provider 配置不完整）时返回 `config: null`，这里映射为 null。
   */
  static async getConfig(): Promise<CaptchaConfig | null> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/captcha/config'));
    const node = parsed['config'];
    if (isMissing(node)) {
      return null;
    }
    const raw = node as Record<string, Object>;
    return {
      provider: asString(raw['provider']),
      captchaId: asString(raw['captchaId']),
      sdkUrl: asString(raw['sdkUrl']),
      enabled: asBoolean(raw['enabled'], false),
      scenes: parseScenes(raw['scenes']),
    };
  }

  /**
   * GET /api/captcha/image —— 取一张新的图形验证码。
   *
   * 图片由服务端内联为 base64 data URL（无需二次鉴权下载，区别于 AuthImage 的封面下载路径）；
   * 正确答案随响应的 secure cookie 下发，客户端不持有明文答案。
   */
  static async fetchImage(): Promise<CaptchaImage> {
    const parsed = ensureOk(await TalebookCoreService.talebookGet('/api/captcha/image'));
    const image = asString(parsed['image']);
    if (image.length === 0) {
      throw new Error('验证码图片为空，请刷新重试');
    }
    return {
      image: image,
      captchaId: asString(parsed['captcha_id']),
    };
  }

  /**
   * POST /api/captcha/verify —— 校验用户输入的验证码。
   *
   * 上游要求 form 参数 `provider=image` 与 `captcha_code`，且大小写不敏感（服务端会 upper 后比对）；
   * 这里与 Web 端 ImageCaptchaWidget 一致，提交前统一转大写。
   * 校验成功后 cookie 保留，供随后的表单提交（`check_captcha`）再次比对，因此这里只做前置反馈。
   *
   * @throws 校验失败（`captcha.invalid`）或已过期（`captcha.expired`）时抛出带 msg 的错误。
   */
  static async verify(captchaCode: string): Promise<void> {
    const form = `provider=${CAPTCHA_PROVIDER_IMAGE}` +
      `&captcha_code=${encodeURIComponent(captchaCode.trim().toUpperCase())}`;
    ensureOk(await TalebookCoreService.talebookPostForm('/api/captcha/verify', form));
  }

  /**
   * 该场景是否需要图形验证码。
   *
   * 仅当 provider 为 `image` 时返回 true：极验（geetest）需要其浏览器 JS SDK，客户端通道无法完成，
   * 此时按「未启用」处理（提交表单时不带 `captcha_code`），由服务端返回 `captcha.invalid`
   * 及「请完成人机验证」提示，不会静默放过。
   * 配置请求失败同样返回 false（服务端仍会校验），避免因网络抖动阻断登录流程。
   */
  static async isEnabled(scene: string): Promise<boolean> {
    try {
      const config = await CaptchaApi.getConfig();
      if (config === null || !config.enabled || config.provider !== CAPTCHA_PROVIDER_IMAGE) {
        return false;
      }
      return sceneEnabled(config.scenes, scene);
    } catch (_error) {
      return false;
    }
  }
}
