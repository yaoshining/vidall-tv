/**
 * OpenSubtitles Proxy Worker
 *
 * 将 App 端的字幕搜索/下载请求转发至 OpenSubtitles API，并注入 API Key。
 * 内置按设备 ID 的每日请求限额（50 次/天），防止 API Key 滥用。
 *
 * 路由：
 *   GET  /v1/subtitles  → https://api.opensubtitles.com/api/v1/subtitles
 *   POST /v1/download   → https://api.opensubtitles.com/api/v1/download
 *
 * 限流机制：
 *   - 每个请求必须携带 X-Device-Id header
 *   - KV key 格式：rate:{deviceId}:{utcDate}，TTL = 25 小时
 *   - 单设备单日上限 50 次；超限返回 429
 */

interface Env {
  OPENSUBTITLES_API_KEY: string;
  RATE_LIMIT_KV: KVNamespace;
}

/** OpenSubtitles REST API 基础地址 */
const UPSTREAM_BASE = "https://api.opensubtitles.com/api/v1";

/** 单设备每日请求上限 */
const DAILY_QUOTA = 50;

/** KV 记录 TTL（秒）：25 小时，确保跨午夜时旧 key 自动过期 */
const KV_TTL_SECONDS = 25 * 60 * 60;

// ---------------------------------------------------------------------------
// 工具函数
// ---------------------------------------------------------------------------

/** 获取当前 UTC 日期字符串（YYYY-MM-DD），用于 KV key 的日期分段 */
function utcDateString(): string {
  return new Date().toISOString().slice(0, 10); // e.g. "2024-06-15"
}

/** 构建限流 KV key */
function rateKey(deviceId: string): string {
  return `rate:${deviceId}:${utcDateString()}`;
}

/** 返回 JSON 响应的快捷方法 */
function jsonResponse(body: Record<string, string>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ---------------------------------------------------------------------------
// 限流检查与计数
// ---------------------------------------------------------------------------

/**
 * 检查设备请求配额，未超限时将计数 +1。
 *
 * @returns `true` 表示已超限（应拒绝请求），`false` 表示放行。
 */
async function checkAndIncrementRateLimit(
  kv: KVNamespace,
  deviceId: string
): Promise<boolean> {
  const key = rateKey(deviceId);
  const current = await kv.get(key);
  const count = current !== null ? parseInt(current, 10) : 0;

  if (count >= DAILY_QUOTA) {
    // 已达上限，拒绝请求（不再递增，避免无谓写入）
    return true;
  }

  // 未超限：写入新计数，重置 TTL
  await kv.put(key, String(count + 1), { expirationTtl: KV_TTL_SECONDS });
  return false;
}

// ---------------------------------------------------------------------------
// 请求转发
// ---------------------------------------------------------------------------

/**
 * 将请求转发至 OpenSubtitles 上游 API，注入鉴权 header。
 *
 * @param upstreamUrl 上游完整 URL（含 query string）
 * @param originalRequest 原始请求对象
 * @param apiKey OpenSubtitles API Key（来自 Worker secret）
 */
async function forwardToUpstream(
  upstreamUrl: string,
  originalRequest: Request,
  apiKey: string
): Promise<Response> {
  // 仅透传必要 header，移除 Host 等可能造成问题的 header
  const forwardHeaders = new Headers();
  forwardHeaders.set("Api-Key", apiKey);
  forwardHeaders.set("Content-Type", "application/json");

  // 透传客户端传入的 Accept-Language（有助于 OpenSubtitles 返回更精准结果）
  const acceptLanguage = originalRequest.headers.get("Accept-Language");
  if (acceptLanguage) {
    forwardHeaders.set("Accept-Language", acceptLanguage);
  }

  const upstreamRequest = new Request(upstreamUrl, {
    method: originalRequest.method,
    headers: forwardHeaders,
    body:
      originalRequest.method !== "GET" && originalRequest.method !== "HEAD"
        ? originalRequest.body
        : undefined,
  });

  return fetch(upstreamRequest);
}

// ---------------------------------------------------------------------------
// 路由处理
// ---------------------------------------------------------------------------

/**
 * 处理 GET /v1/subtitles
 * 将查询参数原样透传至上游字幕搜索接口。
 */
async function handleSearchSubtitles(
  request: Request,
  env: Env
): Promise<Response> {
  const incomingUrl = new URL(request.url);
  // 保留全部 query 参数（query, languages, imdb_id 等）
  const upstreamUrl = `${UPSTREAM_BASE}/subtitles${incomingUrl.search}`;
  return forwardToUpstream(upstreamUrl, request, env.OPENSUBTITLES_API_KEY);
}

/**
 * 处理 POST /v1/download
 * 将请求 body 原样透传至上游字幕下载接口。
 */
async function handleDownloadSubtitle(
  request: Request,
  env: Env
): Promise<Response> {
  const upstreamUrl = `${UPSTREAM_BASE}/download`;
  return forwardToUpstream(upstreamUrl, request, env.OPENSUBTITLES_API_KEY);
}

// ---------------------------------------------------------------------------
// 主入口
// ---------------------------------------------------------------------------

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const { pathname, method } = { pathname: url.pathname, method: request.method };

    // ── 1. 设备 ID 校验 ──────────────────────────────────────────────────────
    const deviceId = request.headers.get("X-Device-Id");
    if (!deviceId || deviceId.trim() === "") {
      return jsonResponse({ error: "missing_device_id" }, 400);
    }

    // ── 2. 限流检查 ──────────────────────────────────────────────────────────
    const quotaExceeded = await checkAndIncrementRateLimit(
      env.RATE_LIMIT_KV,
      deviceId.trim()
    );
    if (quotaExceeded) {
      return jsonResponse({ error: "quota_exceeded" }, 429);
    }

    // ── 3. 路由分发 ──────────────────────────────────────────────────────────
    if (pathname === "/v1/subtitles" && method === "GET") {
      return handleSearchSubtitles(request, env);
    }

    if (pathname === "/v1/download" && method === "POST") {
      return handleDownloadSubtitle(request, env);
    }

    // ── 4. 未匹配路由 ────────────────────────────────────────────────────────
    return jsonResponse({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
