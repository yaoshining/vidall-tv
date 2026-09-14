// 主机竞态复现：转译并执行未修改的生产方法；仅替换平台/IO 边界。
// 生产 controller / session 方法不替换；播放器及平台 IO 用可控实现。
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const {test} = require('node:test');
const ts = require(process.env.TYPESCRIPT_PATH || 'typescript');
const root = process.env.PLAYER_SOURCE_ROOT || path.resolve(__dirname, '../main/ets');
const playerDir = path.join(root, 'components/core/player');
function deferred() { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a;reject=b;}); return {promise,resolve,reject}; }
const tick = async () => { for(let i=0;i<20;i++) await Promise.resolve(); };
function fixture() {
  const env = {db: {getScrapeInfoByVideoId: async()=>null, getVideoById:async()=>null}, players: [], proxyReleases:0, vpeReleases:0};
  class FakePlayer {
    constructor() { this.releases=0; this.selected=[]; this.callbacks={}; this.plays=0; this.pauses=0; this.seeks=[]; this.duration=120000; this.currentTime=0; }
    async init(data) { this.src=data.videoSrc; if(env.initGate)await env.initGate.promise; }
    async play() {this.plays++; if(this.playGate)await this.playGate.promise;}
    async pause() {this.pauses++; if(this.pauseGate)await this.pauseGate.promise;}
    seek(time) {this.seeks.push(time);}
    setPlaybackSpeed() {}
    async release() { this.releases++; if(this.releaseGate) await this.releaseGate.promise; }
    async selectTrack(i) { this.selected.push(i); }
    async getTrackInfos() { return []; }
  }
  for(const event of ['Ready','Play','Paused','Completed','Stopped','TimeUpdate','Error','UnsupportedFormat','SeekDone','SubtitleUpdate','Buffering']) FakePlayer.prototype['on'+event]=function(fn){this.callbacks[event]=fn;};
  class FakeMpv extends FakePlayer {
    constructor(){super();this.softReleases=0;this.surface={loads:0,destroys:0,onLoad:async()=>{this.surface.loads++;if(this.surfaceGate)await this.surfaceGate.promise;},onDestroy:async()=>{this.surface.destroys++;},onSizeChange:async()=>{}};}
    getSurfaceAdapter(){return this.surface;}
    async softRelease(){this.softReleases++;if(this.softGate)await this.softGate.promise;}
    async release(){await super.release();await this.surface.onDestroy();}
  }
  class Bridge { async init(){} onSeekSync(){} onSubtitleUpdate(){} onTimeUpdate(){} release(){} getState(){return {subtitleTracks:[],allSubtitleTracks:[],activeSubtitleIndex:-1,currentSubtitleTrack:-1,currentSubtitleText:'',subtitleDelayMs:0};} }
  class Dispatcher { async resolveSubtitle(){return env.subtitleGate ? env.subtitleGate.promise : {type:'none'};} }
  const decision = {preferredBackend:'avplayer',trackAnalyses:[],videoHdrType:'',summary:'',detectedChannels:2};
  const backend = {
    chooseBackend: async()=>decision,
    prepareAdapter() {const player=env.createMpv?new FakeMpv():new FakePlayer();env.players.push(player);return {player,effectiveVideoSrc:''};}
  };
  const mocks = {
    '@ohos.file.fs':{}, '@ohos.util':{}, '@ohos.buffer':{from:Buffer.from},
    '@ohos.data.preferences':{}, '@kit.NetworkKit':{http:{createHttp:()=>env.http}},
    SubtitleRenderer:{SrtParser:{findAt:()=>'',parse:()=>[]},AssFileParser:{parse:()=>[]}},
    SubtitleLanguagePreference:{loadSubtitleLanguagePreference:async()=>env.preferenceGate?env.preferenceGate.promise:'zh',findPreferredSubtitleTrackIndex:()=>0},
    SmbSubtitleBridgeAdapter:{SmbAvSubtitleBridgeAdapter:Bridge},
    SubtitleDownloader:{sha256Hex:async()=>env.hashGate?env.hashGate.promise:'hash'},
    SubtitleCacheManager:{SubtitleCacheManager:class{}}, UmamiAnalyticsService:{}, AppPreferences:{AppPreferences:{}},
    '@kit.BasicServicesKit': {emitter:{emit(){},EventPriority:{HIGH:1}}}, '@kit.PerformanceAnalysisKit':{hilog:{info(){},warn(){},error(){},debug(){}}},
    '@kit.ArkUI':{}, CommonConstants:{CommonConstants:{LOG_DOMAIN:0}}, TimeUtil:{millisecondsToTime:String},
    AVPlayerAdapter:{AVPlayerAdapter:FakePlayer}, MpvPlayerAdapter:{MpvPlayerAdapter:FakeMpv},
    VidAllPlayerAdapter:{VidAllPlayerAdapter:{releaseSmbProxy(){env.proxyReleases++;}}},
    FileSourceDatabase:{FileSourceDatabase:{getInstance:()=>env.db}},
    FfprobeUtil:{FfprobeUtil:{getLanguageDisplayName:x=>x}}, SubtitleBridgeAdapter:{NoSubtitleBridgeAdapter:Bridge,BaseSubtitleBridgeAdapter:Bridge},
    VpeEnhancerUtil:{VpeEnhancerUtil:{isSupported:()=>false,destroyEnhancer(){env.vpeReleases++;}}},
    MetricsService:{MetricsService:{isInitialized:()=>false}}, SubtitleDispatcher:{SubtitleDispatcher:Dispatcher}, AudioDispatcher:{AudioDispatcher:class { async saveAudioBinding(){} async getAudioBinding(){return env.audioBindingGate?env.audioBindingGate.promise:null;} async clearAudioBinding(){env.clearedBinding=true;} }},
    PlaybackBackendService:{playbackBackendService:backend},
    AudioTrackRoutingService:{audioTrackRoutingService:{resolveInitialTrackIndex:async()=>({trackIndex:0})},normalizeAudioCodec:x=>x||'unknown',findInitialAudioTrackIndex:()=>0},
    AudioDecoderCapabilityService:{audioDecoderCapabilityService:{ensureLoaded:async()=>{},getCompatibility:()=>({compatible:true})}}
  };
  const cache={};
  function load(file) {
    if(cache[file]) return cache[file];
    const exports={}; cache[file]=exports;
    const code=ts.transpileModule(fs.readFileSync(file,'utf8'),{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2021,experimentalDecorators:true}}).outputText;
    vm.runInNewContext(code,{exports,ObservedV2:x=>x,Trace:()=>{},Computed:()=>{},canIUse:()=>true,setTimeout,clearTimeout,setInterval,clearInterval,console,
      require(name) {const mock=mocks[name]||mocks[path.basename(name)];if(mock)return mock;const target=path.resolve(path.dirname(file),name)+'.ets';if(!['Constants','PlaybackState','ReloadSession','ResumeSession','EpisodeAutoplayPreferences','SubtitleSessionService','PlaybackBackendTypes','AudioCodecUtil'].includes(path.basename(name)))throw Error('未声明依赖 '+name);return load(target);}
    },{filename:file});return exports;
  }
  const {VideoPlayerController}=load(path.join(playerDir,'VideoPlayerController.ets'));
  const {SubtitleSessionService}=load(path.join(root,'services/subtitleSession/SubtitleSessionService.ets'));
  return {env,c:new VideoPlayerController(),FakePlayer,FakeMpv,SubtitleSessionService,backend,loadProduction:relative=>load(path.join(root,relative)),mocks};
}
const data = name=>({name,videoSrc:'https://example.test/'+name});

module.exports={fixture,deferred,tick,data};
