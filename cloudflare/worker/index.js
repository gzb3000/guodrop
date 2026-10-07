/**
 * appversion.harvin.top —— Cloudflare Worker 版本接口
 *
 * 与 functions/api/version.js（Pages Functions 版）逻辑相同，实际部署用的是这个 Worker
 * （wrangler.toml 已绑定自定义域名 appversion.harvin.top 和 KV VERSION_KV）。
 *
 * 路由：
 *   GET /api/version   → KV 'current' 的 JSON（下载地址里的 {githubRepo} 会被替换）
 *   GET /              → 简单说明页
 *
 * KV 'current' 示例：
 * {
 *   "latestVersion": "0.2.0",
 *   "minVersion": "0.1.0",
 *   "forceUpdate": false,
 *   "message": "...",
 *   "githubRepo": "gzb3000/guodrop",          ← 只改这里就能换仓库
 *   "urls": {
 *     "android": "https://github.com/{githubRepo}/releases/latest/download/guodrop-android.apk",
 *     "windows": "https://github.com/{githubRepo}/releases/latest/download/guodrop-windows-setup.exe",
 *     "ios": "", "macos": ""
 *   }
 * }
 */
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }
    if (url.pathname === '/api/version' || url.pathname === '/api/version/') {
      if (request.method !== 'GET' && request.method !== 'HEAD') {
        return json({ error: 'METHOD_NOT_ALLOWED' }, 405);
      }
      return handleVersion(env);
    }
    if (url.pathname === '/') {
      return new Response('lan_share version service. GET /api/version', {
        headers: { 'Content-Type': 'text/plain; charset=utf-8' },
      });
    }
    return json({ error: 'NOT_FOUND' }, 404);
  },
};

async function handleVersion(env) {
  if (!env.VERSION_KV) {
    return json({ error: 'KV_BINDING_MISSING', hint: 'KV 变量名必须是 VERSION_KV' }, 500);
  }
  try {
    const raw = await env.VERSION_KV.get('current');
    if (!raw) {
      return json({ error: 'VERSION_NOT_CONFIGURED', hint: "KV 里还没有 'current' 键" }, 404);
    }
    let data;
    try {
      data = JSON.parse(raw);
    } catch {
      return json({ error: 'KV_VALUE_NOT_JSON' }, 500);
    }
    const repo = String(data.githubRepo || '').trim();
    if (repo && data.urls && typeof data.urls === 'object') {
      for (const k of Object.keys(data.urls)) {
        if (typeof data.urls[k] === 'string') {
          data.urls[k] = data.urls[k].split('{githubRepo}').join(repo);
        }
      }
    }
    // 规则：只要有新版本就强制更新 —— minVersion 恒等于 latestVersion，forceUpdate 恒为 true。
    // 以后发版只需改 KV 里的 latestVersion。
    const latest = data.latestVersion ?? data.latest;
    if (latest) {
      data.latestVersion = String(latest);
      data.minVersion = String(latest);
      delete data.latest;
      delete data.minimum;
    }
    data.forceUpdate = true;
    return json(data, 200);
  } catch (e) {
    return json({ error: 'KV_READ_FAILED', detail: String(e) }, 500);
  }
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      Pragma: 'no-cache',
      ...corsHeaders(),
    },
  });
}

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}
