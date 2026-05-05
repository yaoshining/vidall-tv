# OpenSubtitles Proxy Worker

Cloudflare Worker 代理，用于中转 OpenSubtitles API 请求，支持本地开发与生产两套环境。

## 环境说明

| 环境 | 命令 | KV | Secret |
|------|------|----|--------|
| 本地开发 | `npm run dev` | 本地模拟 | `.dev.vars` |
| 本地开发（远程 KV） | `npm run dev:remote` | 真实 KV | `.dev.vars` |
| 生产部署 | `npm run deploy:production` | 真实 KV | wrangler secret |

## 初次部署（生产环境）

```bash
# 1. 安装依赖
npm install

# 2. 创建生产 KV namespace，记录返回的 id
npm run kv:create:production

# 3. 将 id 填入 wrangler.toml 的 [[env.production.kv_namespaces]] id 字段

# 4. 注入生产环境 API Key（不会写入版本控制）
npm run secret:put:production

# 5. 部署到生产
npm run deploy:production
```

## 本地开发

```bash
# 1. 复制环境变量示例文件
cp .dev.vars.example .dev.vars

# 2. 编辑 .dev.vars，填入真实 API Key
# OPENSUBTITLES_API_KEY=your_api_key_here

# 3. 启动本地开发服务器（KV 使用本地模拟，监听 localhost:8787）
npm run dev

# 或：连接真实 Cloudflare KV 进行测试
npm run dev:remote
```

## App 端对应配置

App 在不同 product 下访问不同 Worker URL：

| App Product | Worker URL |
|-------------|------------|
| `default`（开发） | `http://localhost:8787/v1` |
| `production` | `https://os-proxy.vidall.app/v1` |

详见 `entry/src/main/ets/config/AppEnv.ets`。
