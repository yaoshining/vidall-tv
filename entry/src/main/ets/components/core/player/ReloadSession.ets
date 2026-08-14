/**
 * 源重载（reload）事务。
 *
 * 把 VideoPlayerController 中散落的 reload 状态（pendingReloadToken / activeReloadToken /
 * reloadTimeoutId / pendingReloadResolve / pendingReloadReject）收敛为单一对象。
 *
 * 语义保持与原实现一致：
 * - `begin` 生成新 token 并创建等待 Promise + 超时定时器；
 * - 只有「当前活跃 token」对应的超时才会触发 reject（旧 token 的超时被跳过）。
 */
export class ReloadSession {
  private pendingToken: number = 0;
  private activeToken: number = 0;
  private timeoutId?: number;
  private pendingResolve?: () => void;
  private pendingReject?: (error: Error) => void;

  /**
   * 开始一次 reload：token +1，登记 resolve/reject，并启动超时兜底。
   * @param resolve 与 initPlayer 完成后的 resolvePendingReload 对应
   * @param reject  与错误/超时/被取代时的 rejectPendingReload 对应
   */
  begin(resolve: () => void, reject: (error: Error) => void, timeoutMs: number = 15000): void {
    this.pendingToken += 1;
    const token = this.pendingToken;
    this.activeToken = token;
    this.pendingResolve = resolve;
    this.pendingReject = reject;
    this.timeoutId = setTimeout(() => {
      // 仅当本次 token 仍是活跃 token 时才触发超时，旧 token 的超时被跳过（与原语义一致）。
      if (token !== this.activeToken) {
        return;
      }
      this.rejectPending(new Error('reloadSource prepared timeout'));
    }, timeoutMs);
  }

  private clear(): void {
    if (this.timeoutId !== undefined) {
      clearTimeout(this.timeoutId);
      this.timeoutId = undefined;
    }
    this.pendingResolve = undefined;
    this.pendingReject = undefined;
  }

  resolvePending(): void {
    const resolve = this.pendingResolve;
    this.clear();
    if (resolve !== undefined) {
      resolve();
    }
  }

  rejectPending(error: Error): void {
    const reject = this.pendingReject;
    this.clear();
    if (reject !== undefined) {
      reject(error);
    }
  }
}
