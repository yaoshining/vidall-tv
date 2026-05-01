/**
 * Feature ID Constants
 * 
 * 定义应用中所有功能的标识符常量
 * 
 * 命名约定：
 * - 常量名：UPPER_SNAKE_CASE，前缀 FEATURE_
 * - 值格式：'feature:<kebab-case-name>'
 * - 前缀 'feature:' 用于命名空间隔离，避免与其他 ID 类型冲突
 * 
 * 使用指南：
 * 1. 添加新功能时，在此文件定义对应常量
 * 2. 使用常量而非硬编码字符串，便于 IDE 自动补全和重构
 * 3. 常量值一旦定义不应修改，避免破坏历史数据兼容性
 * 
 * 示例：
 * ```typescript
 * import { FEATURE_ADVANCED_PLAYBACK } from './services/entitlement/FeatureIds';
 * 
 * const hasAccess = await entitlementService.hasFeature(FEATURE_ADVANCED_PLAYBACK);
 * ```
 */

/**
 * 高级播放控制功能
 * 
 * 包含功能：
 * - 倍速播放（0.5x ~ 2.0x）
 * - 精确帧控制（逐帧前进/后退）
 * - 自定义快进/快退步长
 * - 播放列表管理
 * 
 * v1.x: 所有用户可用
 * v2.0 规划: 基础订阅及以上用户可用
 */
export const FEATURE_ADVANCED_PLAYBACK = 'feature:advanced-playback';

/**
 * 云同步功能
 * 
 * 包含功能：
 * - 播放历史云端同步
 * - 收藏列表云端备份
 * - 跨设备进度同步
 * - 设置云端同步
 * 
 * v1.x: 所有用户可用（本地存储）
 * v2.0 规划: 高级订阅用户可用（远程云存储）
 */
export const FEATURE_CLOUD_SYNC = 'feature:cloud-sync';

/**
 * 付费内容访问功能
 * 
 * 包含功能：
 * - 独家高清内容
 * - 4K/HDR 视频流
 * - 无广告观看体验
 * - 优先访问新发布内容
 * 
 * v1.x: 所有用户可用（无付费内容）
 * v2.0 规划: 高级订阅用户可用
 */
export const FEATURE_PREMIUM_CONTENT = 'feature:premium-content';

/**
 * 未来扩展示例（注释保留供参考）：
 * 
 * export const FEATURE_OFFLINE_DOWNLOAD = 'feature:offline-download';
 * export const FEATURE_MULTI_DEVICE = 'feature:multi-device';
 * export const FEATURE_LIVE_STREAMING = 'feature:live-streaming';
 * export const FEATURE_AI_RECOMMENDATION = 'feature:ai-recommendation';
 */
