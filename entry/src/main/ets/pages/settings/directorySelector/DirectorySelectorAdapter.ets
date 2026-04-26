import { SMBSourceConfig, WebDAVSourceConfig } from "../../../db/models/FileSourceEntity"
import { getFileExplorerErrorMessage } from "../../../components/core/file/FileExplorerAdapter"
import { WebDAVClient, WebDAVConfig, WebDAVResource } from "../../../lib/WebDAVClient"
import { SMBClient, SMBClientConfig, SmbFileInfo, SmbListDirectoryResult } from "../../../lib/SMBClient"

export interface DirectorySelectorEntry {
  key: string
  name: string
  path: string
}

export interface DirectorySelectorLoadResult {
  entries: DirectorySelectorEntry[]
  errorMessage?: string
}

export interface DirectorySelectorSourceAdapter {
  readonly protocolKey: string
  readonly rootLabel: string
  readonly endpointSummary: string
  load(path: string): Promise<DirectorySelectorLoadResult>
}

export interface DirectorySelectorRouteParams {
  sourceId: number
  protocolKey: 'webdav' | 'smb'
  username: string
  password: string
  baseUrl?: string
  host?: string
  port?: number
  domain?: string
}

export interface DirectorySelectorSourceDescriptor {
  sourceId: number
  protocolKey: string
  rootLabel: string
  endpointSummary: string
  adapter: DirectorySelectorSourceAdapter
}

function buildDirectorySelectorLoadResult(entries: DirectorySelectorEntry[], errorMessage?: string): DirectorySelectorLoadResult {
  const result: DirectorySelectorLoadResult = {
    entries: entries,
    errorMessage: errorMessage
  }
  return result
}

function joinDirectorySelectorPath(parentPath: string, childName: string): string {
  if (parentPath === '/') {
    return '/' + childName
  }
  return parentPath.endsWith('/') ? parentPath + childName : parentPath + '/' + childName
}

function createDirectorySelectorEntry(name: string, path: string): DirectorySelectorEntry {
  const entry: DirectorySelectorEntry = {
    key: path,
    name: name,
    path: path
  }
  return entry
}

function createDirectorySelectorEntryFromWebDav(currentPath: string, resource: WebDAVResource): DirectorySelectorEntry {
  return createDirectorySelectorEntry(resource.displayName, joinDirectorySelectorPath(currentPath, resource.displayName))
}

function createDirectorySelectorEntryFromSmb(file: SmbFileInfo): DirectorySelectorEntry {
  return createDirectorySelectorEntry(file.name, file.path)
}

function readStringParam(params: Record<string, Object>, key: string): string {
  const value = params[key]
  return typeof value === 'string' ? value : ''
}

function readNumberParam(params: Record<string, Object>, key: string): number | undefined {
  const value = params[key]
  return typeof value === 'number' ? value : undefined
}

export class EmptyDirectorySelectorSourceAdapter implements DirectorySelectorSourceAdapter {
  readonly protocolKey: string = 'empty'
  readonly rootLabel: string = '根目录'
  readonly endpointSummary: string = ''

  async load(_path: string): Promise<DirectorySelectorLoadResult> {
    return buildDirectorySelectorLoadResult([])
  }
}

export class WebDavDirectorySelectorAdapter implements DirectorySelectorSourceAdapter {
  readonly protocolKey: string = 'webdav'
  readonly rootLabel: string = '根目录'
  readonly endpointSummary: string
  private readonly listDirectory: (path: string) => Promise<WebDAVResource[]>

  constructor(listDirectory: (path: string) => Promise<WebDAVResource[]>, endpointSummary: string) {
    this.listDirectory = listDirectory
    this.endpointSummary = endpointSummary
  }

  async load(path: string): Promise<DirectorySelectorLoadResult> {
    try {
      const resources = await this.listDirectory(path)
      const entries = resources
        .filter((resource: WebDAVResource, index: number) => resource.isCollection && index > 0)
        .map((resource: WebDAVResource) => createDirectorySelectorEntryFromWebDav(path, resource))
      return buildDirectorySelectorLoadResult(entries)
    } catch (error) {
      return buildDirectorySelectorLoadResult([], getFileExplorerErrorMessage(error))
    }
  }
}

export class SmbDirectorySelectorAdapter implements DirectorySelectorSourceAdapter {
  readonly protocolKey: string = 'smb'
  readonly rootLabel: string = '共享列表'
  readonly endpointSummary: string
  private readonly listDirectory: (path: string) => Promise<SmbListDirectoryResult>

  constructor(listDirectory: (path: string) => Promise<SmbListDirectoryResult>, endpointSummary: string) {
    this.listDirectory = listDirectory
    this.endpointSummary = endpointSummary
  }

  async load(path: string): Promise<DirectorySelectorLoadResult> {
    try {
      const result = await this.listDirectory(path)
      const entries = result.files
        .filter((file: SmbFileInfo) => file.isDirectory)
        .map((file: SmbFileInfo) => createDirectorySelectorEntryFromSmb(file))
      const errorMessage = result.error !== undefined && result.error.length > 0 && entries.length === 0
        ? result.error
        : undefined
      return buildDirectorySelectorLoadResult(entries, errorMessage)
    } catch (error) {
      return buildDirectorySelectorLoadResult([], getFileExplorerErrorMessage(error))
    }
  }
}

function buildWebDavBaseUrl(config: WebDAVSourceConfig): string {
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
  return baseUrl
}

export function buildWebDavDirectorySelectorRouteParams(
  sourceId: number,
  config: WebDAVSourceConfig
): DirectorySelectorRouteParams {
  const routeParams: DirectorySelectorRouteParams = {
    sourceId: sourceId,
    protocolKey: 'webdav',
    baseUrl: buildWebDavBaseUrl(config),
    username: config.username,
    password: config.password
  }
  return routeParams
}

export function buildSmbDirectorySelectorRouteParams(
  sourceId: number,
  config: SMBSourceConfig
): DirectorySelectorRouteParams {
  const routeParams: DirectorySelectorRouteParams = {
    sourceId: sourceId,
    protocolKey: 'smb',
    host: config.host,
    username: config.username,
    password: config.password,
    port: config.port ?? 445,
    domain: config.domain ?? ''
  }
  return routeParams
}

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
  const protocolKey = readStringParam(params, 'protocolKey')
  if (protocolKey === 'webdav' || (protocolKey.length === 0 && readStringParam(params, 'baseUrl').length > 0)) {
    const routeParams: DirectorySelectorRouteParams = {
      sourceId: sourceId,
      protocolKey: 'webdav',
      baseUrl: readStringParam(params, 'baseUrl'),
      username: readStringParam(params, 'username'),
      password: readStringParam(params, 'password')
    }
    return routeParams
  }
  if (protocolKey === 'smb' || (protocolKey.length === 0 && readStringParam(params, 'host').length > 0)) {
    const routeParams: DirectorySelectorRouteParams = {
      sourceId: sourceId,
      protocolKey: 'smb',
      host: readStringParam(params, 'host'),
      username: readStringParam(params, 'username'),
      password: readStringParam(params, 'password'),
      port: readNumberParam(params, 'port') ?? 445,
      domain: readStringParam(params, 'domain')
    }
    return routeParams
  }
  return undefined
}

export function createDirectorySelectorSourceDescriptor(
  params: DirectorySelectorRouteParams
): DirectorySelectorSourceDescriptor {
  if (params.protocolKey === 'webdav') {
    if (params.baseUrl === undefined || params.baseUrl.length === 0) {
      throw new Error('WebDAV protocol requires baseUrl')
    }
    const config: WebDAVConfig = {
      baseUrl: params.baseUrl,
      username: params.username,
      password: params.password,
      timeout: 10000
    }
    const client = new WebDAVClient(config)
    const adapter = new WebDavDirectorySelectorAdapter(
      (path: string): Promise<WebDAVResource[]> => client.listDirectory(path),
      params.baseUrl
    )
    const descriptor: DirectorySelectorSourceDescriptor = {
      sourceId: params.sourceId,
      protocolKey: adapter.protocolKey,
      rootLabel: adapter.rootLabel,
      endpointSummary: adapter.endpointSummary,
      adapter: adapter
    }
    return descriptor
  }

  if (params.host === undefined || params.host.length === 0) {
    throw new Error('SMB protocol requires host')
  }
  const config: SMBClientConfig = {
    host: params.host,
    port: params.port ?? 445,
    username: params.username,
    password: params.password,
    domain: params.domain ?? '',
    timeoutMs: 10000
  }
  const client = new SMBClient(config)
  const endpointSummary = `smb://${config.host}:${config.port}`
  const adapter = new SmbDirectorySelectorAdapter(
    (path: string): Promise<SmbListDirectoryResult> => client.listDirectory(path),
    endpointSummary
  )
  const descriptor: DirectorySelectorSourceDescriptor = {
    sourceId: params.sourceId,
    protocolKey: adapter.protocolKey,
    rootLabel: adapter.rootLabel,
    endpointSummary: adapter.endpointSummary,
    adapter: adapter
  }
  return descriptor
}

export function createDirectorySelectorRecordParams(params: DirectorySelectorRouteParams): Record<string, Object> {
  const record: Record<string, Object> = {}
  record['sourceId'] = params.sourceId
  record['protocolKey'] = params.protocolKey
  record['username'] = params.username
  record['password'] = params.password
  if (params.baseUrl !== undefined) {
    record['baseUrl'] = params.baseUrl
  }
  if (params.host !== undefined) {
    record['host'] = params.host
  }
  if (params.port !== undefined) {
    record['port'] = params.port
  }
  if (params.domain !== undefined) {
    record['domain'] = params.domain
  }
  return record
}
