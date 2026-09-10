import { describe, it, expect } from '@ohos/hypium';
import { SMBAdapter } from '../main/ets/utils/SMBAdapter';
import { WebDAVAdapter } from '../main/ets/utils/WebDAVAdapter';
import { FileSource, FileSourceType } from '../main/ets/db/models/FileSourceEntity';
import { VideoEntity } from '../main/ets/db/models/MediaEntity';
import { ISourceAdapter, VideoUpsertStrategy } from '../main/ets/utils/VideoScannerTypes';
import { SmbListDirectoryResult } from '../main/ets/lib/SMBClient';
import { WebDAVResource } from '../main/ets/lib/WebDAVClient';

class UnusedUpsert implements VideoUpsertStrategy {
  async upsert(_entity: VideoEntity): Promise<number> { throw new Error('目录夹具不应产生视频'); }
}
function source(type: FileSourceType): FileSource {
  return { id: 1, name: '目录错误测试', type: type, createdAt: 0,
    configJson: type === FileSourceType.SMB
      ? '{"host":"127.0.0.1","username":"","password":""}'
      : '{"url":"127.0.0.1","protocol":"http"}' };
}
async function assertScanFails(adapter: ISourceAdapter): Promise<void> {
  let message = '';
  try { await adapter.scan('/root', { maxDepth: 5, mode: 'incremental' }); }
  catch (error) { message = String(error); }
  expect(message.includes('不可达')).assertTrue();
}
async function smbRootFailure(_path: string): Promise<SmbListDirectoryResult> {
  return { files: [], error: '根目录不可达' };
}
async function smbChildFailure(path: string): Promise<SmbListDirectoryResult> {
  return path === '/root'
    ? { files: [{ name: 'child', path: '/root/child', isDirectory: true, size: 0, lastModifiedMs: 0 }] }
    : { files: [], error: '子目录不可达' };
}
async function webdavChildFailure(path: string): Promise<WebDAVResource[]> {
  if (path === '/root') { return [{ href: '/root/child/', displayName: 'child', isCollection: true }]; }
  throw new Error('子目录不可达');
}
export default function directedAdapterErrorsTest() {
  describe('定向扫描适配器错误传播', () => {
    it('SMB根目录返回error时必须失败', 0, async () => {
      await assertScanFails(new SMBAdapter(source(FileSourceType.SMB), undefined, new UnusedUpsert(), smbRootFailure));
    });
    it('SMB子目录失败不得返回空成功', 0, async () => {
      await assertScanFails(new SMBAdapter(source(FileSourceType.SMB), undefined, new UnusedUpsert(), smbChildFailure));
    });
    it('WebDAV子目录失败必须传播至定向扫描', 0, async () => {
      await assertScanFails(new WebDAVAdapter(source(FileSourceType.WEBDAV), undefined, new UnusedUpsert(), webdavChildFailure));
    });
    it('全局扫描保持原有子目录跳过行为', 0, async () => {
      const adapter = new WebDAVAdapter(source(FileSourceType.WEBDAV), undefined, undefined, webdavChildFailure);
      const result = await adapter.scan('/root', { maxDepth: 5, mode: 'incremental' });
      expect(result.length).assertEqual(0);
    });
  });
}
