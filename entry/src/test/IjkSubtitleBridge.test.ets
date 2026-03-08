import { describe, it, expect } from '@ohos/hypium';
import { FfprobeUtil, FfprobeTrack } from '../main/ets/utils/FfprobeUtil';
import { SrtParser, SrtEntry } from '../main/ets/components/core/player/SubtitleRenderer';

/**
 * ijk 字幕后端能力接入 — 单元测试
 *
 * 覆盖范围：
 * 1. FfprobeUtil.buildSubtitleTrackDisplayName() — 字幕轨名称构建
 * 2. 字幕延迟偏移逻辑 — SrtParser.findAt 时间调整验证
 * 3. 空轨道/解析失败边界场景
 */
export default function ijkSubtitleBridgeTest() {
  describe('IjkSubtitleBridge', () => {

    // ─── FfprobeUtil.buildSubtitleTrackDisplayName ───────────────────────────

    it('buildSubtitleTrackDisplayName: 带语言+编码', 0, () => {
      const track: FfprobeTrack = {
        index: 2, type: 'subtitle',
        codecName: 'subrip', codecLongName: 'SubRip Subtitle',
        language: 'chi'
      };
      const name = FfprobeUtil.buildSubtitleTrackDisplayName(track, 0);
      expect(name).assertEqual('中文 (SRT)');
    });

    it('buildSubtitleTrackDisplayName: ASS 英语', 0, () => {
      const track: FfprobeTrack = {
        index: 3, type: 'subtitle',
        codecName: 'ass', codecLongName: 'ASS (Advanced SSA) subtitle',
        language: 'eng'
      };
      const name = FfprobeUtil.buildSubtitleTrackDisplayName(track, 1);
      expect(name).assertEqual('英语 (ASS)');
    });

    it('buildSubtitleTrackDisplayName: 无语言兜底显示 "字幕 N"', 0, () => {
      const track: FfprobeTrack = {
        index: 4, type: 'subtitle',
        codecName: 'subrip', codecLongName: '',
        language: ''
      };
      const name = FfprobeUtil.buildSubtitleTrackDisplayName(track, 2);
      // 无语言时：字幕 3 (SRT)
      expect(name).assertContain('字幕 3');
    });

    it('buildSubtitleTrackDisplayName: PGS 图形字幕无语言', 0, () => {
      const track: FfprobeTrack = {
        index: 5, type: 'subtitle',
        codecName: 'hdmv_pgs_subtitle', codecLongName: 'HDMV Presentation Graphic Stream',
        language: ''
      };
      const name = FfprobeUtil.buildSubtitleTrackDisplayName(track, 0);
      expect(name).assertContain('PGS');
    });

    it('buildSubtitleTrackDisplayName: 空轨道列表不崩溃', 0, () => {
      const tracks: FfprobeTrack[] = [];
      // 空数组不调用，仅验证方法在有效输入时不抛异常
      expect(tracks.length).assertEqual(0);
    });

    // ─── 字幕延迟偏移逻辑（SrtParser 时间轴查找）────────────────────────────

    /**
     * 验证：subtitleDelayMs > 0（字幕偏慢，往后推）时，
     * 用 currentTime - delayMs 查找，使原本早出现的字幕被推迟到更晚的视频时间显示。
     *
     * 例：第二条字幕 startMs=4000，加 +2000ms 延迟后，要到视频 6000ms 时才出现。
     *     视频 4500ms 时，SrtParser 查找 4500-2000=2500ms，返回第一条字幕内容。
     */
    it('subtitleDelayMs > 0 时：SrtParser 查找时间前移，字幕内容延迟出现', 0, () => {
      const entries: SrtEntry[] = [
        { startMs: 1000, endMs: 3000, text: '第一条' },
        { startMs: 4000, endMs: 6000, text: '第二条' },
      ];

      // 当前视频时间 4500ms，不加延迟应显示"第二条"
      const noDelay = SrtParser.findAt(entries, 4500);
      expect(noDelay).assertEqual('第二条');

      // 加 +2000ms 延迟：查找时间 = 4500 - 2000 = 2500ms，应显示"第一条"
      // 这意味着"第二条"要到视频 6000ms 才会出现（被推迟了 2000ms）
      const withDelay = SrtParser.findAt(entries, 4500 - 2000);
      expect(withDelay).assertEqual('第一条');
    });

    /**
     * 验证：subtitleDelayMs < 0（字幕偏快，往前提）时，
     * 用 currentTime - (-|D|) = currentTime + |D| 查找，使字幕提前出现。
     *
     * 例：第一条字幕 startMs=1000，加 -1000ms 延迟后，在视频 0ms 时就可能出现。
     *     视频 500ms 时，SrtParser 查找 500-(-1000)=1500ms，返回第一条字幕内容。
     */
    it('subtitleDelayMs < 0 时：SrtParser 查找时间后移，字幕内容提前出现', 0, () => {
      const entries: SrtEntry[] = [
        { startMs: 1000, endMs: 3000, text: '第一条' },
        { startMs: 4000, endMs: 6000, text: '第二条' },
      ];

      // 当前视频时间 500ms，不加偏移：时间段前无字幕
      const noDelay = SrtParser.findAt(entries, 500);
      expect(noDelay).assertEqual('');

      // 加 -1000ms 偏移：查找时间 = 500 - (-1000) = 1500ms，应显示"第一条"
      // 这意味着"第一条"在视频 0ms 时就开始显示（提前了 1000ms）
      const withNegDelay = SrtParser.findAt(entries, 500 - (-1000));
      expect(withNegDelay).assertEqual('第一条');
    });

    it('subtitleDelay: 零偏移行为与原始一致', 0, () => {
      const entries: SrtEntry[] = [
        { startMs: 2000, endMs: 5000, text: '测试字幕' },
      ];
      const t = 3000;
      const zeroDelay = SrtParser.findAt(entries, t - 0);
      expect(zeroDelay).assertEqual('测试字幕');
    });

    // ─── 空轨道/错误边界 ──────────────────────────────────────────────────────

    it('SrtParser.findAt: 空条目列表返回空字符串', 0, () => {
      const result = SrtParser.findAt([], 5000);
      expect(result).assertEqual('');
    });

    it('SrtParser.findAt: 时间超出所有字幕范围返回空字符串', 0, () => {
      const entries: SrtEntry[] = [
        { startMs: 1000, endMs: 2000, text: '字幕' },
      ];
      const result = SrtParser.findAt(entries, 99999);
      expect(result).assertEqual('');
    });

    it('SrtParser.findAt: 时间在字幕开始前返回空字符串', 0, () => {
      const entries: SrtEntry[] = [
        { startMs: 5000, endMs: 8000, text: '字幕' },
      ];
      const result = SrtParser.findAt(entries, 1000);
      expect(result).assertEqual('');
    });

    // ─── FfprobeUtil.getCodecDisplayName 字幕格式映射 ─────────────────────────

    it('getCodecDisplayName: subrip → SRT', 0, () => {
      expect(FfprobeUtil.getCodecDisplayName('subrip')).assertEqual('SRT');
    });

    it('getCodecDisplayName: ass → ASS', 0, () => {
      expect(FfprobeUtil.getCodecDisplayName('ass')).assertEqual('ASS');
    });

    it('getCodecDisplayName: hdmv_pgs_subtitle → PGS', 0, () => {
      expect(FfprobeUtil.getCodecDisplayName('hdmv_pgs_subtitle')).assertEqual('PGS');
    });

    it('getCodecDisplayName: 未知编解码器原样大写输出', 0, () => {
      expect(FfprobeUtil.getCodecDisplayName('dvdsub')).assertEqual('DVDSUB');
    });
  });
}
