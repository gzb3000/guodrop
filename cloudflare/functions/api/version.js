/**
 * GET /api/version
 *
 * 从 Cloudflare KV 读取当前版本公告，返回给 App。
 *
 * ────────────────────────────────────────────────────────────
 * 部署方式（Cloudflare Pages + Functions）
 * ────────────────────────────────────────────────────────────
 *
 * 1. 建 KV namespace
 *    Cloudflare 后台 → Workers & Pages → KV → Create namespace
 *    命名：lan_share_version
 *
 * 2. 绑定到 Pages 项目
 *    你的 Pages 项目 → Settings → Functions → KV namespace bindings
 *    Variable name : VERSION_KV          ← 必须叫这个名
 *    KV namespace  : lan_share_version   ← 选刚建的那个
 *
 * 3. 部署这个文件
 *    把 functions/ 目录放到 Pages 项目根目录，一起部署。
 *    部署后访问 https://appversion.harvin.top/api/version 应该能看到 JSON。
 *
 * 4. 写入初始数据
 *    KV 里加一个键：current
 *    值是下面这段 JSON（见文件底部的示例）
 *
 * ────────────────────────────────────────────────────────────
 * 以后怎么强制淘汰老版本
 * ────────────────────────────────────────────────────────────
 *
 * 只要去 KV 里把 current 这个键的 minVersion 改成新版本号，
 * 几秒内全球生效，所有低于该版本的 App 下次启动就会被拦住。
 * 不需要重新部署 Pages，也不需要重新编译任何东西。
 */

export async function onRequestGet({ env }) {
  // KV 没绑定时给出明确提示，方便排查部署问题
  if (!env.VERSION_KV) {
    return json(
      {
        error: 'KV_BINDING_MISSING',
        hint: '请在 Pages 项目的 Settings → Functions 里绑定 KV，变量名必须是 VERSION_KV',
      },
      500,
    );
  }

  try {
    // 同时兼容两种存法：
    //   1) get('current', {type:'json'})  —— 存的就是 JSON
    //   2) get('current')                —— 存的是字符串，这里手动解析
    let data = await env.VERSION_KV.get('current', { type: 'json' });

    if (!data) {
      const raw = await env.VERSION_KV.get('current');
      if (raw) {
        try {
          data = JSON.parse(raw);
        } catch {
          return json({ error: 'KV_VALUE_NOT_JSON' }, 500);
        }
      }
    }

    if (!data) {
      return json(
        {
          error: 'VERSION_NOT_CONFIGURED',
          hint: "KV 里还没有名为 'current' 的键，请先写入版本数据",
        },
        404,
      );
    }

    return json(data, 200);
  } catch (e) {
    return json({ error: 'KV_READ_FAILED', detail: String(e) }, 500);
  }
}

/**
 * 顺手处理 OPTIONS 预检（如果以后要用浏览器跨域访问）
 */
export async function onRequestOptions() {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(),
  });
}

function json(obj, status) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      // 关键：不能缓存。
      // 否则你改了 minVersion，用户端可能还读到旧值，白等一个缓存周期。
      'Cache-Control': 'no-store, no-cache, must-revalidate',
      'Pragma': 'no-cache',
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

/* ────────────────────────────────────────────────────────────
 * KV 里 'current' 键应该存的内容（原样粘贴到 KV value 里）
 * ────────────────────────────────────────────────────────────
 *
 * {
 *   "latestVersion": "0.1.0",
 *   "minVersion": "0.1.0",
 *   "message": "",
 *   "urls": {
 *     "android": "https://appversion.harvin.top/download/lan_share.apk",
 *     "windows": "https://appversion.harvin.top/download/lan_share.zip",
 *     "ios": "",
 *     "macos": ""
 *   },
 *   "forceUpdate": true
 * }
 *
 * ────────────────────────────────────────────────────────────
 * 字段说明
 * ────────────────────────────────────────────────────────────
 *
 * latestVersion  最新版本号。当前版本比它低 → 提示更新。
 *
 * minVersion     允许使用的最低版本。当前版本比它低 → 强制拦截。
 *                这是你要的「让老版本停止工作」的开关。
 *
 * message        展示给用户的更新说明。纯文本，可以用 \n 换行。
 *
 * urls           各平台下载地址。App 会按自己的平台自动挑。
 *                留空字符串表示该平台暂时没有下载链接。
 *
 * forceUpdate    true（默认）= 只要比 latestVersion 低就强制拦截；
 *                false = 比 latestVersion 低时只提示、可跳过。
 *                注意：不管这个是 true 还是 false，
 *                低于 minVersion 一律强制拦截。
 *
 * ────────────────────────────────────────────────────────────
 * 常见操作示例
 * ────────────────────────────────────────────────────────────
 *
 * 【发布 0.2.0，老版本 0.1.0 必须升级】
 *   latestVersion: "0.2.0"
 *   minVersion:    "0.2.0"     ← 调高到 0.2.0，0.1.0 就被拦了
 *
 * 【发布 0.2.0，但允许 0.1.0 继续用一阵子】
 *   latestVersion: "0.2.0"
 *   minVersion:    "0.1.0"     ← 保持不变 → 0.1.0 只会看到提示
 *
 * 【过一阵子，决定淘汰 0.1.0】
 *   minVersion:    "0.2.0"     ← 只改这一个字段就行
 */
