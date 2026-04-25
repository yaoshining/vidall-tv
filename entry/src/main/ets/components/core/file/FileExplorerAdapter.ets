import { WebDAVResource } from "../../../lib/WebDAVClient";
import { SmbListDirectoryResult } from "../../../lib/SMBClient";
import {
  createFileExplorerResourceFromSmb,
  createFileExplorerResourceFromWebDav,
  FileExplorerAdapter,
  FileExplorerLoadResult,
  FileExplorerResource
} from "./FileExplorerController";

export type WebDavListDirectory = (path: string) => Promise<WebDAVResource[]>;

export type SmbListDirectory = (path: string) => Promise<SmbListDirectoryResult>;

export interface FileExplorerErrorMessageCarrier {
  message: string;
}

export type FileExplorerErrorValue = Error | string | FileExplorerErrorMessageCarrier | Object | undefined | null;

function buildLoadResult(resources: FileExplorerResource[], errorMessage?: string): FileExplorerLoadResult {
  const result: FileExplorerLoadResult = {
    resources: resources,
    errorMessage: errorMessage
  };
  return result;
}

function isFileExplorerErrorMessageCarrier(error: FileExplorerErrorValue): boolean {
  if (error === undefined || error === null || typeof error === 'string' || error instanceof Error) {
    return false;
  }
  const carrier = error as FileExplorerErrorMessageCarrier;
  return carrier.message !== undefined && carrier.message.length > 0;
}

export function getFileExplorerErrorMessage(error: FileExplorerErrorValue): string {
  if (typeof error === 'string' && error.length > 0) {
    return error;
  }
  if (error instanceof Error && error.message.length > 0) {
    return error.message;
  }
  if (isFileExplorerErrorMessageCarrier(error)) {
    const carrier = error as FileExplorerErrorMessageCarrier;
    return carrier.message;
  }
  if (error !== undefined && error !== null) {
    const fallbackMessage = String(error);
    if (fallbackMessage.length > 0 && fallbackMessage !== '[object Object]') {
      return fallbackMessage;
    }
  }
  return '加载目录失败';
}

export class WebDavFileExplorerAdapter implements FileExplorerAdapter {
  private readonly listDirectory: WebDavListDirectory;

  constructor(listDirectory: WebDavListDirectory) {
    this.listDirectory = listDirectory;
  }

  async list(path: string): Promise<FileExplorerLoadResult> {
    try {
      const rawResources = await this.listDirectory(path);
      const mappedResources = rawResources
        .filter((resource: WebDAVResource, index: number) => index > 0)
        .map((resource: WebDAVResource) => createFileExplorerResourceFromWebDav(path, resource));
      return buildLoadResult(mappedResources);
    } catch (error) {
      const typedError = error as FileExplorerErrorValue;
      return buildLoadResult([], getFileExplorerErrorMessage(typedError));
    }
  }
}

export class SmbFileExplorerAdapter implements FileExplorerAdapter {
  private readonly listDirectory: SmbListDirectory;

  constructor(listDirectory: SmbListDirectory) {
    this.listDirectory = listDirectory;
  }

  async list(path: string): Promise<FileExplorerLoadResult> {
    try {
      const result = await this.listDirectory(path);
      if (result.error !== undefined && result.error.length > 0) {
        return buildLoadResult([], result.error);
      }
      const mappedResources = result.files.map(createFileExplorerResourceFromSmb);
      return buildLoadResult(mappedResources);
    } catch (error) {
      const typedError = error as FileExplorerErrorValue;
      return buildLoadResult([], getFileExplorerErrorMessage(typedError));
    }
  }
}
