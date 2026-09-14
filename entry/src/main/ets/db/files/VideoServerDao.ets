import relationalStore from '@ohos.data.relationalStore';
import { VideoServer, VideoServerType } from '../models/VideoServerEntity';
import { CredentialStorage } from './CredentialStorage';
import { BusinessError } from "@kit.BasicServicesKit";
import { hilog } from '@kit.PerformanceAnalysisKit';
import { TABLE_VIDEO_SERVERS } from './DbConstants';
import { FileSourceDbCore } from './FileSourceDbCore';

/**
 * video_servers 表的数据访问。
 * 结构与 FileSourceDao 对齐，敏感字段（password / apiKey / token）加密落库。
 */
export class VideoServerDao {
  private core: FileSourceDbCore;
  private credentials: CredentialStorage;
  private static readonly CREDENTIAL_KEYS: string[] = ['password', 'apiKey', 'token'];

  constructor(core: FileSourceDbCore, credentials: CredentialStorage = new CredentialStorage()) {
    this.core = core;
    this.credentials = credentials;
  }

  /**
   * 插入影视服务器
   */
  async insertVideoServer(server: VideoServer): Promise<number> {
    const store = this.core.getStore();

    try {
      const config = await this.credentials.write(server.configJson, TABLE_VIDEO_SERVERS, VideoServerDao.CREDENTIAL_KEYS);
      const valueBucket: relationalStore.ValuesBucket = {
        name: server.name,
        type: server.type,
        config_json: config,
        created_at: server.createdAt
      };

      const rowId = await store.insert(TABLE_VIDEO_SERVERS, valueBucket);
      console.info(`VideoServerDao: Inserted video server with id ${rowId}`);
      return rowId;
    } catch (error) {
      console.error('VideoServerDao: Failed to insert video server');
      throw new Error('数据源操作失败，请重新加载后重试；原凭据不会因读取失败而清空');
    }
  }

  /**
   * 更新影视服务器
   */
  async updateVideoServer(server: VideoServer): Promise<void> {
    const store = this.core.getStore();

    if (server.id === undefined) {
      throw new Error('Video server id is required for update');
    }

    try {
      const raw = await this.credentials.raw(store, TABLE_VIDEO_SERVERS, server.id);
      const config = await this.credentials.write(server.configJson, TABLE_VIDEO_SERVERS, VideoServerDao.CREDENTIAL_KEYS, raw);
      const valueBucket: relationalStore.ValuesBucket = {
        name: server.name,
        type: server.type,
        config_json: config,
        created_at: server.createdAt
      };

      const predicates = this.credentials.compare(TABLE_VIDEO_SERVERS, server.id, raw);

      const rows = await store.update(valueBucket, predicates);
      if (rows !== 1) { throw new Error('配置已变更，请重新加载后保存'); }
      console.info(`VideoServerDao: Updated ${rows} video server(s)`);
    } catch (error) {
      console.error('VideoServerDao: Failed to update video server');
      throw new Error('数据源操作失败，请重新加载后重试；原凭据不会因读取失败而清空');
    }
  }

  /**
   * 删除影视服务器
   */
  async deleteVideoServer(id: number): Promise<void> {
    const store = this.core.getStore();

    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_VIDEO_SERVERS);
      predicates.equalTo('id', id);

      const rows = await store.delete(predicates);
      console.info(`VideoServerDao: Deleted ${rows} video server(s)`);
    } catch (error) {
      console.error('VideoServerDao: Failed to delete video server');
      throw new Error('数据源操作失败，请重新加载后重试；原凭据不会因读取失败而清空');
    }
  }

  /**
   * 根据 ID 获取影视服务器
   */
  async getVideoServerById(id: number): Promise<VideoServer | null> {
    const store = this.core.getStore();

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_VIDEO_SERVERS);
      predicates.equalTo('id', id);

      resultSet = await store.query(predicates);

      if (resultSet.goToFirstRow()) {
        return await this.parseVideoServer(resultSet);
      }

      return null;
    } catch (error) {
      console.error('VideoServerDao: Failed to get video server by id');
      throw new Error('数据源操作失败，请重新加载后重试；原凭据不会因读取失败而清空');
    } finally {
      try { resultSet?.close(); } catch { }
    }
  }

  /**
   * 获取全部影视服务器
   */
  async getAllVideoServers(): Promise<VideoServer[]> {
    const store = this.core.getStore();

    let resultSet: relationalStore.ResultSet | null = null;
    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_VIDEO_SERVERS);
      resultSet = await store.query(predicates);

      const servers: VideoServer[] = [];
      while (resultSet.goToNextRow()) {
        const server = await this.parseVideoServer(resultSet);
        servers.push(server);
      }

      console.info(`VideoServerDao: Retrieved ${servers.length} video server(s)`);
      return servers;
    } catch (error) {
      console.error('VideoServerDao: Failed to get all video servers');
      throw new Error('数据源操作失败，请重新加载后重试；原凭据不会因读取失败而清空');
    } finally {
      try { resultSet?.close(); } catch { }
    }
  }

  /**
   * 从 ResultSet 解析影视服务器对象
   */
  private async parseVideoServer(resultSet: relationalStore.ResultSet): Promise<VideoServer> {
    try {
      const id = resultSet.getLong(resultSet.getColumnIndex('id'));
      const name = resultSet.getString(resultSet.getColumnIndex('name'));
      const typeString = resultSet.getString(resultSet.getColumnIndex('type'));
      const configJson = resultSet.getString(resultSet.getColumnIndex('config_json'));
      const createdAt = resultSet.getLong(resultSet.getColumnIndex('created_at'));

      const config = await this.credentials.read(this.core.getStore(), TABLE_VIDEO_SERVERS, id, configJson, VideoServerDao.CREDENTIAL_KEYS);

      return {
        id: id,
        name: name,
        type: typeString as VideoServerType,
        configJson: config,
        createdAt: createdAt
      };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'VideoServerDao', 'parseVideoServer 失败');
      throw new Error('数据源配置读取失败，请重试');
    }
  }
}
