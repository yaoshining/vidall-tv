import { BusinessError } from '@kit.BasicServicesKit';
import { FileSource, FileSourceType, SMBSourceConfig, WebDAVSourceConfig } from '../../db/models/FileSourceEntity';
import { SMBClient, SmbListDirectoryResult } from '../../lib/SMBClient';
import { WebDAVClient } from '../../lib/WebDAVClient';
import { WebDAVConfig, WebDAVResource } from '../../lib/WebDavTypes';
import { isExactMissingMediaPathMatch } from './MissingMediaPathUtils';
import {
  MissingMediaDirectoryGroup,
  MissingMediaVerificationResult,
  MissingMediaVerificationStatus,
  MissingMediaVideoRef
} from './MissingMediaSyncTypes';

function createGroupResults(
  group: MissingMediaDirectoryGroup,
  status: MissingMediaVerificationStatus
): MissingMediaVerificationResult[] {
  const results: MissingMediaVerificationResult[] = [];
  for (const video of group.videos) {
    const result: MissingMediaVerificationResult = { videoId: video.videoId, status };
    results.push(result);
  }
  return results;
}

function classifyListedPaths(
  videos: MissingMediaVideoRef[],
  listedPaths: string[]
): MissingMediaVerificationResult[] {
  const results: MissingMediaVerificationResult[] = [];
  for (const video of videos) {
    let exists = false;
    for (const listedPath of listedPaths) {
      if (isExactMissingMediaPathMatch(video.filePath, listedPath)) {
        exists = true;
        break;
      }
    }
    const result: MissingMediaVerificationResult = {
      videoId: video.videoId,
      status: exists ? MissingMediaVerificationStatus.EXISTS : MissingMediaVerificationStatus.MISSING
    };
    results.push(result);
  }
  return results;
}

function isSmbMissingError(error: string): boolean {
  const normalized = error.toLowerCase();
  return normalized.includes('nt_status_object_name_not_found') ||
    normalized.includes('nt_status_object_path_not_found') ||
    normalized.includes('no such file or directory');
}

export class MissingMediaVerifier {
  async verifyGroup(
    source: FileSource | null,
    group: MissingMediaDirectoryGroup
  ): Promise<MissingMediaVerificationResult[]> {
    if (source === null) {
      return createGroupResults(group, MissingMediaVerificationStatus.UNCONFIRMED);
    }
    if (source.type === FileSourceType.WEBDAV) {
      return this.verifyWebDav(source, group);
    }
    if (source.type === FileSourceType.SMB) {
      return this.verifySmb(source, group);
    }
    return createGroupResults(group, MissingMediaVerificationStatus.UNCONFIRMED);
  }

  private async verifyWebDav(
    source: FileSource,
    group: MissingMediaDirectoryGroup
  ): Promise<MissingMediaVerificationResult[]> {
    try {
      const config = JSON.parse(source.configJson) as WebDAVSourceConfig;
      const protocol = config.protocol ?? 'http';
      const port = config.port ?? (protocol === 'https' ? 443 : 80);
      const rootPath = config.rootPath ?? '';
      const normalizedRoot = rootPath.length > 0 && !rootPath.startsWith('/') ? `/${rootPath}` : rootPath;
      const webDavConfig: WebDAVConfig = {
        baseUrl: `${protocol}://${config.url}:${port}${normalizedRoot.replace(/\/$/, '')}`,
        username: config.username,
        password: config.password,
        tlsCertPolicy: config.tlsCertPolicy
      };
      const resources = await new WebDAVClient(webDavConfig).listDirectory(group.directoryPath);
      const listedPaths: string[] = [];
      for (const resource of resources) {
        const path = this.webDavResourcePath(group.directoryPath, resource);
        if (!resource.isCollection) {
          listedPaths.push(path);
        }
      }
      return classifyListedPaths(group.videos, listedPaths);
    } catch (e) {
      const error = e as BusinessError;
      if ((error.message ?? '').includes('HTTP 404')) {
        return createGroupResults(group, MissingMediaVerificationStatus.MISSING);
      }
      return createGroupResults(group, MissingMediaVerificationStatus.UNCONFIRMED);
    }
  }

  private webDavResourcePath(directoryPath: string, resource: WebDAVResource): string {
    const displayName = resource.displayName;
    if (displayName.length > 0) {
      return `${directoryPath}/${displayName}`;
    }
    return resource.href;
  }

  private async verifySmb(
    source: FileSource,
    group: MissingMediaDirectoryGroup
  ): Promise<MissingMediaVerificationResult[]> {
    try {
      const config = JSON.parse(source.configJson) as SMBSourceConfig;
      const result: SmbListDirectoryResult = await SMBClient.fromSourceConfig(config)
        .listDirectory(group.directoryPath);
      if (result.error !== undefined && result.error.length > 0) {
        const status = isSmbMissingError(result.error)
          ? MissingMediaVerificationStatus.MISSING
          : MissingMediaVerificationStatus.UNCONFIRMED;
        return createGroupResults(group, status);
      }
      const listedPaths: string[] = [];
      for (const file of result.files) {
        if (!file.isDirectory) {
          listedPaths.push(file.path);
        }
      }
      return classifyListedPaths(group.videos, listedPaths);
    } catch {
      return createGroupResults(group, MissingMediaVerificationStatus.UNCONFIRMED);
    }
  }
}

export const defaultMissingMediaVerifier = new MissingMediaVerifier();
