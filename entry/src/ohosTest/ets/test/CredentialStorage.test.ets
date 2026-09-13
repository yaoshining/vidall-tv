import { describe, it, expect } from '@ohos/hypium';
import { huks } from '@kit.UniversalKeystoreKit';
import relationalStore from '@ohos.data.relationalStore';
import { Context } from '@kit.AbilityKit';
import { CredentialCipher } from '../../../main/ets/utils/CryptoUtil';
import { CredentialCodec, CredentialStorage } from '../../../main/ets/db/files/CredentialStorage';
import { FileSourceDbCore } from '../../../main/ets/db/files/FileSourceDbCore';
import { FileSourceDao } from '../../../main/ets/db/files/FileSourceDao';
import { VideoServerDao } from '../../../main/ets/db/files/VideoServerDao';
import { FileSourceType } from '../../../main/ets/db/models/FileSourceEntity';
import { VideoServerType } from '../../../main/ets/db/models/VideoServerEntity';
import { CREDENTIAL_FAILURE, parseCredentialConfig } from '../../../main/ets/utils/CredentialConfig';

// 固定测试夹具，无真实账户；生产代码没有旧格式加密入口。
const LEGACY = 'BwcHBwcHBwcHBwcHBwcHBw==:pJ/rjbPCm0f1Po3IgKeljiX3TxOSkHSsg3V1Vz13c+s=';
const FIXTURE = 'credential-fixture-测试';
let sequence = 0;
const KEY_OPTIONS: huks.HuksOptions = { properties: [
  { tag: huks.HuksTag.HUKS_TAG_AUTH_STORAGE_LEVEL, value: huks.HuksAuthStorageLevel.HUKS_AUTH_STORAGE_LEVEL_DE }
] };

class IsolatedCore extends FileSourceDbCore {
  private store: relationalStore.RdbStore;
  constructor(store: relationalStore.RdbStore) { super(); this.store = store; }
  getStore(): relationalStore.RdbStore { return this.store; }
}

class ControlledCodec implements CredentialCodec {
  cipher: CredentialCipher;
  failEncrypt: boolean = false;
  beforeEncrypt: (() => Promise<void>) | undefined = undefined;
  constructor(cipher: CredentialCipher) { this.cipher = cipher; }
  async encrypt(value: string, scope: string): Promise<string> {
    if (this.beforeEncrypt !== undefined) {
      const callback = this.beforeEncrypt;
      this.beforeEncrypt = undefined;
      await callback();
    }
    if (this.failEncrypt) { throw new Error('injected failure'); }
    return this.cipher.encrypt(value, scope);
  }
  decrypt(value: string, scope: string): Promise<string> { return this.cipher.decrypt(value, scope); }
}

class Fixture {
  store: relationalStore.RdbStore;
  codec: ControlledCodec;
  storage: CredentialStorage;
  files: FileSourceDao;
  servers: VideoServerDao;
  constructor(store: relationalStore.RdbStore, cipher: CredentialCipher) {
    this.store = store;
    this.codec = new ControlledCodec(cipher);
    this.storage = new CredentialStorage(this.codec);
    const core = new IsolatedCore(store);
    this.files = new FileSourceDao(core, this.storage);
    this.servers = new VideoServerDao(core, this.storage);
  }
  async insert(table: string, json: string): Promise<number> {
    if (table === 'file_sources') {
      return this.files.insertFileSource({ name: 'isolated', type: FileSourceType.WEBDAV, configJson: json, createdAt: 1 });
    }
    return this.servers.insertVideoServer({ name: 'isolated', type: VideoServerType.JELLYFIN, configJson: json, createdAt: 1 });
  }
  async read(table: string, id: number): Promise<string> {
    if (table === 'file_sources') {
      const row = await this.files.getFileSourceById(id);
      if (row === null) { throw new Error('missing test row'); }
      return row.configJson;
    }
    const row = await this.servers.getVideoServerById(id);
    if (row === null) { throw new Error('missing test row'); }
    return row.configJson;
  }
  async save(table: string, id: number, json: string): Promise<void> {
    if (table === 'file_sources') {
      await this.files.updateFileSource({ id, name: 'edited', type: FileSourceType.WEBDAV, configJson: json, createdAt: 1 });
    } else {
      await this.servers.updateVideoServer({ id, name: 'edited', type: VideoServerType.JELLYFIN, configJson: json, createdAt: 1 });
    }
  }
  raw(table: string, id: number): Promise<string> { return this.storage.raw(this.store, table, id); }
  async seed(table: string, json: string): Promise<number> {
    return this.store.insert(table, { name: 'isolated', type: 'webdav', config_json: json, created_at: 1 });
  }
}

async function isolated(context: Context, verify: (f: Fixture, alias: string) => Promise<void>): Promise<void> {
  const suffix = Date.now() + '_' + (++sequence);
  const name = 'VIDALL_CREDENTIAL_TEST_' + suffix + '.db';
  const alias = 'vidall.credential.test.' + suffix;
  const store = await relationalStore.getRdbStore(context, { name, securityLevel: relationalStore.SecurityLevel.S1 });
  try {
    for (const table of ['file_sources', 'video_servers']) {
      await store.executeSql('CREATE TABLE ' + table + ' (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, type TEXT, config_json TEXT, created_at INTEGER)');
    }
    await verify(new Fixture(store, new CredentialCipher(alias)), alias);
  } finally {
    await store.close();
    await relationalStore.deleteRdbStore(context, name);
    if (await huks.hasKeyItem(alias, KEY_OPTIONS)) { await huks.deleteKeyItem(alias, KEY_OPTIONS); }
  }
}

async function rejects(work: () => Promise<void>): Promise<void> {
  let rejected = false;
  try { await work(); } catch { rejected = true; }
  expect(rejected).assertTrue();
}

export default function credentialStorageTest(context: Context) {
  describe('CredentialStorage_platform', () => {
    it('huks_roundtrip_randomness_unicode_empty_reuse', 0, async () => {
      await isolated(context, async (f: Fixture, alias: string) => {
        const cipher = f.codec.cipher;
        const values = await Promise.all([cipher.encrypt(FIXTURE, 'scope'), cipher.encrypt(FIXTURE, 'scope')]);
        expect(values[0] !== values[1]).assertTrue();
        expect(values[0].startsWith('v2:')).assertTrue();
        expect(await new CredentialCipher(alias).decrypt(values[0], 'scope')).assertEqual(FIXTURE);
        expect(await cipher.decrypt(await cipher.encrypt('', 'scope'), 'scope')).assertEqual('');
      });
    });
    it('huks_tamper_scope_wrong_key_missing_key_no_recreate', 0, async () => {
      await isolated(context, async (f: Fixture, alias: string) => {
        const cipher = f.codec.cipher;
        const value = await cipher.encrypt(FIXTURE, 'scope');
        const parts = value.split(':');
        parts[2] = (parts[2][0] === 'A' ? 'B' : 'A') + parts[2].slice(1);
        await rejects(async () => { await cipher.decrypt(parts.join(':'), 'scope'); });
        await rejects(async () => { await cipher.decrypt(value, 'other'); });
        await rejects(async () => { await cipher.decrypt('v3:unknown', 'scope'); });
        await huks.deleteKeyItem(alias, KEY_OPTIONS);
        await rejects(async () => { await cipher.decrypt(value, 'scope'); });
        expect(await huks.hasKeyItem(alias, KEY_OPTIONS)).assertFalse();
        await cipher.encrypt('replacement-fixture', 'scope');
        await rejects(async () => { await cipher.decrypt(value, 'scope'); });
      });
    });
    for (const table of ['file_sources', 'video_servers']) {
      it(table + '_real_crud_and_delete_retains_shared_key', 0, async () => {
        await isolated(context, async (f: Fixture, alias: string) => {
          const id = await f.insert(table, JSON.stringify({ password: FIXTURE }));
          expect(id > 0).assertTrue();
          expect((JSON.parse(await f.raw(table, id)) as Record<string, string>).password.startsWith('v2:')).assertTrue();
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual(FIXTURE);
          await f.save(table, id, JSON.stringify({ password: 'edited-fixture' }));
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual('edited-fixture');
          const second = await f.insert(table, JSON.stringify({ password: FIXTURE }));
          if (table === 'file_sources') { await f.files.deleteFileSource(id); } else { await f.servers.deleteVideoServer(id); }
          expect(await huks.hasKeyItem(alias, KEY_OPTIONS)).assertTrue();
          expect((JSON.parse(await f.read(table, second)) as Record<string, string>).password).assertEqual(FIXTURE);
        });
      });
      it(table + '_legacy_migration_retry_and_idempotence', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const raw = JSON.stringify({ password: LEGACY });
          const id = await f.seed(table, raw);
          f.codec.failEncrypt = true;
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual(FIXTURE);
          expect(await f.raw(table, id)).assertEqual(raw);
          f.codec.failEncrypt = false;
          await f.read(table, id);
          const migrated = await f.raw(table, id);
          expect(migrated !== raw).assertTrue();
          await f.read(table, id);
          expect(await f.raw(table, id)).assertEqual(migrated);
        });
      });
      it(table + '_migration_database_failure_preserves_and_retry', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const raw = JSON.stringify({ password: LEGACY });
          const id = await f.seed(table, raw);
          await f.store.executeSql('CREATE TRIGGER deny_migration BEFORE UPDATE ON ' + table +
            " BEGIN SELECT RAISE(ABORT, 'isolated write failure'); END");
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual(FIXTURE);
          expect(await f.raw(table, id)).assertEqual(raw);
          await f.store.executeSql('DROP TRIGGER deny_migration');
          await f.read(table, id);
          expect((JSON.parse(await f.raw(table, id)) as Record<string, string>).password.startsWith('v2:')).assertTrue();
        });
      });
      it(table + '_blank_edit_preserves_even_after_key_recovers', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const id = await f.insert(table, JSON.stringify({ password: FIXTURE }));
          const raw = await f.raw(table, id);
          // 模拟失败后的表单空值；保存时系统密钥已可用，仍不得擦除。
          await f.save(table, id, '{"password":"","_credentialReadFailures":["password"]}');
          expect(await f.raw(table, id)).assertEqual(raw);
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual(FIXTURE);
        });
      });
      it(table + '_failed_read_save_preserves_and_reentry_recovers', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const raw = JSON.stringify({ password: 'corrupt-fixture' });
          const id = await f.seed(table, raw);
          const read = await f.read(table, id);
          const config = JSON.parse(read) as Record<string, Object>;
          expect(config.password).assertEqual('');
          expect(config[CREDENTIAL_FAILURE] !== undefined).assertTrue();
          let blocked = false;
          try { parseCredentialConfig(read); } catch { blocked = true; }
          expect(blocked).assertTrue();
          await f.save(table, id, read);
          expect(await f.raw(table, id)).assertEqual(raw);
          await f.save(table, id, '{}');
          expect((JSON.parse(await f.raw(table, id)) as Record<string, string>).password).assertEqual('corrupt-fixture');
          await f.save(table, id, JSON.stringify({ password: FIXTURE }));
          const recovered = JSON.parse(await f.read(table, id)) as Record<string, Object>;
          expect(recovered[CREDENTIAL_FAILURE] === undefined).assertTrue();
          expect(recovered.password).assertEqual(FIXTURE);
        });
      });
      it(table + '_migration_does_not_overwrite_concurrent_save', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const id = await f.seed(table, JSON.stringify({ password: LEGACY }));
          f.codec.beforeEncrypt = async () => {
            await f.save(table, id, JSON.stringify({ password: 'concurrent-fixture' }));
          };
          await f.read(table, id);
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual('concurrent-fixture');
        });
      });
      it(table + '_concurrent_saves_conflict_and_encrypt_failure_preserves', 0, async () => {
        await isolated(context, async (f: Fixture) => {
          const id = await f.insert(table, JSON.stringify({ password: FIXTURE }));
          const raw = await f.raw(table, id);
          f.codec.failEncrypt = true;
          await rejects(async () => { await f.save(table, id, JSON.stringify({ password: 'rejected-fixture' })); });
          expect(await f.raw(table, id)).assertEqual(raw);
          f.codec.failEncrypt = false;
          f.codec.beforeEncrypt = async () => {
            await f.save(table, id, JSON.stringify({ password: 'winner-fixture' }));
          };
          await rejects(async () => { await f.save(table, id, JSON.stringify({ password: 'stale-fixture' })); });
          expect((JSON.parse(await f.read(table, id)) as Record<string, string>).password).assertEqual('winner-fixture');
        });
      });
      it(table + '_missing_key_restore_keeps_ciphertext_and_import_rejected', 0, async () => {
        await isolated(context, async (f: Fixture, alias: string) => {
          const id = await f.insert(table, JSON.stringify({ password: FIXTURE }));
          const raw = await f.raw(table, id);
          await rejects(async () => { await f.insert(table, raw); });
          await huks.deleteKeyItem(alias, KEY_OPTIONS);
          const read = await f.read(table, id);
          await f.save(table, id, read);
          expect(await f.raw(table, id)).assertEqual(raw);
          expect(await huks.hasKeyItem(alias, KEY_OPTIONS)).assertFalse();
        });
      });
    }
    it('video_servers_partial_field_failure_preserves_entire_migration', 0, async () => {
      await isolated(context, async (f: Fixture) => {
        const raw = JSON.stringify({ password: LEGACY, apiKey: 'invalid-fixture', token: LEGACY });
        const id = await f.seed('video_servers', raw);
        const json = await f.read('video_servers', id);
        const read = JSON.parse(json) as Record<string, Object>;
        expect(read.password).assertEqual(FIXTURE);
        expect(read.token).assertEqual(FIXTURE);
        expect(read.apiKey).assertEqual('');
        expect(await f.raw('video_servers', id)).assertEqual(raw);
        await f.save('video_servers', id, json);
        expect((JSON.parse(await f.raw('video_servers', id)) as Record<string, string>).apiKey).assertEqual('invalid-fixture');
        await f.save('video_servers', id, JSON.stringify({ password: FIXTURE, apiKey: 'new-fixture', token: FIXTURE }));
        const recovered = await f.read('video_servers', id);
        expect((JSON.parse(recovered) as Record<string, Object>)[CREDENTIAL_FAILURE] === undefined).assertTrue();
        expect((await f.servers.getAllVideoServers()).length).assertEqual(1);
      });
    });
    it('video_servers_all_sensitive_fields_migrate_and_read_back', 0, async () => {
      await isolated(context, async (f: Fixture) => {
        const id = await f.seed('video_servers', JSON.stringify({ password: LEGACY, apiKey: LEGACY, token: LEGACY }));
        const plain = JSON.parse(await f.read('video_servers', id)) as Record<string, string>;
        const stored = JSON.parse(await f.raw('video_servers', id)) as Record<string, string>;
        for (const field of ['password', 'apiKey', 'token']) {
          expect(plain[field]).assertEqual(FIXTURE);
          expect(stored[field].startsWith('v2:')).assertTrue();
        }
        const reread = JSON.parse(await f.read('video_servers', id)) as Record<string, string>;
        for (const field of ['password', 'apiKey', 'token']) { expect(reread[field]).assertEqual(FIXTURE); }
      });
    });
    it('no_credentials_is_distinct_from_read_failure', 0, async () => {
      await isolated(context, async (f: Fixture) => {
        const id = await f.insert('file_sources', '{"password":""}');
        const read = await f.read('file_sources', id);
        expect((JSON.parse(read) as Record<string, Object>)[CREDENTIAL_FAILURE] === undefined).assertTrue();
        expect((await f.files.getAllFileSources()).length).assertEqual(1);
      });
    });
  });
}
