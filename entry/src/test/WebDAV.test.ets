import { describe, it } from '@ohos/hypium'
import { WebDAVClient, WebDAVConfig } from '../main/ets/lib/WebDAVClient'

export default function webdavTest() {
  describe('WebDAV_client_tests', () => {
    it('connect success', 0, async () => {
      const config: WebDAVConfig = {
        baseUrl: 'http://192.168.3.59:5445/dav',
        username: 'yao',
        password: 'ys198756'
      }
      // const config: WebDAVConfig = {
      //   baseUrl: 'http://dav.mypikpak.com',
      //   username: 'cdkd',
      //   password: 'dartvjhx'
      // }

      const client = new WebDAVClient(config)
      await client.listDirectory()
    })
  })
}