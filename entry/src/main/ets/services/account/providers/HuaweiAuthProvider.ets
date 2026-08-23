import { authentication, loginComponentManager } from '@kit.AccountKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import buffer from '@ohos.buffer';
import { AuthProvider, PlatformIdentity } from '../AuthProvider';

export class HuaweiCredentialEmptyError extends Error {
  readonly code: number = 1001502999;

  constructor() {
    super('华为登录未返回凭据');
    this.name = 'HuaweiCredentialEmptyError';
  }
}

/**
 * idToken（JWT）payload 中关注的 claims
 */
interface IdTokenClaims {
  name: string;
  picture: string;
}

/**
 * 华为账号认证 provider（首发实现）
 *
 * 使用系统组件 `LoginWithHuaweiIDButton` 拉起授权：
 * - UI 调用 `getController()` 取 controller 渲染按钮
 * - `login()` 在 controller 上注册 `onClickLoginWithHuaweiIDButton` 回调并封装为 Promise
 * - 用户点击按钮 → 华为授权页 → 回调拿到 `HuaweiIDCredential`（含 unionID）
 * - 从 unionID 作为 platformUserId；idToken 尝试解码取 name/picture，无则空字符串
 *
 * 华为侧无显式 signOut API，`signOut()` 为空实现；本地态清理由 AccountService 负责。
 */
export class HuaweiAuthProvider implements AuthProvider {
  readonly providerId: string = 'huawei';
  readonly displayName: string = '华为账号';
  private controller: loginComponentManager.LoginWithHuaweiIDButtonController =
    new loginComponentManager.LoginWithHuaweiIDButtonController();
  private authorizationContext: common.UIAbilityContext | undefined;

  setAuthorizationContext(context: common.UIAbilityContext): void {
    this.authorizationContext = context;
  }

  login(): Promise<PlatformIdentity> {
    return new Promise<PlatformIdentity>((resolve, reject) => {
      this.controller.onClickLoginWithHuaweiIDButton(
        (err: BusinessError, data: loginComponentManager.HuaweiIDCredential) => {
          if (err && err.code !== 0) {
            this.authorizationContext = undefined;
            reject(err);
            return;
          }
          if (data) {
            void this.resolveIdentity(data, resolve);
            return;
          }
          this.authorizationContext = undefined;
          reject(new HuaweiCredentialEmptyError());
        }
      );
    });
  }

  async signOut(): Promise<void> {
    // 华为侧无显式 signOut API；不调用 CancelAuthorizationRequest（保留给未来「解绑授权」功能）
  }

  /** 供 UI 渲染 `LoginWithHuaweiIDButton` 时传入的 controller */
  getController(): loginComponentManager.LoginWithHuaweiIDButtonController {
    return this.controller;
  }

  private async resolveIdentity(cred: loginComponentManager.HuaweiIDCredential,
    resolve: (identity: PlatformIdentity) => void): Promise<void> {
    const identity: PlatformIdentity = this.buildIdentity(cred);
    try {
      if (identity.displayName === undefined || identity.avatarUri === undefined) {
        await this.enrichWithProfile(identity);
      }
    } catch (e) {
      const error = e as BusinessError;
      console.warn(`[HuaweiAuthProvider] 资料授权未完成 code=${error.code ?? -1}`);
    } finally {
      this.authorizationContext = undefined;
      resolve(identity);
    }
  }

  private async enrichWithProfile(identity: PlatformIdentity): Promise<void> {
    const context: common.UIAbilityContext | undefined = this.authorizationContext;
    if (context === undefined) {
      return;
    }
    const huaweiIDProvider: authentication.HuaweiIDProvider = new authentication.HuaweiIDProvider();
    const request: authentication.AuthorizationWithHuaweiIDRequest =
      huaweiIDProvider.createAuthorizationWithHuaweiIDRequest();
    request.scopes = ['profile'];
    const controller: authentication.AuthenticationController =
      new authentication.AuthenticationController(context);
    const response: authentication.AuthenticationResponse = await controller.executeRequest(request);
    const huaweiResponse: authentication.AuthorizationWithHuaweiIDResponse =
      response as authentication.AuthorizationWithHuaweiIDResponse;
    const credential: authentication.AuthorizationWithHuaweiIDCredential | undefined = huaweiResponse.data;
    if (credential === undefined) {
      return;
    }
    if (identity.displayName === undefined && credential.nickName !== undefined && credential.nickName.length > 0) {
      identity.displayName = credential.nickName;
    }
    if (identity.avatarUri === undefined && credential.avatarUri !== undefined && credential.avatarUri.length > 0) {
      identity.avatarUri = credential.avatarUri;
    }
  }

  private buildIdentity(cred: loginComponentManager.HuaweiIDCredential): PlatformIdentity {
    const raw: Map<string, string> = new Map<string, string>();
    raw.set('authorizationCode', cred.authorizationCode);
    const idToken: string | undefined = cred.idToken;
    if (idToken !== undefined && idToken.length > 0) {
      raw.set('idToken', idToken);
    }
    const claims: IdTokenClaims = this.decodeIdTokenClaims(idToken);
    const identity: PlatformIdentity = {
      platformUserId: cred.unionID,
      openID: cred.openID,
      displayName: claims.name.length > 0 ? claims.name : undefined,
      avatarUri: claims.picture.length > 0 ? claims.picture : undefined,
      raw
    };
    return identity;
  }

  private decodeIdTokenClaims(idToken: string | undefined): IdTokenClaims {
    const empty: IdTokenClaims = { name: '', picture: '' };
    if (!idToken || idToken.length === 0) {
      return empty;
    }
    try {
      const parts: string[] = idToken.split('.');
      if (parts.length < 2) {
        return empty;
      }
      const payloadB64: string = parts[1];
      // base64url → base64
      const b64: string = payloadB64.replace(/-/g, '+').replace(/_/g, '/');
      const padLen: number = (4 - b64.length % 4) % 4;
      const padded: string = b64 + '='.repeat(padLen);
      const json: string = buffer.from(padded, 'base64').toString('utf-8');
      const claims = JSON.parse(json) as Record<string, string>;
      const result: IdTokenClaims = {
        name: claims['name'] || '',
        picture: claims['picture'] || ''
      };
      return result;
    } catch {
      return empty;
    }
  }
}
