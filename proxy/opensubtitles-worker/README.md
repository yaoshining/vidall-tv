# OpenSubtitles Proxy Worker

Cloudflare Worker 代理，用于中转 OpenSubtitles API 请求。

## 部署

1. 安装依赖：`npm install`
2. 创建 KV namespace：`wrangler kv:namespace create RATE_LIMIT_KV`，更新 wrangler.toml 中的 id
3. 设置 API Key：`wrangler secret put OPENSUBTITLES_API_KEY`
4. 部署：`npm run deploy`

## 本地开发

1. 复制 `.dev.vars.example` 为 `.dev.vars` 并填写 API Key
2. `npm run dev`
