import { describe, it, expect } from '@ohos/hypium';
import { millisecondsToTime } from '../main/ets/utils/TimeUtil';

export default function TimeUtilTest() {
  describe('millisecondsToTime', () => {

    it('0 毫秒应返回 "00:00"', 0, () => {
      expect(millisecondsToTime(0)).assertEqual('00:00');
    });

    it('1000 毫秒（1 秒）应返回 "00:01"', 0, () => {
      expect(millisecondsToTime(1000)).assertEqual('00:01');
    });

    it('59000 毫秒（59 秒）应返回 "00:59"', 0, () => {
      expect(millisecondsToTime(59000)).assertEqual('00:59');
    });

    it('60000 毫秒（1 分钟）应返回 "01:00"', 0, () => {
      expect(millisecondsToTime(60000)).assertEqual('01:00');
    });

    it('3599000 毫秒（59 分 59 秒）应返回 "59:59"', 0, () => {
      expect(millisecondsToTime(3599000)).assertEqual('59:59');
    });

    it('3600000 毫秒（1 小时）应返回 "01:00:00"', 0, () => {
      expect(millisecondsToTime(3600000)).assertEqual('01:00:00');
    });

    it('3661000 毫秒（1 小时 1 分 1 秒）应返回 "01:01:01"', 0, () => {
      expect(millisecondsToTime(3661000)).assertEqual('01:01:01');
    });

    it('不足一秒的毫秒数应向下取整（46613ms → "00:46"）', 0, () => {
      expect(millisecondsToTime(46613)).assertEqual('00:46');
    });

    it('分钟和秒数不足两位时应补零前缀', 0, () => {
      expect(millisecondsToTime(61000)).assertEqual('01:01');
    });

    it('超过 10 小时的时长应正确格式化', 0, () => {
      expect(millisecondsToTime(36000000)).assertEqual('10:00:00');
    });
  });
}