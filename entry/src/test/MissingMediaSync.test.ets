import { describe, it, expect } from '@ohos/hypium';
import { VideoEntity } from '../main/ets/db/models/MediaEntity';
import {
  normalizeMissingMediaPath,
  getMissingMediaParentPath,
  isExactMissingMediaPathMatch,
  groupMissingMediaVideos,
} from '../main/ets/services/mediaSync/MissingMediaPathUtils';

function makeVideo(id: number, sourceId: number, directoryPath: string, filePath: string): VideoEntity {
  const v: VideoEntity = {
    id,
    sourceId,
    directoryPath,
    filePath,
    fileName: filePath.substring(filePath.lastIndexOf('/') + 1),
    scannedAt: 0,
  };
  return v;
}

export default function missingMediaSyncTest() {
  describe('normalizeMissingMediaPath', () => {
    it('反斜杠统一为斜杠并折叠重复斜杠', 0, () => {
      expect(normalizeMissingMediaPath('\\a\\b//c')).assertEqual('/a/b/c');
    });

    it('去除末尾斜杠但保留根目录', 0, () => {
      expect(normalizeMissingMediaPath('/a/b/')).assertEqual('/a/b');
      expect(normalizeMissingMediaPath('/')).assertEqual('/');
    });

    it('空路径归一化为根目录', 0, () => {
      expect(normalizeMissingMediaPath('')).assertEqual('/');
    });

    it('解码百分号编码路径', 0, () => {
      expect(normalizeMissingMediaPath('/TV%20Series')).assertEqual('/TV Series');
    });

    it('非法编码保持原样不抛异常', 0, () => {
      expect(normalizeMissingMediaPath('/bad%')).assertEqual('/bad%');
    });
  });

  describe('getMissingMediaParentPath', () => {
    it('返回文件所在父目录', 0, () => {
      expect(getMissingMediaParentPath('/nas/movies/a.mkv')).assertEqual('/nas/movies');
    });

    it('顶层文件返回根目录', 0, () => {
      expect(getMissingMediaParentPath('/a.mkv')).assertEqual('/');
    });
  });

  describe('isExactMissingMediaPathMatch', () => {
    it('完全相同路径匹配', 0, () => {
      expect(isExactMissingMediaPathMatch('/a/b.mkv', '/a/b.mkv')).assertTrue();
    });

    it('尾斜杠差异与编码差异归一后仍匹配', 0, () => {
      expect(isExactMissingMediaPathMatch('/a/b.mkv', '/a/b.mkv/')).assertTrue();
      expect(isExactMissingMediaPathMatch('/a/b mkv', '/a/b%20mkv')).assertTrue();
    });

    it('不同路径不匹配', 0, () => {
      expect(isExactMissingMediaPathMatch('/a/b.mkv', '/a/c.mkv')).assertFalse();
    });

    it('子串不误判为匹配', 0, () => {
      expect(isExactMissingMediaPathMatch('/a/b.mkv', '/a/b.mkv2')).assertFalse();
    });
  });

  describe('groupMissingMediaVideos', () => {
    it('相同源+目录合并为一组', 0, () => {
      const videos: VideoEntity[] = [
        makeVideo(1, 10, '/nas/movies', '/nas/movies/a.mkv'),
        makeVideo(2, 10, '/nas/movies', '/nas/movies/b.mkv'),
      ];
      const groups = groupMissingMediaVideos(videos);
      expect(groups.length).assertEqual(1);
      expect(groups[0].videos.length).assertEqual(2);
    });

    it('不同源或不同目录拆分分组', 0, () => {
      const videos: VideoEntity[] = [
        makeVideo(1, 10, '/nas/movies', '/nas/movies/a.mkv'),
        makeVideo(2, 20, '/nas/movies', '/nas/movies/b.mkv'),
        makeVideo(3, 10, '/nas/other', '/nas/other/c.mkv'),
      ];
      const groups = groupMissingMediaVideos(videos);
      expect(groups.length).assertEqual(3);
    });

    it('directoryPath 为空时回退到文件父目录', 0, () => {
      const videos: VideoEntity[] = [
        makeVideo(1, 10, '', '/nas/movies/a.mkv'),
        makeVideo(2, 10, '', '/nas/movies/b.mkv'),
      ];
      const groups = groupMissingMediaVideos(videos);
      expect(groups.length).assertEqual(1);
      expect(groups[0].directoryPath).assertEqual('/nas/movies');
    });

    it('跳过 id 缺失的记录', 0, () => {
      const noId: VideoEntity = {
        sourceId: 10,
        directoryPath: '/nas/movies',
        filePath: '/nas/movies/a.mkv',
        fileName: 'a.mkv',
        scannedAt: 0,
      };
      const groups = groupMissingMediaVideos([noId]);
      expect(groups.length).assertEqual(0);
    });

    it('规范化后相同目录去重合并', 0, () => {
      const videos: VideoEntity[] = [
        makeVideo(1, 10, '/nas/movies/', '/nas/movies/a.mkv'),
        makeVideo(2, 10, '/nas/movies', '/nas/movies/b.mkv'),
      ];
      const groups = groupMissingMediaVideos(videos);
      expect(groups.length).assertEqual(1);
    });
  });
}
