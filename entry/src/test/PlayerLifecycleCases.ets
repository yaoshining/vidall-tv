import { VideoPlayerController, PlayerBackend, AudioTrackItem } from '../main/ets/components/core/player/VideoPlayerController';
import { IPlayer, TrackInfo, SubtitleInfo } from '../main/ets/components/core/player/IPlayer';
import { VideoData } from '../main/ets/components/core/player/VideoData';
import { VideoDataType } from '../main/ets/components/core/player/Constants';
import { PlaybackBackendDecision, buildDefaultBackendDecision } from '../main/ets/services/playback/PlaybackBackendTypes';

class Gate {
  private complete: () => void = (): void => {};
  readonly promise: Promise<void> = new Promise<void>((resolve) => { this.complete = resolve; });
  open(): void { this.complete(); }
}
interface RoutingBoundary { chooseBackend(video: VideoData): Promise<PlaybackBackendDecision>; }
class Routing implements RoutingBoundary {
  gate?: Gate;
  async chooseBackend(_video: VideoData): Promise<PlaybackBackendDecision> {
    if (this.gate) { await this.gate.promise; }
    return buildDefaultBackendDecision();
  }
}
interface Access {
  player?: IPlayer;
  backendService: RoutingBoundary;
  audioTracks: AudioTrackItem[];
  isPlaying: boolean;
}
function access(controller: VideoPlayerController): Access { return controller as Object as Access; }
function check(value: boolean, message: string): void { if (!value) { throw new Error(message); } }
function source(name: string): VideoData { return { type: VideoDataType.URL, videoSrc: 'https://example.test/' + name, name }; }
async function settle(): Promise<void> { for (let i = 0; i < 20; i++) { await Promise.resolve(); } }
class LifecyclePlayer implements IPlayer {
  duration: number = 2_684_598
  currentTime: number = 500_762
  seekCalls: number[] = []
  playCallCount: number = 0

  init(_videoData: VideoData, _surfaceId: string): Promise<void> { return Promise.resolve() }
  play(): Promise<void> {
    this.playCallCount += 1
    return Promise.resolve()
  }
  async pause(): Promise<void> { if (this.pauseGate) { await this.pauseGate.promise; } }
  toggle(): Promise<void> { return Promise.resolve() }
  releases: number = 0
  releaseGate?: Gate
  pauseGate?: Gate
  selected: number[] = []
  async release(): Promise<void> { this.releases++; if (this.releaseGate) { await this.releaseGate.promise; } }
  seek(timeMs: number): void {
    this.seekCalls.push(timeMs)
  }
  forward(_milliseconds: number): Promise<void> { return Promise.resolve() }
  backward(_milliseconds: number): Promise<void> { return Promise.resolve() }
  getTrackInfos(): Promise<TrackInfo[]> { return Promise.resolve([]) }
  selectTrack(trackIndex: number): Promise<void> { this.selected.push(trackIndex); return Promise.resolve() }
  setSubtitleDelay(_delayMs: number): void {}
  setPlaybackSpeed(_speed: number): void {}
  setPropertyString(_property: string, _value: string): void {}
  onReady(_callback: () => void): void {}
  onPlay(_callback: () => void): void {}
  onPaused(_callback: () => void): void {}
  onCompleted(_callback: () => void): void {}
  onStopped(_callback: () => void): void {}
  onTimeUpdate(_callback: (currentTime: number) => void): void {}
  onBuffering(_callback: (isBuffering: boolean) => void): void {}
  onError(_callback: (error: Error) => void): void {}
  onUnsupportedFormat(_callback: () => void): void {}
  onSeekDone(_callback: () => void): void {}
  onSubtitleUpdate(_callback: (info: SubtitleInfo) => void): void {}
}

class Controller extends VideoPlayerController {
  players: LifecyclePlayer[] = [];
  protected createAdapterForBackend(_backend: PlayerBackend): IPlayer | undefined {
    const player = new LifecyclePlayer(); this.players.push(player); return player;
  }
}
function controller(): Controller {
  const c = new Controller(); access(c).backendService = new Routing(); return c;
}
export async function exitDuringRouting(): Promise<void> {
  const c = controller(); const routing = new Routing(); routing.gate = new Gate(); access(c).backendService = routing;
  const init = c.initPlayer(source('A'), 'A'); await settle(); await c.release(); routing.gate.open(); await init;
  check(c.players.length === 0 && access(c).player === undefined, '退出后出现新实例');
}
export async function releaseBeforeNewInit(): Promise<void> {
  const c = controller(); await c.initPlayer(source('A'), 'A'); const old = c.players[0]; old.releaseGate = new Gate();
  const release = c.release(); const init = c.initPlayer(source('B'), 'B'); await settle();
  check(old.releases === 1 && c.players.length === 1, '旧释放等待期间创建实例或重复释放');
  old.releaseGate.open(); await Promise.all([release, init]);
  check(old.releases === 1 && access(c).player === c.players[1] && c.players[1].releases === 0, '实例归属错误');
  await c.release();
}
export async function lateAudioSwitch(): Promise<void> {
  const c = controller(); await c.initPlayer(source('A'), 'A'); const old = c.players[0]; old.pauseGate = new Gate();
  access(c).isPlaying = true; access(c).audioTracks = [{ trackIndex: 41, displayName: 'A' }];
  const switching = c.switchAudioTrack(0, true); await c.initPlayer(source('B'), 'B');
  access(c).audioTracks = [{ trackIndex: 72, displayName: 'B' }]; old.pauseGate.open(); await switching;
  check(c.players[1].selected.length === 0 && c.players[1].playCallCount === 0, '迟到选轨操作新实例');
  await c.release();
}
export async function reenterAfterRelease(): Promise<void> {
  const c = controller(); await c.initPlayer(source('A'), 'A'); await c.play(); await c.pause(); await c.release();
  await c.initPlayer(source('B'), 'B'); await c.play();
  check(c.players[0].releases === 1 && c.players[1].playCallCount === 1 && access(c).player === c.players[1], '重进回归');
  await c.release();
}
