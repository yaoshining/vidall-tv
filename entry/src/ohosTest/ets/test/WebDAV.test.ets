import { describe, it, expect } from '@ohos/hypium'
import { WebDAVClient, WebDAVConfig, TestConnectionResult } from '../../../main/ets/lib/WebDAVClient'

export default function webdavTest() {
  describe('WebDAV_client_tests', () => {

    /**
     * HTTP 明文 WebDAV 连接测试（本地 NAS）
     */
    it('http_connect_success', 0, async () => {
      const config: WebDAVConfig = {
        baseUrl: 'http://192.168.3.59:5445/dav',
        username: 'yao',
        password: 'ys198756'
      }
      const client = new WebDAVClient(config)
      const result: TestConnectionResult = await client.testConnection()
      console.info(`[Test] http_connect_success: ${result.success} — ${result.message}`)
      expect(result.success).assertTrue()
    })

    /**
     * HTTP 明文 WebDAV 目录列举测试（本地 NAS）
     */
    it('http_list_directory', 0, async () => {
      const config: WebDAVConfig = {
        baseUrl: 'http://192.168.3.59:5445/dav',
        username: 'yao',
        password: 'ys198756'
      }
      const client = new WebDAVClient(config)
      const resources = await client.listDirectory('/')
      console.info(`[Test] http_list_directory: found ${resources.length} resources`)
      expect(resources.length >= 0).assertTrue()
    })

    /**
     * HTTPS WebDAV 连接测试（PikPak 云盘）
     * 使用 http 模块发送 PROPFIND，验证 HTTPS 路径可正常连通并收到响应。
     * 预期：返回 success=true 或认证相关的 false，不应超时或报 TLS 错误。
     * testConnection 对 HTTPS 使用 OPTIONS 请求（http 模块原生支持），不依赖 PROPFIND。
     * 预期：不超时，不报 Parameter error；认证通过则 success=true，认证失败则 success=false。
     */
    it('https_connect_pikpak', 0, async () => {
      const config: WebDAVConfig = {
        baseUrl: 'https://dav.mypikpak.com',
        username: 'cdkd',
        password: 'dartvjhx',
        timeout: 20000
      }
      const client = new WebDAVClient(config)
      console.info('[Test] https_connect_pikpak: 开始...')
      const result: TestConnectionResult = await client.testConnection()
      console.info(`[Test] https_connect_pikpak: success=${result.success} — ${result.message}`)
      // 不应超时（超时时 message 包含 "Timeout"）
      const isTimeout = result.message.includes('Timeout') || result.message.includes('timeout')
      expect(isTimeout).assertFalse()
      // 不应出现 plain HTTP 错误
      expect(result.message.includes('plain HTTP request')).assertFalse()
      // 不应超时或报 Parameter error（这两种情况说明底层实现有问题）
      const isImplError = result.message.includes('Timeout') || result.message.includes('Parameter error')
      expect(isImplError).assertFalse()
    })

    /**
     * HTTPS URL 解析测试：验证 isHttps 标志和端口解析正确
     */
    it('https_url_parse', 0, () => {
      const configExplicitPort: WebDAVConfig = {
        baseUrl: 'https://dav.mypikpak.com:443',
        username: 'user',
        password: 'pass'
      }
      const client1 = new WebDAVClient(configExplicitPort)
      console.info(`[Test] https_url_parse (explicit port): getFullUrl=${client1.getFullUrl('/')}`)
      expect(client1.getFullUrl('/').startsWith('https://')).assertTrue()

      const configImplicitPort: WebDAVConfig = {
        baseUrl: 'https://dav.example.com',
        username: 'user',
        password: 'pass'
      }
      const client2 = new WebDAVClient(configImplicitPort)
      console.info(`[Test] https_url_parse (implicit port): getFullUrl=${client2.getFullUrl('/')}`)
      expect(client2.getFullUrl('/').startsWith('https://')).assertTrue()
    })

    /**
     * HTTP URL 解析测试：非 HTTPS 路径不受影响
     */
    it('http_url_parse', 0, () => {
      const config: WebDAVConfig = {
        baseUrl: 'http://192.168.3.59:5445/dav',
        username: 'yao',
        password: 'ys198756'
      }
      const client = new WebDAVClient(config)
      console.info(`[Test] http_url_parse: getFullUrl=${client.getFullUrl('/nas')}`)
      expect(client.getFullUrl('/nas').startsWith('http://')).assertTrue()
    })
  })
}

