"""恢复成套 CI 签名材料；秘密只经环境变量和权限受限文件传递。"""
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

FILES = {'vidall_tv_debug.cer', 'vidall_tv_debug.p12', 'vidall_tv_debug.p7b'}
MATERIAL_GROUPS = {'ac', 'ce', 'fd/0', 'fd/1', 'fd/2'}


def profile_data(text):
    # 仓库配置使用双引号键；去掉字符串外的注释和尾逗号。
    text = re.sub(r'("(?:\\.|[^"\\])*")|//[^\n]*|/\*[\s\S]*?\*/',
                  lambda m: m[1] or '', text)
    text = re.sub(r'("(?:\\.|[^"\\])*")|,(?=\s*[}\]])', lambda m: m[1] or '', text)
    return json.loads(text)


def default_material(data):
    configs = [c for c in data['app']['signingConfigs'] if c['name'] == 'default']
    if len(configs) != 1:
        raise ValueError('default 签名配置缺失或不唯一')
    return configs[0]['material']


def signing_values(text):
    material = default_material(profile_data(text))
    return {key: material[key] for key in ('keyAlias', 'keyPassword', 'storePassword')}


def config_digest(text):
    return hashlib.sha256(json.dumps(signing_values(text), sort_keys=True).encode()).hexdigest()


def package_bundle(source, profile_text):
    names = FILES | {str(p.relative_to(source)) for p in (source / 'material').rglob('*') if p.is_file()}
    content = {name: (source / name).read_bytes() for name in names}
    manifest = {'schema': 1, 'config_sha256': config_digest(profile_text),
                'files': {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}}
    content['manifest.json'] = json.dumps(manifest).encode()
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w:gz') as archive:
        for name, data in sorted(content.items()):
            member = tarfile.TarInfo(name); member.size = len(data); member.mode = 0o600
            archive.addfile(member, io.BytesIO(data))
    encoded = base64.b64encode(buffer.getvalue()).decode()
    unpack_bundle(encoded, profile_text)
    return encoded


def unpack_bundle(encoded, profile_text):
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(encoded, validate=True)), mode='r:gz') as archive:
        members = archive.getmembers()
        names = [m.name for m in members]
        material = [re.fullmatch(r'material/(ac|ce|fd/[012])/[a-f0-9]{16,64}', name)
                    for name in names if name not in FILES | {'manifest.json'}]
        if (len(names) != len(set(names)) or not FILES | {'manifest.json'} <= set(names) or
                len(material) != len(MATERIAL_GROUPS) or any(m is None for m in material) or
                {m[1] for m in material} != MATERIAL_GROUPS):
            raise ValueError('签名包文件集合不完整或含未知路径')
        if any(not m.isfile() or m.size <= 0 or m.size > 1024 * 1024 for m in members):
            raise ValueError('签名包包含链接、空文件或异常大小')
        content = {m.name: archive.extractfile(m).read() for m in members}
    manifest = json.loads(content.pop('manifest.json'))
    if manifest.get('schema') != 1 or manifest.get('config_sha256') != config_digest(profile_text):
        raise ValueError('签名材料与当前别名/密码配置不匹配')
    if manifest.get('files') != {name: hashlib.sha256(data).hexdigest() for name, data in content.items()}:
        raise ValueError('签名材料校验和不一致')
    return content


def restore(encoded, destination, profile):
    text = profile.read_text()
    content = unpack_bundle(encoded, text)
    certificates = re.findall(b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', content['vidall_tv_debug.cer'], re.S)
    if not certificates:
        raise ValueError('签名证书链为空')
    for certificate in certificates:
        result = subprocess.run(['openssl', 'x509', '-checkend', '0', '-noout'], input=certificate, capture_output=True)
        if result.returncode != 0:
            raise ValueError('签名证书链包含过期或损坏证书')
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    for name, data in content.items():
        path = destination / name
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        path.write_bytes(data)
        path.chmod(0o600)
    data = profile_data(text)
    material = default_material(data)
    for key, name in [('certpath', 'vidall_tv_debug.cer'), ('storeFile', 'vidall_tv_debug.p12'), ('profile', 'vidall_tv_debug.p7b')]:
        material[key] = str(destination / name)
    profile.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')
    print('签名包文件、配置匹配及证书有效期校验通过；材料已隔离恢复')


if __name__ == '__main__':
    try:
        restore(os.environ['SIGNING_BUNDLE_BASE64'], Path(sys.argv[1]), Path(sys.argv[2]))
    except (KeyError, ValueError, OSError, tarfile.TarError) as error:
        print('签名恢复失败：' + str(error), file=sys.stderr)
        sys.exit(1)
