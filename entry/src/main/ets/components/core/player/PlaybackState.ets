/**
 * 播放器显式状态机枚举。
 *
 * 用于把 VideoPlayerController 中由多个布尔字段（isReady / isPlaying / isSeeking /
 * isLoading / hasPrepared）隐式表达的播放会话生命周期，收敛为单一状态来源。
 */
export enum PlaybackState {
  /** 无播放（初始 / release 后） */
  IDLE = 'idle',
  /** 初始化中，正在做音频路由决策（resolveAudioRoutingDecision） */
  ROUTING = 'routing',
  /** 适配器已创建、正在 load source、等待 prepare 完成 */
  PREPARING = 'preparing',
  /** prepare 完成（onPlayerReady） */
  PREPARED = 'prepared',
  /** 播放中 */
  PLAYING = 'playing',
  /** 已暂停 */
  PAUSED = 'paused',
  /** seek 中（含续播 seek） */
  SEEKING = 'seeking',
  /** 终端错误（handleTerminalPlayerError） */
  ERROR = 'error',
  /** 释放中（release） */
  RELEASING = 'releasing'
}
