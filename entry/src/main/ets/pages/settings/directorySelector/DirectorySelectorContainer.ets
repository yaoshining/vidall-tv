/**
 * DirectorySelectorContainer
 * 
 * 目录选择器容器，协议无关的路由参数处理
 * 使用 DirectoryProvider 接口实现协议解耦
 */

import { SMBSourceConfig, WebDAVSourceConfig } from "../../../db/models/FileSourceEntity"
import { 
  DirectoryProvider, 
  DirectoryProviderConfig 
} from "../../../lib/DirectoryProvider"
import { SmbDirectoryProvider } from "../../../lib/SmbDirectoryProvider"
import { WebDAVDirectoryProvider } from "../../../lib/WebDAVDirectoryProvider"

/**
 * 目录选择器条目（用于UI展示）
 */
export interface DirectorySelectorEntry {
  key: string
  name: string
  path: string
}

/**
 * 路由参数接口
 */
export interface DirectorySelectorRouteParams {
  sourceId: number
  protocol: 'webdav' | 'smb'
  username: string
  password: string
  protocolSpecific: Record<string, Object>
}

/**
 * 源描述符（包含实例化的 Provider）
 */
export interface DirectorySelectorSourceDescriptor {
  sourceId: number
  protocol: string
  rootLabel: string
  endpointSummary: string
  provider: DirectoryProvider
}

/**
 * 从 Record 中读取字符串参数
 */
function readStringParam(params: Record<string, Object>, key: string): string {
  const value = params[key]
  return typeof value === 'string' ? value : ''
}

/**
 * 从 Record 中读取数字参数
 */
function readNumberParam(params: Record<string, Object>, key: string): number | undefined {
  const value = params[key]
  return typeof value === 'number' ? value : undefined
}

/**
 * 从路由参数解析为 DirectorySelectorRouteParams
 */
export function createDirectorySelectorRouteParams(
  params: Record<string, Object> | undefined
): DirectorySelectorRouteParams | undefined {
  if (params === undefined) {
    return undefined
  }
  
  const sourceId = readNumberParam(params, 'sourceId')
  if (sourceId === undefined || sourceId <= 0) {
    return undefined
  }
  
  const protocol = readStringParam(params, 'protocol')
  const username = readStringParam(params, 'username')
  const password = readStringParam(params, 'password')
  
  // 提取协议特定参数
  const protocolSpecific: Record<string, Object> = {}
  
  if (protocol === 'webdav') {
    const baseUrl = readStringParam(params, 'baseUrl')
    if (baseUrl.length === 0) {
      return undefined  // webdav 必须提供 baseUrl
    }
    protocolSpecific['baseUrl'] = baseUrl
    protocolSpecific['tlsCertPolicy'] = readStringParam(params, 'tlsCertPolicy')
  } else if (protocol === 'smb') {
    const host = readStringParam(params, 'host')
    if (host.length === 0) {
      return undefined  // smb 必须提供 host
    }
    protocolSpecific['host'] = host
    protocolSpecific['port'] = readNumberParam(params, 'port') ?? 445
    protocolSpecific['domain'] = readStringParam(params, 'domain')
    protocolSpecific['shareName'] = readStringParam(params, 'shareName')
  } else {
    // 兼容旧格式（通过 baseUrl/host 推断协议）
    const baseUrl = readStringParam(params, 'baseUrl')
    const host = readStringParam(params, 'host')
    
    if (baseUrl.length > 0) {
      protocolSpecific['baseUrl'] = baseUrl
      protocolSpecific['tlsCertPolicy'] = 'allow_self_signed'
      const routeParams: DirectorySelectorRouteParams = {
        sourceId: sourceId,
        protocol: 'webdav',
        username: username,
        password: password,
        protocolSpecific: protocolSpecific
      }
      return routeParams
    }
    
    if (host.length > 0) {
      protocolSpecific['host'] = host
      protocolSpecific['port'] = readNumberParam(params, 'port') ?? 445
      protocolSpecific['domain'] = readStringParam(params, 'domain')
      protocolSpecific['shareName'] = ''
      const routeParams: DirectorySelectorRouteParams = {
        sourceId: sourceId,
        protocol: 'smb',
        username: username,
        password: password,
        protocolSpecific: protocolSpecific
      }
      return routeParams
    }
    
    return undefined
  }
  
  const routeParams: DirectorySelectorRouteParams = {
    sourceId: sourceId,
    protocol: protocol as 'webdav' | 'smb',
    username: username,
    password: password,
    protocolSpecific: protocolSpecific
  }
  return routeParams
}

/**
 * 从路由参数创建 DirectoryProvider 实例
 */
export async function createDirectorySelectorSourceDescriptor(
  params: DirectorySelectorRouteParams
): Promise<DirectorySelectorSourceDescriptor> {
  let provider: DirectoryProvider
  let config: DirectoryProviderConfig
  
  if (params.protocol === 'webdav') {
    provider = new WebDAVDirectoryProvider()
    config = {
      protocol: 'webdav',
      sourceId: params.sourceId,
      username: params.username,
      password: params.password,
      protocolSpecific: params.protocolSpecific
    }
  } else if (params.protocol === 'smb') {
    provider = new SmbDirectoryProvider()
    config = {
      protocol: 'smb',
      sourceId: params.sourceId,
      username: params.username,
      password: params.password,
      protocolSpecific: params.protocolSpecific
    }
  } else {
    throw new Error(`不支持的协议: ${params.protocol}`)
  }
  
  try {
    await provider.initWithConfig(config)
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    throw new Error(`初始化目录提供者失败: ${msg}`)
  }
  const descriptor: DirectorySelectorSourceDescriptor = {
    sourceId: params.sourceId,
    protocol: provider.getProtocolKey(),
    rootLabel: provider.getRootLabel(),
    endpointSummary: provider.getEndpointSummary(),
    provider: provider
  }
  return descriptor
}

/**
 * 从 WebDAV 配置构建路由参数
 */
export function buildWebDavDirectorySelectorRouteParams(
  sourceId: number,
  config: WebDAVSourceConfig
): Record<string, Object> {
  // 构建 baseUrl
  let serverAddress = config.url
  let port = config.port
  if (serverAddress.includes(':')) {
    const parts = serverAddress.split(':')
    serverAddress = parts[0]
    const portInUrl = parseInt(parts[1], 10)
    if (!Number.isNaN(portInUrl)) {
      port = portInUrl
    }
  }
  let baseUrl = `${config.protocol}://${serverAddress}:${port}`
  const normalizedPath = config.rootPath.trim().length > 0 ? config.rootPath.trim() : '/'
  if (normalizedPath !== '/') {
    baseUrl += normalizedPath.startsWith('/') ? normalizedPath : '/' + normalizedPath
  }
  
  const record: Record<string, Object> = {}
  record['sourceId'] = sourceId
  record['protocol'] = 'webdav'
  record['username'] = config.username
  record['password'] = config.password
  record['baseUrl'] = baseUrl
  record['tlsCertPolicy'] = config.tlsCertPolicy ?? 'allow_self_signed'
  return record
}

/**
 * 从 SMB 配置构建路由参数
 */
export function buildSmbDirectorySelectorRouteParams(
  sourceId: number,
  config: SMBSourceConfig
): Record<string, Object> {
  const record: Record<string, Object> = {}
  record['sourceId'] = sourceId
  record['protocol'] = 'smb'
  record['username'] = config.username
  record['password'] = config.password
  record['host'] = config.host
  record['port'] = config.port ?? 445
  record['domain'] = config.domain ?? ''
  record['shareName'] = ''
  return record
}
