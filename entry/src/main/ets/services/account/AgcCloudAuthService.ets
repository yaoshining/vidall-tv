import { common } from '@kit.AbilityKit';
import { cloudCommon } from '@kit.CloudFoundationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import buffer from '@ohos.buffer';
import auth, { AuthUser, HwIdCredentialInfo, SignInParam } from '@hw-agconnect/auth';

const AGC_CONFIG_FILE: string = 'agconnect-services.json';
const CLOUD_DB_SCHEMA_FILE: string = 'schema.json';
const LOG_DOMAIN: number = 0x0000;
const TAG: string = 'AgcCloudAuth';
export const ERROR_AGC_NOT_INITIALIZED: number = 10001;
const ERROR_SESSION_MISSING: number = 10002;
const ERROR_AUTHENTICATION_FAILED: number = 10003;

export class AgcAuthenticationError extends Error implements BusinessError {
  code: number;

  constructor(code: number, message: string) {
    super(message);
    this.name = 'AgcAuthenticationError';
    this.code = code;
  }
}

export class AgcCloudAuthService {
  private static instance: AgcCloudAuthService = new AgcCloudAuthService();
  private initialized: boolean = false;

  static getInstance(): AgcCloudAuthService {
    return AgcCloudAuthService.instance;
  }

  initialize(context: common.Context): void {
    const configData: Uint8Array = context.resourceManager.getRawFileContentSync(AGC_CONFIG_FILE);
    const configJson: string = buffer.from(configData.buffer).toString('utf-8');
    auth.init(context, configJson);
    this.initialized = true;
  }

  async authenticateHuaweiAccount(): Promise<void> {
    if (!this.initialized) {
      throw new AgcAuthenticationError(ERROR_AGC_NOT_INITIALIZED, 'AGC Authentication 尚未初始化');
    }

    const credentialInfo: HwIdCredentialInfo = { kind: 'hwid' };
    const signInParam: SignInParam = {
      autoCreateUser: true,
      credentialInfo
    };
    hilog.info(LOG_DOMAIN, TAG, 'AGC 华为账号认证开始');
    try {
      let currentUser: AuthUser | null = await auth.getCurrentUser();
      if (currentUser === null) {
        await auth.signIn(signInParam);
        currentUser = await auth.getCurrentUser();
      } else {
        hilog.info(LOG_DOMAIN, TAG, '复用已有 AGC 用户会话继续登录流程');
      }
      if (currentUser === null) {
        hilog.error(LOG_DOMAIN, TAG, 'AGC signIn 返回成功但当前用户为空');
        throw new AgcAuthenticationError(ERROR_SESSION_MISSING, 'AGC Authentication 未建立用户会话');
      }

      await currentUser.getToken(false);
      hilog.info(LOG_DOMAIN, TAG, 'AGC 用户会话及访问令牌验证成功');

      const options: cloudCommon.CloudOptions = {
        region: cloudCommon.CloudRegion.CHINA,
        authProvider: auth.getAuthProvider(),
        databaseOptions: {
          schema: CLOUD_DB_SCHEMA_FILE
        }
      };
      cloudCommon.init(options);
      hilog.info(LOG_DOMAIN, TAG, 'Cloud Foundation 认证上下文初始化成功');
    } catch (e) {
      const error = e as BusinessError;
      const errorCode: number = typeof error.code === 'number' ? error.code : ERROR_AUTHENTICATION_FAILED;
      const errorMessage: string = error.message ?? 'AGC Authentication 失败';
      hilog.error(LOG_DOMAIN, TAG, 'AGC 华为账号认证失败 code=%{public}d message=%{public}s',
        errorCode, errorMessage);
      throw new AgcAuthenticationError(errorCode, errorMessage);
    }
  }

  async signOut(): Promise<void> {
    if (!this.initialized) {
      return;
    }
    try {
      await auth.signOut();
    } catch (e) {
      const error = e as BusinessError;
      console.error(`AGC Authentication 退出失败: ${error.code} ${error.message}`);
    }
  }
}
