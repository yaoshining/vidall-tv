import relationalStore from '@ohos.data.relationalStore';
import { VideoServer, VideoServerType } from '../models/VideoServerEntity';
import { CryptoUtil } from '../../utils/CryptoUtil';
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

  constructor(core: FileSourceDbCore) {
    this.core = core;
  }

  /** 需要加密的敏感配置字段 */
  private static readonly SENSITIVE_KEYS: string[] = ['password', 'apiKey', 'token'];

  private async encryptSensitive(config: Record<string, Object>): Promise<Record<string, Object>> {
    for (const key of VideoServerDao.SENSITIVE_KEYS) {
      const value = config[key];
      if (typeof value === 'string' && value.length > 0) {
        config[key] = await CryptoUtil.encrypt(value);
      }
    }
    return config;
  }

  private async decryptSensitive(config: Record<string, Object>): Promise<Record<string, Object>> {
    for (const key of VideoServerDao.SENSITIVE_KEYS) {
      const value = config[key];
      if (typeof value === 'string' && value.length > 0) {
        try {
          config[key] = await CryptoUtil.decrypt(value);
        } catch (error) {
          console.error('VideoServerDao: Failed to decrypt sensitive field', key, JSON.stringify(error));
          // 解密失败时保持密文状态
        }
      }
    }
    return config;
  }

  /**
   * 插入影视服务器
   */
  async insertVideoServer(server: VideoServer): Promise<number> {
    const store = this.core.getStore();

    try {
      const config = await this.encryptSensitive(JSON.parse(server.configJson) as Record<string, Object>);
      const valueBucket: relationalStore.ValuesBucket = {
        name: server.name,
        type: server.type,
        config_json: JSON.stringify(config),
        created_at: server.createdAt
      };

      const rowId = await store.insert(TABLE_VIDEO_SERVERS, valueBucket);
      console.info(`VideoServerDao: Inserted video server with id ${rowId}`);
      return rowId;
    } catch (error) {
      console.error('VideoServerDao: Failed to insert video server', JSON.stringify(error));
      throw new Error('Failed to insert video server: ' + JSON.stringify(error));
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
      const config = await this.encryptSensitive(JSON.parse(server.configJson) as Record<string, Object>);
      const valueBucket: relationalStore.ValuesBucket = {
        name: server.name,
        type: server.type,
        config_json: JSON.stringify(config),
        created_at: server.createdAt
      };

      const predicates = new relationalStore.RdbPredicates(TABLE_VIDEO_SERVERS);
      predicates.equalTo('id', server.id);

      const rows = await store.update(valueBucket, predicates);
      console.info(`VideoServerDao: Updated ${rows} video server(s)`);
    } catch (error) {
      console.error('VideoServerDao: Failed to update video server', JSON.stringify(error));
      throw new Error('Failed to update video server: ' + JSON.stringify(error));
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
      console.error('VideoServerDao: Failed to delete video server', JSON.stringify(error));
      throw new Error('Failed to delete video server: ' + JSON.stringify(error));
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
      console.error('VideoServerDao: Failed to get video server by id', JSON.stringify(error));
      throw new Error('Failed to get video server by id: ' + JSON.stringify(error));
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
      console.error('VideoServerDao: Failed to get all video servers', JSON.stringify(error));
      throw new Error('Failed to get all video servers: ' + JSON.stringify(error));
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

      const config = await this.decryptSensitive(JSON.parse(configJson) as Record<string, Object>);

      return {
        id: id,
        name: name,
        type: typeString as VideoServerType,
        configJson: JSON.stringify(config),
        createdAt: createdAt
      };
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(0x0000, 'VideoServerDao', `parseVideoServer 失败: ${err.message}`);
      throw new Error(err.message);
    }
  }
}
