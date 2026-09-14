const {test}=require('node:test');
const assert=require('node:assert/strict');
const {fixture,deferred,tick,data}=require('./player_session_fixture.cjs');

test('媒体标识乱序：旧结果不能覆盖新源、媒体标识或实例',async()=>{
  const {env,c}=fixture(),gate=deferred();
  env.db.getScrapeInfoByVideoId=id=>id===1?gate.promise:Promise.resolve(null);
  c.progressContext={videoId:1};const first=c.initPlayer(data('A'),'A');
  c.progressContext={videoId:2};await c.initPlayer(data('B'),'B');const latest=c.player;
  gate.resolve(null);await first;
  assert.equal(c.name,'B');assert.equal(c.metricsMedia.local_id,2);assert.equal(c.player,latest);
  assert.equal(env.players.length,1);assert.equal(latest.releases,0);
});
for(const phase of ['media','routing'])test(`${phase} 等待中退出，不得重建实例`,async()=>{
  const {env,c,backend}=fixture(),gate=deferred();const decision=await backend.chooseBackend();
  if(phase==='media'){env.db.getScrapeInfoByVideoId=()=>gate.promise;c.progressContext={videoId:1};}
  else backend.chooseBackend=()=>gate.promise;
  const pending=c.initPlayer(data('A'),'A');await tick();await c.release();gate.resolve(phase==='media'?null:decision);await pending;
  assert.equal(c.player,undefined);assert.equal(c.currentVideoData,undefined);assert.equal(env.players.length,0);
});
test('旧释放晚到：新初始化等待资源清理，旧实例仅释放一次',async()=>{
  const {env,c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;old.releaseGate=deferred();
  const releasing=c.release(), next=c.initPlayer(data('B'),'B');await tick();
  assert.equal(c.player,undefined);assert.equal(old.releases,1);assert.equal(env.players.length,1);
  old.releaseGate.resolve();await Promise.all([releasing,next]);
  assert.equal(c.player,env.players[1]);assert.equal(c.player.releases,0);assert.equal(old.releases,1);assert.equal(c.name,'B');
});
for(const fail of [false,true])test(`底层 init ${fail?'失败':'完成'}迟到：原实例清理完才创建新实例`,async()=>{
  const {env,c}=fixture();env.initGate=deferred();const gate=env.initGate;
  const first=c.initPlayer(data('A'),'A');await tick();const old=c.player;assert.ok(old);
  env.initGate=undefined;const second=c.initPlayer(data('B'),'B');await tick();
  assert.equal(env.players.length,1);assert.equal(old.releases,0);
  fail?gate.reject(new Error('旧初始化失败')):gate.resolve();await Promise.all([first,second]);
  assert.equal(old.releases,1);assert.equal(c.player,env.players[1]);assert.equal(c.backend,'avplayer');assert.equal(c.lastErrorMessage,'');
});
test('连续切集：释放等待期间只创建最终需求的实例',async()=>{
  const {env,c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;old.releaseGate=deferred();
  const b=c.initPlayer(data('B'),'B');await tick();const d=c.initPlayer(data('D'),'D');await tick();
  old.releaseGate.resolve();await Promise.all([b,d]);assert.equal(env.players.length,2);assert.equal(c.name,'D');assert.equal(old.releases,1);
});
test('释放中再次退出可重复调用，不重复释放实例',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;old.releaseGate=deferred();
  const a=c.release(),b=c.release();await tick();assert.equal(old.releases,1);old.releaseGate.resolve();await Promise.all([a,b]);assert.equal(old.releases,1);assert.equal(c.player,undefined);
});
test('旧音轨枚举不能污染新列表或对新实例选轨',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const gate=deferred();c.player.getTrackInfos=()=>gate.promise;
  const pending=c.loadAudioTracks();await c.initPlayer(data('B'),'B');const latest=c.player;
  gate.resolve([{trackType:'audio',trackIndex:41,language:'en'}]);await pending;
  assert.equal(c.audioTracks.length,0);assert.deepEqual(latest.selected,[]);
});
for(const fail of [false,true])test(`旧切轨 pause ${fail?'失败':'结束'}不操作新实例或显示旧错误`,async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;old.pauseGate=deferred();
  c.isPlaying=true;c.audioTracks=[{trackIndex:41,displayName:'A'}];const pending=c.switchAudioTrack(0,true);
  await c.initPlayer(data('B'),'B');const latest=c.player;c.audioTracks=[{trackIndex:72,displayName:'B'}];
  fail?old.pauseGate.reject(new Error('old pause failed')):old.pauseGate.resolve();await pending;
  assert.deepEqual(latest.selected,[]);assert.equal(latest.plays,0);assert.equal(c.activeAudioIndex,-1);assert.equal(c.lastErrorMessage,'');
});
test('旧 play 失败不覆盖新错误状态',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const gate=deferred();c.player.playGate=gate;const pending=c.play();
  await c.initPlayer(data('B'),'B');gate.reject(new Error('旧会话播放失败'));await pending;assert.equal(c.lastErrorMessage,'');
});
test('旧 seek 等待 pause 结束后不修改新进度或 seek 新实例',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const gate=deferred();c.player.pauseGate=gate;const pending=c.seek(40000);
  await c.initPlayer(data('B'),'B');const latest=c.player;gate.resolve();await pending;assert.equal(c.currentTime,0);assert.deepEqual(latest.seeks,[]);
});
test('退出后旧回调不能改变状态',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;await c.release();const state=c.state;
  old.callbacks.Stopped();old.callbacks.TimeUpdate(50000);old.callbacks.Completed();old.callbacks.Error(new Error('旧错误'));
  assert.equal(c.state,state);assert.equal(c.currentTime,0);assert.equal(c.lastErrorMessage,'');assert.equal(old.releases,1);
});
test('字幕解析 reset 后不再切轨、投影或启动持久化指令',async()=>{
  const {env,SubtitleSessionService}=fixture(),svc=new SubtitleSessionService();env.subtitleGate=deferred();
  const base={subtitleTracks:[],allSubtitleTracks:[],activeSubtitleIndex:-1,currentSubtitleTrack:-1,currentSubtitleText:'',subtitleDelayMs:0};
  const bridge={init:async()=>{},release(){},getState:()=>({...base,currentSubtitleText:'A'}),switchTrack:async()=>{bridge.switches++;},switches:0};
  const pending=svc.initialize(bridge,{},data('A'),'',undefined);await tick();svc.reset();svc.applyBridgeState({...base,currentSubtitleText:'B'});
  env.subtitleGate.resolve({type:'user-specified',trackIndex:0});await pending;
  assert.equal(bridge.switches,0);assert.equal(svc.getState().currentSubtitleText,'B');
});
for(const operation of ['switch','append'])test(`字幕 ${operation} 迟到不覆盖 reset 后状态`,async()=>{
  const {SubtitleSessionService}=fixture(),svc=new SubtitleSessionService(),gate=deferred();
  const base={subtitleTracks:[],allSubtitleTracks:[],activeSubtitleIndex:-1,currentSubtitleTrack:-1,currentSubtitleText:'B',subtitleDelayMs:0};
  const bridge={switchTrack:()=>gate.promise,addLocalSubtitle:()=>gate.promise,getState:()=>({...base,currentSubtitleText:'A'})};
  const pending=operation==='switch'?svc.switchToTrack(bridge,data('A'),'',0):svc.addLocalSubtitle(bridge,'A.srt');
  svc.reset();svc.applyBridgeState(base);gate.resolve();const result=await pending;
  assert.equal(svc.getState().currentSubtitleText,'B');assert.equal(operation==='switch'?result.type:result,operation==='switch'?'skip':-1);
});
test('正常准备、播放、暂停、音轨选择、切集和退出重进',async()=>{
  const {c,env}=fixture();await c.initPlayer(data('A'),'A');let p=c.player;
  await c.onPlayerReady();assert.equal(c.isReady,true);assert.equal(c.duration,120000);
  await c.play();assert.equal(p.plays,1);await c.pause();assert.equal(p.pauses,1);
  c.audioTracks=[{trackIndex:7,displayName:'英语'}];await c.switchAudioTrack(0);assert.deepEqual(p.selected,[7]);assert.equal(c.activeAudioIndex,0);
  await c.initPlayer(data('B'),'B');assert.equal(p.releases,1);p=c.player;await c.release();assert.equal(p.releases,1);
  await c.initPlayer(data('C'),'C');assert.equal(c.player,env.players[2]);assert.equal(c.name,'C');await c.release();
});
test('正常续播保留 seek 目标且 prepared 前设置 seeking',async()=>{
  const {c}=fixture();await c.initPlayer({...data('A'),seekTime:35000},'A');await c.onPlayerReady();
  assert.deepEqual(c.player.seeks,[35000]);assert.equal(c.currentTime,35000);assert.equal(c.isSeeking,true);await c.release();
});

test('真实 MPV 绑定服务：onLoad 迟到后不再 init，controller 等待清理 surface',async()=>{
  const f=fixture(),{c,FakeMpv}=f;
  const {PlaybackBackendService}=f.loadProduction('services/playback/PlaybackBackendService.ets');
  c.backendService=new PlaybackBackendService();const p=new FakeMpv();p.surfaceGate=deferred();
  c.backend='mpv';c.player=p;c.currentVideoData=data('A');
  const binding=c.setMpvSurface('surface-A',1920,1080);await tick();assert.equal(p.surface.loads,1);
  const release=c.release();await tick();assert.equal(p.releases,0);
  p.surfaceGate.resolve();await Promise.all([binding,release]);
  assert.equal(p.src,undefined);assert.equal(p.releases,1);assert.equal(p.surface.destroys,1);assert.equal(c.isMpvSurfaceBound,false);
});
test('MPV 重复 surface 事件只启动一次 init',async()=>{
  const f=fixture(),{c,FakeMpv}=f;const {PlaybackBackendService}=f.loadProduction('services/playback/PlaybackBackendService.ets');
  c.backendService=new PlaybackBackendService();const p=new FakeMpv();p.surfaceGate=deferred();
  c.backend='mpv';c.player=p;c.currentVideoData=data('A');
  const a=c.setMpvSurface('surface',1920,1080),b=c.setMpvSurface('surface',1920,1080);await tick();
  p.surfaceGate.resolve();await Promise.all([a,b]);assert.equal(p.surface.loads,1);assert.equal(c.isMpvSurfaceBound,true);assert.equal(p.src,data('A').videoSrc);await c.release();
});
for(const kind of ['AvSubtitleBridgeAdapter','MpvSubtitleBridgeAdapter'])test(`真实 ${kind} 内嵌轨道迟到不能回写已释放 bridge`,async()=>{
  const f=fixture();const mod=f.loadProduction('components/core/player/SubtitleBridgeAdapter.ets');const bridge=new mod[kind](),p=new f.FakePlayer(),gate=deferred();
  p.getTrackInfos=()=>gate.promise;const pending=bridge.init(p,data('A'));bridge.release();
  gate.resolve([{trackType:'subtitle',trackIndex:1,language:'en',mimeType:'text/srt'}]);await pending;
  assert.equal(bridge.getState().subtitleTracks.length,0);assert.equal(bridge.getState().allSubtitleTracks.length,0);assert.deepEqual(p.selected,[]);
});
test('真实字幕 bridge 偏好迟到不覆盖用户关闭字幕',async()=>{
  const f=fixture(),mod=f.loadProduction('components/core/player/SubtitleBridgeAdapter.ets'),bridge=new mod.AvSubtitleBridgeAdapter(),p=new f.FakePlayer();
  f.env.preferenceGate=deferred();p.getTrackInfos=async()=>[{trackType:'subtitle',trackIndex:1,language:'en',mimeType:'text/srt'}];
  const pending=bridge.init(p,data('A'));await tick();await bridge.switchTrack(-1);f.env.preferenceGate.resolve('en');await pending;
  assert.deepEqual(p.selected,[-1]);assert.equal(bridge.getState().activeSubtitleIndex,-1);
});
test('真实音轨路由服务：失效绑定迟到不清除用户绑定',async()=>{
  const f=fixture();const {AudioTrackRoutingService}=f.loadProduction('services/audioRouting/AudioTrackRoutingService.ets');
  f.env.audioBindingGate=deferred();let current=true;const svc=new AudioTrackRoutingService();
  const pending=svc.resolveInitialTrackIndex('A',[{trackIndex:1,displayName:'新轨'}],()=>current);await tick();current=false;
  f.env.audioBindingGate.resolve({displayName:'旧轨'});await pending;assert.equal(f.env.clearedBinding,undefined);
});
test('真实偏好持久化：store 初始化迟到，不提交失效选择',async()=>{
  const f=fixture(),{AppPreferences}=f.loadProduction('utils/AppPreferences.ets'),gate=deferred(),writes=[];
  AppPreferences.setStoreLoaderForTesting(()=>gate.promise);const init=AppPreferences.init({});let current=true;
  const pending=AppPreferences.setGuarded('audio', 'A',()=>current);await tick();current=false;
  gate.resolve({put:async(...args)=>writes.push(args),flush:async()=>{}});await Promise.all([pending,init]);assert.deepEqual(writes,[]);
});
test('真实偏好持久化：已提交不可取消的旧 put 不得晚于同 key 新写入',async()=>{
  const f=fixture(),{AppPreferences}=f.loadProduction('utils/AppPreferences.ets'),gate=deferred(),writes=[];
  AppPreferences.setStoreLoaderForTesting(async()=>({put:async(key,value)=>{if(value==='A')await gate.promise;writes.push(value);},flush:async()=>{}}));await AppPreferences.init({});
  let current=true;const first=AppPreferences.setGuarded('audio','A',()=>current);await tick();current=false;
  const second=AppPreferences.setGuarded('audio','B',()=>true);await tick();assert.deepEqual(writes,[]);gate.resolve();await Promise.all([first,second]);assert.deepEqual(writes,['A','B']);
});
test('MPV 切集保留 surface，退出由新实例释放一次',async()=>{
  const {c,env,backend}=fixture();const decision=await backend.chooseBackend();decision.preferredBackend='mpv';env.createMpv=true;
  await c.initPlayer(data('A'),'A');const old=c.player;await c.initPlayer(data('B'),'B');const latest=c.player;
  assert.equal(old.softReleases,1);assert.equal(old.surface.destroys,0);await c.release();assert.equal(latest.releases,1);assert.equal(latest.surface.destroys,1);
});
test('MPV softRelease 等待期间退出，迟到 surface 仍清理且不创建新实例',async()=>{
  const {c,env,backend}=fixture();const decision=await backend.chooseBackend();decision.preferredBackend='mpv';env.createMpv=true;
  await c.initPlayer(data('A'),'A');const old=c.player;old.softGate=deferred();const next=c.initPlayer(data('B'),'B');await tick();
  const release=c.release();old.softGate.resolve();await Promise.all([next,release]);assert.equal(env.players.length,1);assert.equal(old.softReleases,1);assert.equal(old.surface.destroys,1);
});
test('代理及 VPE 的旧所有者不能销毁新代次资源',async()=>{
  const f=fixture(),released=[];let handle=0,vpeReleased=0;
  f.mocks['libvidall_core_player_napi.so']={createPlayer:()=>++handle,setSource(){},setXComponent(){},setCallbacks(){},prepare(){},getProxyUrl:()=>`http://localhost/${handle}`,release:i=>released.push(i),
    isVpeDetailEnhancerSupported:()=>true,createVpeDetailEnhancer:()=>String(++handle),destroyVpeDetailEnhancer:()=>vpeReleased++};
  f.mocks['@ohos.hilog']={default:{info(){},warn(){}}};
  const {VidAllPlayerAdapter}=f.loadProduction('components/core/player/VidAllPlayerAdapter.ets');
  VidAllPlayerAdapter.startSmbProxy('smb://A');const old=VidAllPlayerAdapter.smbProxyGeneration;VidAllPlayerAdapter.startSmbProxy('smb://B');
  assert.deepEqual(released,[1]);VidAllPlayerAdapter.releaseSmbProxy(old);assert.deepEqual(released,[1]);VidAllPlayerAdapter.releaseSmbProxy(VidAllPlayerAdapter.smbProxyGeneration);assert.deepEqual(released,[1,2]);
  const {VpeEnhancerUtil}=f.loadProduction('utils/VpeEnhancerUtil.ets');VpeEnhancerUtil.createEnhancer('A');const vpeOld=VpeEnhancerUtil.generation;
  VpeEnhancerUtil.createEnhancer('B');VpeEnhancerUtil.destroyEnhancer(vpeOld);assert.equal(vpeReleased,0);VpeEnhancerUtil.destroyEnhancer(VpeEnhancerUtil.generation);assert.equal(vpeReleased,1);
});
test('AVPlayer 后端回退后旧回调无效，保留续播并可重新初始化',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const old=c.player;c.currentTime=45000;c.duration=120000;c.isPlaying=true;
  c.fallbackAvPlayerToMpv('test');old.callbacks.Stopped();assert.equal(c.backend,'mpv');assert.equal(c.resumeSession.pending.positionMs,45000);assert.equal(c.resumeSession.pending.shouldResumePlay,true);
  await c.initPlayer(data('A'),'A');assert.equal(c.backend,'mpv');assert.equal(old.releases,1);await c.release();
});
test('重复 surface 绑定的旧失败不向新会话传播或重试 init',async()=>{
  const f=fixture(),{c,FakeMpv}=f;const {PlaybackBackendService}=f.loadProduction('services/playback/PlaybackBackendService.ets');
  c.backendService=new PlaybackBackendService();const p=new FakeMpv();p.surfaceGate=deferred();c.backend='mpv';c.player=p;c.currentVideoData=data('A');
  const a=c.setMpvSurface('surface',1920,1080),b=c.setMpvSurface('surface',1920,1080);await tick();const release=c.release();
  p.surfaceGate.reject(new Error('旧 surface 失败'));await Promise.all([a,b,release]);assert.equal(c.lastErrorMessage,'');assert.equal(p.surface.loads,1);assert.equal(p.releases,1);
});
for(const operation of ['switch','append'])test(`字幕 ${operation} reset 后的旧异常安全结束`,async()=>{
  const {SubtitleSessionService}=fixture(),svc=new SubtitleSessionService(),gate=deferred();
  const bridge={switchTrack:()=>gate.promise,addLocalSubtitle:()=>gate.promise};
  const pending=operation==='switch'?svc.switchToTrack(bridge,data('A'),'',0):svc.addLocalSubtitle(bridge,'A.srt');
  svc.reset();gate.reject(new Error('旧字幕失败'));const result=await pending;assert.equal(operation==='switch'?result.type:result,operation==='switch'?'skip':-1);
});
test('reload 事务跟随同源后端回退，不把实例更换误判为切集取消',async()=>{
  const {c,env}=fixture();await c.initPlayer(data('A'),'A');env.initGate=deferred();const gate=env.initGate;
  const next=data('B');const reload=c.reloadSource(next,false);await tick();env.initGate=undefined;gate.reject(new Error('AVPlayer 初始化失败'));await tick();
  assert.equal(c.backend,'mpv');await c.initPlayerForSurface(next,'mpv-surface');c.player.callbacks.Ready();await reload;
  assert.equal(c.name,'B');assert.equal(c.backend,'mpv');await c.release();
});
test('旧 reload 被新源替代，其 catch 不得拒绝新 reload',async()=>{
  const {c}=fixture();await c.initPlayer(data('A'),'A');const first=c.reloadSource(data('B'),false);const firstResult=first.catch(e=>e);
  await tick();const second=c.reloadSource(data('C'),false);await tick();c.player.callbacks.Ready();await second;
  assert.ok(await firstResult);assert.equal(c.name,'C');await c.release();
});

for (const latestSurface of ['surface-A', 'surface-B']) test(`MPV 首次绑定失败后处理有效并发请求：${latestSurface}`, async () => {
  const f = fixture(), { c, FakeMpv } = f;
  const { PlaybackBackendService } = f.loadProduction('services/playback/PlaybackBackendService.ets');
  c.backendService = new PlaybackBackendService();
  const p = new FakeMpv(), gate = deferred(), loads = [];
  p.surface.onLoad = async (...args) => {
    loads.push(args);
    if (loads.length === 1) await gate.promise;
  };
  c.backend = 'mpv'; c.player = p; c.currentVideoData = data('A');
  const first = c.setMpvSurface('surface-A', 1920, 1080);
  await tick();
  const latest = c.setMpvSurface(latestSurface, 1280, 720);
  gate.reject(new Error('首次绑定失败'));
  await Promise.all([first, latest]);
  assert.deepEqual(loads, [['surface-A', 1920, 1080], [latestSurface, 1280, 720]]);
  assert.equal(c.player, p);
  assert.equal(c.isMpvSurfaceBound, true);
  assert.equal(c.boundMpvSurfaceId, latestSurface);
  assert.equal(p.src, data('A').videoSrc);
  assert.equal(p.releases, 0);
  await c.release();
  assert.equal(p.releases, 1);
  assert.equal(p.surface.destroys, 1);
});
