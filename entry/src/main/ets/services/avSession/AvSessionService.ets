import { avSession as AVSessionManager } from '@kit.AVSessionKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG = '[AvSessionService]';
const DOMAIN = 0x0000;

/**
 * 小艺语音 / 智慧屏遥控器 / 系统媒体中心可下发的媒体控制命令。
 * 小艺说「播放」「暂停」「继续播放」「停止播放」「快进到 xx」等，
 * 系统会转成以下命令下发到当前激活的 AVSession。
 */
export type AvSessionCommand = 'play' | 'pause' | 'stop' | 'seek' | 'setSpeed';

/** AVSession 状态快照，由宿主页面从 VideoPlayerController 实时读取 */
export interface AvSessionSyncState {
  /** 当前媒体标题（用于系统播控卡片展示） */
  title: string;
  playing: boolean;
  buffering: boolean;
  positionMs: number;
  durationMs: number;
  speed: number;
  /** 媒体封面：PixelMap 或本地图片 URI（file://），用于系统媒体中心展示 */
  mediaImage?: image.PixelMap | string;
}

export interface AvSessionServiceOptions {
  /** 用于创建 AVSession 的上下文（UIAbilityContext / common.Context） */
  context: common.Context;
  /** 会话标签，展示在系统播控中的应用名 */
  tag: string;
  /** 命令回调：cmd + 可选参数（seek 为毫秒、setSpeed 为倍速） */
  onCommand: (cmd: AvSessionCommand, args?: number) => void;
  /** 实时读取播放器状态快照（宿主页面从 controller 读取） */
  getState: () => AvSessionSyncState;
  /** 播放状态同步周期（ms），默认 1000 */
  syncIntervalMs?: number;
}

/**
 * AVSession Provider 封装：
 * 1. 创建并激活 AVSession（应用作为媒体会话提供方）；
 * 2. 注册 play/pause/stop/seek/setSpeed 命令监听 —— 小艺语音、遥控器、
 *    系统媒体中心下发的控制命令都通过这里到达应用；
 * 3. 周期性把标题、时长、播放状态/进度同步到系统，供播控卡片展示。
 *
 * 一个 UIAbility 只能创建一个 AVSession，且会话需在播放期间保持存活，
 * 因此本服务生命周期跟随 PlayerPage（aboutToAppear 创建 / aboutToDisappear 销毁）。
 */
export class AvSessionService {
  private session: AVSessionManager.AVSession | undefined;
  private readonly options: AvSessionServiceOptions;
  private syncTimer: number | undefined;
  private lastStateKey: string = '';
  private lastMetadataKey: string = '';
  private destroyed: boolean = false;

  constructor(options: AvSessionServiceOptions) {
    this.options = options;
  }

  /** 创建并激活 AVSession，注册命令监听。返回是否成功。 */
  async init(): Promise<boolean> {
    if (this.session) {
      return true;
    }
    try {
      const type: AVSessionManager.AVSessionType = 'video';
      const session = await AVSessionManager.createAVSession(this.options.context, this.options.tag, type);
      this.session = session;
      await session.activate();
      this.registerCommandListeners();
      this.setLaunchAbility();
      // 首次立即同步，避免播控中心等待一个周期
      this.syncMetadataIfChanged(true);
      this.syncPlaybackState(true);
      this.startSyncTimer();
      hilog.info(DOMAIN, TAG, 'AVSession created & activated: %{public}s', session.sessionId);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'createAVSession failed: code=%{public}s msg=%{public}s',
        String(e.code), e.message ?? String(e));
      this.session = undefined;
      return false;
    }
  }

  /**
   * 销毁会话（页面退出时调用）。
   * 取消命令监听并销毁会话；静默失败，不抛异常。
   */
  async destroy(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    this.destroyed = true;
    this.stopSyncTimer();
    const session = this.session;
    this.session = undefined;
    if (!session) {
      return;
    }
    try {
      session.off('play');
      session.off('pause');
      session.off('stop');
      session.off('seek');
      session.off('setSpeed');
      await session.destroy();
      hilog.info(DOMAIN, TAG, 'AVSession destroyed');
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'destroy AVSession failed: %{public}s', e.message ?? String(e));
    }
  }

  /** 立即刷新元数据（标题/时长变化时由宿主调用，如切换剧集后） */
  refreshMetadata(): void {
    this.syncMetadataIfChanged(true);
  }

  /** 立即刷新播放状态（播放/暂停事件时由宿主调用） */
  refreshPlaybackState(): void {
    this.syncPlaybackState(true);
  }

  // ─── 命令监听 ──────────────────────────────────────────────

  /**
   * 注册固定播放控制命令监听。
   * 注册后命令会出现在系统播控 getValidCommands() 中，
   * 小艺语音「播放/暂停/停止」「进度跳转」「倍速」等即可命中。
   */
  private registerCommandListeners(): void {
    const session = this.session;
    if (!session) {
      return;
    }
    try {
      session.on('play', () => {
        hilog.info(DOMAIN, TAG, 'AVSession command: play');
        this.options.onCommand('play');
      });
      session.on('pause', () => {
        hilog.info(DOMAIN, TAG, 'AVSession command: pause');
        this.options.onCommand('pause');
      });
      session.on('stop', () => {
        hilog.info(DOMAIN, TAG, 'AVSession command: stop');
        this.options.onCommand('stop');
      });
      session.on('seek', (time: number) => {
        hilog.info(DOMAIN, TAG, 'AVSession command: seek %{public}dms', time);
        this.options.onCommand('seek', time);
      });
      session.on('setSpeed', (speed: number) => {
        hilog.info(DOMAIN, TAG, 'AVSession command: setSpeed %{public}f', speed);
        this.options.onCommand('setSpeed', speed);
      });
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'registerCommandListeners failed: %{public}s', e.message ?? String(e));
    }
  }

  /**
   * 设置点击系统播控卡片时的拉起目标（应用主页）。
   * 失败不阻塞会话创建，仅记录日志。
   */
  private setLaunchAbility(): void {
    const session = this.session;
    if (!session) {
      return;
    }
    try {
      const bundleName = this.options.context.applicationInfo.name;
      const wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [
          {
            bundleName: bundleName,
            abilityName: 'EntryAbility'
          }
        ],
        operationType: wantAgent.OperationType.START_ABILITIES,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      wantAgent.getWantAgent(wantAgentInfo).then((agent) => {
        session.setLaunchAbility(agent).catch((err: BusinessError) => {
          hilog.warn(DOMAIN, TAG, 'setLaunchAbility failed: %{public}s', err.message ?? String(err));
        });
      }).catch((err: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'getWantAgent failed: %{public}s', err.message ?? String(err));
      });
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setLaunchAbility exception: %{public}s', e.message ?? String(e));
    }
  }

  // ─── 状态同步 ──────────────────────────────────────────────

  private startSyncTimer(): void {
    this.stopSyncTimer();
    const interval = this.options.syncIntervalMs ?? 1000;
    this.syncTimer = setInterval(() => {
      if (this.destroyed || !this.session) {
        return;
      }
      this.syncMetadataIfChanged(false);
      this.syncPlaybackState(false);
    }, interval);
  }

  private stopSyncTimer(): void {
    if (this.syncTimer !== undefined) {
      clearInterval(this.syncTimer);
      this.syncTimer = undefined;
    }
  }

  /** 标题/时长/封面变化时才写元数据（setAVMetadata 属于 IPC，需去重） */
  private syncMetadataIfChanged(force: boolean): void {
    const s = this.options.getState();
    const key = `${s.title}|${Math.round(s.durationMs)}|${this.mediaImageKey(s.mediaImage)}`;
    if (!force && key === this.lastMetadataKey) {
      return;
    }
    this.lastMetadataKey = key;
    this.syncMetadataNow(s);
  }

  /**
   * mediaImage 的去重标识：
   * - string（本地 URI）：直接用字符串
   * - PixelMap：无法字符串化，用固定标记；宿主在替换封面后调用 refreshMetadata() 强制刷新
   */
  private mediaImageKey(mediaImage: image.PixelMap | string | undefined): string {
    if (mediaImage === undefined) {
      return '';
    }
    if (typeof mediaImage === 'string') {
      return mediaImage;
    }
    return 'pixelmap';
  }

  private syncMetadataNow(s: AvSessionSyncState): void {
    const session = this.session;
    if (!session) {
      return;
    }
    const metadata: AVSessionManager.AVMetadata = {
      assetId: 'vidall-current',
      title: s.title.length > 0 ? s.title : this.options.tag,
      duration: Math.max(0, Math.round(s.durationMs))
    };
    if (s.mediaImage !== undefined) {
      metadata.mediaImage = s.mediaImage;
    }
    session.setAVMetadata(metadata).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVMetadata failed: %{public}s', err.message ?? String(err));
    });
  }

  /** 播放状态/进度变化时才写（position 单位 ms） */
  private syncPlaybackState(force: boolean): void {
    const session = this.session;
    if (!session) {
      return;
    }
    const s = this.options.getState();
    let state: AVSessionManager.PlaybackState;
    if (s.playing) {
      state = s.buffering
        ? AVSessionManager.PlaybackState.PLAYBACK_STATE_BUFFERING
        : AVSessionManager.PlaybackState.PLAYBACK_STATE_PLAY;
    } else {
      state = AVSessionManager.PlaybackState.PLAYBACK_STATE_PAUSE;
    }
    const key = `${state}|${Math.round(s.positionMs)}|${s.speed}`;
    if (!force && key === this.lastStateKey) {
      return;
    }
    this.lastStateKey = key;
    const playbackState: AVSessionManager.AVPlaybackState = {
      state: state,
      position: {
        elapsedTime: Math.max(0, Math.round(s.positionMs)),
        updateTime: Date.now()
      },
      speed: s.speed > 0 ? s.speed : 1.0
    };
    session.setAVPlaybackState(playbackState).catch((err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'setAVPlaybackState failed: %{public}s', err.message ?? String(err));
    });
  }
}
