import { WebDAVResource } from './WebDavTypes';

/** 重定向目标（由 parseRedirectUrl 解析得到） */
export interface RedirectTarget {
  host: string;
  port: number;
  path: string;
  isHttps: boolean;
}

/**
 * WebDAV XML 与重定向 URL 解析（无状态纯函数）。
 * 拆分自 WebDAVClient.ets。
 */
export class WebDavXmlParser {
  parsePropfindResponse(xmlText: string): WebDAVResource[] {
    const resources: WebDAVResource[] = [];

    try {
      if (xmlText.includes('<html') || xmlText.includes('<HTML')) {
        console.error('[WebDAVClient] PROPFIND 返回 HTML 而非 WebDAV XML，可能 rootPath 配置不正确');
        throw new Error('服务器返回了网页而非 WebDAV 响应，请检查 WebDAV 根路径(rootPath)配置是否正确');
      }

      const responsePattern = /<(?:D:)?response[^>]*>([\s\S]*?)<\/(?:D:)?response>/gi;
      const matches = Array.from(xmlText.matchAll(responsePattern));

      console.info(`Found ${matches.length} resources`);

      for (let i = 0; i < matches.length; i++) {
        const match = matches[i];
        const responseXml = match[1];

        const href = this.extractXmlValue(responseXml, 'href');
        const displayName = this.extractXmlValue(responseXml, 'displayname');
        const size = this.extractXmlValue(responseXml, 'getcontentlength');
        const lastModified = this.extractXmlValue(responseXml, 'getlastmodified');
        const contentType = this.extractXmlValue(responseXml, 'getcontenttype');
        const isCollection = responseXml.includes('<collection') || responseXml.includes(':collection');

        if (href) {
          const pathParts = href.split('/');
          const filteredParts: string[] = [];
          for (let j = 0; j < pathParts.length; j++) {
            if (pathParts[j]) {
              filteredParts.push(pathParts[j]);
            }
          }
          const lastPart = filteredParts.length > 0 ? filteredParts[filteredParts.length - 1] : '';

          resources.push({
            href: href,
            displayName: displayName || decodeURIComponent(lastPart),
            isCollection: isCollection,
            size: size ? parseInt(size) : undefined,
            lastModified: lastModified,
            contentType: contentType
          });
        }
      }
    } catch (error) {
      console.error('Parse error:', JSON.stringify(error));
    }

    return resources;
  }

  private extractXmlValue(xml: string, tagName: string): string {
    const patterns = [
      new RegExp(`<D:${tagName}[^>]*>([\\s\\S]*?)<\\/D:${tagName}>`, 'i'),
      new RegExp(`<d:${tagName}[^>]*>([\\s\\S]*?)<\\/d:${tagName}>`, 'i'),
      new RegExp(`<${tagName}[^>]*>([\\s\\S]*?)<\\/${tagName}>`, 'i')
    ];

    for (let i = 0; i < patterns.length; i++) {
      const match = xml.match(patterns[i]);
      if (match) {
        return this.decodeXmlEntities(match[1].trim());
      }
    }

    return '';
  }

  private decodeXmlEntities(text: string): string {
    return text
      .replace(/&amp;/g, '&')
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'");
  }

  /**
   * 解析重定向 URL。
   * @param host/port/isHttps 相对路径重定向时使用的当前连接信息
   */
  parseRedirectUrl(url: string, host: string, port: number, isHttps: boolean): RedirectTarget {
    // 支持相对路径和绝对路径
    if (url.startsWith('http://') || url.startsWith('https://')) {
      // 绝对URL
      const urlPattern = /^(https?):\/\/([^:\/]+)(?::(\d+))?(\/.*)?$/;
      const match = url.match(urlPattern);

      if (match) {
        const targetIsHttps = match[1] === 'https';
        const targetHost = match[2];
        const targetPort = match[3] ? parseInt(match[3]) : (targetIsHttps ? 443 : 80);
        const targetPath = match[4] || '/';

        return { host: targetHost, port: targetPort, path: targetPath, isHttps: targetIsHttps };
      } else {
        throw new Error('Invalid redirect URL format');
      }
    } else if (url.startsWith('/')) {
      // 相对路径（同一主机）
      return {
        host: host,
        port: port,
        path: url,
        isHttps: isHttps
      };
    } else {
      throw new Error('Unsupported redirect URL format');
    }
  }
}
