# 强制更新 —— 部署与运维说明

## 整体结构

```
  你的 App（手机 / 电脑）
        ↓ 启动时 GET https://appversion.harvin.top/api/version
  Cloudflare Pages（独立子域名，与主站 harvin.top 完全隔离）
        ↓ 读
  Cloudflare KV（键名 current）
        ↓ 存着
  { latestVersion, minVersion, message, urls }
```

**你要控制的就是 KV 里那一个 JSON。** 改 `minVersion`，老版本立刻报废。

### 为什么用独立子域名

主站 `harvin.top` 的 nginx 配了 catch-all 规则（任何路径都返回同一个页面），
挂 `/api/version` 上去会和现有服务互相干扰。

`appversion.harvin.top` 是独立子域名，DNS 记录和 Pages 绑定都是分开的，
**完全不碰你主站的东西**。

---

## 一、部署（一次性，约 8 分钟）

### 步骤 1：建 KV namespace

🖱️【点击】Cloudflare 后台 → 左侧菜单 **Workers & Pages** → 上方 **KV** 标签
🖱️【点击】**Create a namespace**
⌨️【输入】`lan_share_version`
🖱️【点击】**Add**

### 步骤 2：建 Pages 项目

如果你已经有 Pages 项目，跳过这步直接看步骤 3。

🖱️【点击】**Workers & Pages** → **Create** → **Pages** → **Upload assets**
⌨️【输入】项目名：`lan-share-update`
🖱️【点击】**Create project**
🖱️ 上传一个空的 `index.html`（内容随便写，占个位）

### 步骤 3：绑定 KV 到 Pages 项目

🖱️【点击】进入 `lan-share-update` 项目
🖱️【点击】**Settings** → 左侧 **Functions**
🖱️【点击】**KV namespace bindings** → **Add binding**
⌨️【输入】

| 字段 | 值 |
|---|---|
| **Variable name** | `VERSION_KV` ← **一字不差，区分大小写** |
| **KV namespace** | `lan_share_version` |

🖱️【点击】**Save**

### 步骤 4：绑定子域名 appversion.harvin.top

🖱️【点击】项目 → **Custom domains** 标签
🖱️【点击】**Set up a custom domain**
⌨️【输入】`appversion.harvin.top`
🖱️【点击】**Continue** → **Activate domain**

**前提：`harvin.top` 的 DNS 托管在 Cloudflare。**
如果不在这里，Cloudflare 会告诉你需要加一条 CNAME 记录，
按它给的提示去你的 DNS 服务商加就行。

激活后应该显示 `Active`。首次生效可能要等 1～5 分钟。

### 步骤 5：部署 Functions 代码

把本目录下的 `functions/` 文件夹放到 Pages 项目里，然后部署。

**方式 A：网页上传**（最简单）

用 `wrangler` 或直接在你的项目目录里准备好：

```
你的项目目录/
├── index.html                  ← 占位页
└── functions/
    └── api/
        └── version.js          ← 本目录的文件
```

然后打包成 zip 上传。⚠️ 注意：**网页版 "Upload assets" 不支持 `functions/` 目录**，
这种方式只能用 wrangler。

**方式 B：Wrangler 命令行**（推荐）

⌨️【在终端执行】

```bash
npm install -g wrangler
wrangler login

# 进入含 functions/ 的目录
cd 你的项目目录

wrangler pages deploy . --project-name=lan-share-update
```

**方式 C：Git 集成**

把项目推到 GitHub，在 Pages 设置里连上仓库，以后 push 自动部署。

### 步骤 6：写入初始版本数据

🖱️【点击】回到 **KV** → 点进 `lan_share_version`
🖱️【点击】**Add entry**
⌨️【输入】

**Key:** `current`

**Value:**（粘贴后按你实际的下载地址改）

```json
{
  "latestVersion": "0.1.0",
  "minVersion": "0.1.0",
  "message": "",
  "urls": {
    "android": "https://appversion.harvin.top/download/lan_share.apk",
    "windows": "https://appversion.harvin.top/download/lan_share.zip",
    "ios": "",
    "macos": ""
  },
  "forceUpdate": true
}
```

🖱️【点击】**Add**

### 步骤 7：验证

浏览器打开：

```
https://appversion.harvin.top/api/version
```

**应该看到纯 JSON**，类似：

```json
{"latestVersion":"0.1.0","minVersion":"0.1.0","message":"","urls":{...},"forceUpdate":true}
```

---

## 二、排查：验证不通过怎么办

| 现象 | 原因 | 解决 |
|---|---|---|
| `KV_BINDING_MISSING` | KV 没绑定，或变量名不叫 `VERSION_KV` | 回到步骤 3，名字必须**完全一致**（区分大小写） |
| `VERSION_NOT_CONFIGURED` | KV 里没有 `current` 这个键 | 回到步骤 6 |
| 404 | 文件路径不对 | 必须是 `functions/api/version.js`，不能是 `functions/version.js` |
| 一直显示旧的 JSON | 缓存 | 接口已设 `no-store`；用无痕窗口再试 |
| 打不开域名 | 子域名没激活 / DNS 没生效 | 回到步骤 4，等几分钟；确认 `harvin.top` 的 DNS 在 Cloudflare |
| 全是 `<h1>Welcome to nginx!</h1>` | **域名指到主站的 nginx 了** | 说明 `appversion` 子域名没正确绑到 Pages。检查步骤 4 |

**自查命令**（本地终端）：

```bash
curl -i https://appversion.harvin.top/api/version
```

看三点：
1. 状态码是 `200` 不是 `404`
2. `Content-Type` 是 `application/json` 不是 `text/html`
3. 响应体是 JSON，不是 nginx 欢迎页

---

## 三、日常运维：怎么淘汰老版本

### 场景 A：发了 0.2.0，但先让老版本用着

只改 `latestVersion`：

```json
{
  "latestVersion": "0.2.0",     ← 改这里
  "minVersion": "0.1.0",        ← 不动
  ...
}
```

**效果**：装 0.1.0 的用户看到更新提示，但可以点「以后再说」继续用。

### 场景 B：过一阵子，决定让 0.1.0 彻底停用

只改 `minVersion`：

```json
{
  "latestVersion": "0.2.0",
  "minVersion": "0.2.0",        ← 改这里
  ...
}
```

**效果**：装 0.1.0 的用户下次打开 App，**直接被全屏拦住**，只能去下载或退出。

### 场景 C：发了个有严重 bug 的 0.3.0，想让大家退回 0.2.0

```json
{
  "latestVersion": "0.2.0",
  "minVersion": "0.1.0",
  "message": "0.3.0 存在严重问题，请重新下载 0.2.0"
  ...
}
```

⚠️ 装 0.3.0 的用户因为版本比 `latestVersion` 高，**不会被提示**。
要拦他们得把 `minVersion` 也提到 0.3.0 以上 —— 但那会连 0.1.0 一起拦。
这种情况建议直接发个 0.3.1 修掉。

---

## 四、字段速查

| 字段 | 必填 | 说明 |
|---|---|---|
| `latestVersion` | ✅ | 最新版本号，三段式 `x.y.z` |
| `minVersion` | ✅ | 允许的最低版本，低于它一律拦截 |
| `message` | | 更新说明，纯文本，`\n` 可换行 |
| `urls.android` | | Android 下载地址（apk 直链） |
| `urls.windows` | | Windows 下载地址 |
| `urls.ios` | | iOS 下载地址（App Store 链接） |
| `urls.macos` | | macOS 下载地址 |
| `forceUpdate` | | `true`=低于 latest 就拦；`false`=只提示可跳过。默认 `true` |

**兼容写法**：`latestVersion` 也可写 `latest`，`minVersion` 也可写 `minimum`，
`urls.android` 也可写成平铺的 `androidUrl`。随便哪种都能解析。

---

## 五、几个重要设计决定

### 1. 查不到就放行（关键）

App 只在**成功读到版本数据**时才拦截。以下情况一律放行：

- 断网
- `appversion.harvin.top` 挂了
- KV 没配好返回 404
- JSON 格式不对

**为什么**：这是个局域网传文件的工具，经常在没有外网的环境用
（公司内网、手机热点、断网的家里）。如果「查不到版本就不让用」，
用户会直接卸载，**而且你没法远程救回来**。

### 2. 检查有 3 秒超时，不阻塞启动

不是后台慢慢查，是启动时并发查、最多等 3 秒。超时就走放行。
用户开 App 是来传文件的，不该为版本检查白站。

### 3. 版本号拆成整数逐段比

不能用字符串比 —— `"1.10.0"` 和 `"1.9.0"` 按字符串会比出
`1.10 < 1.9`（因为 `'1' < '9'`），是错的。

### 4. ⚠️ 发版时有两处版本号要一起改

- `pubspec.yaml` 的 `version:`
- `lib/core/version/version_check_service.dart` 的 `currentVersion` 常量

**两处不一致会导致「明明装了新版，还是被拦」。**
这条最容易出错，务必记牢。

### 5. 手机端点了「去下载」会发生什么

桌面端（Windows/macOS/Linux）会直接拉起系统浏览器打开下载链接。
手机端（Android/iOS）因为需要平台通道，会**自动退回成「复制下载链接」**，
提示用户自己粘贴到浏览器。

这是有意的取舍：与其为这一个按钮加原生通道代码，不如用复制粘贴 ——
更可靠，也少一堆平台差异要维护。

---

## 六、本地测试强制更新效果

想验证拦截功能，不用真发新版：

1. 在 KV 里把 `minVersion` 改成 `9.9.9`
2. **完全退出** App（不是切后台，要在最近任务里划掉）
3. 重新打开，应该立刻看到全屏拦截页
4. 测完把 `minVersion` 改回 `0.1.0`

如果没被拦，检查：
- App 里 `version_check_service.dart` 的 `currentVersion` 是不是 `0.1.0`
- 用 `curl -i https://appversion.harvin.top/api/version` 确认接口返回正常

---

## 七、App 侧地址在哪

只有一处：

```
lan_share/lib/ui/app_state.dart
  → static const _versionEndpoint = 'https://appversion.harvin.top/api/version';
```

以后要换地址，改这一行，然后重新编译。

---

## 八、实际部署状态（2026-10-07）

实际用的是 **Cloudflare Worker**（`worker/index.js` + `wrangler.toml`），不是 Pages：

- Worker：`lan-share-update`，自定义域名 `appversion.harvin.top`（Workers Custom Domain）
- KV：`lan_share_version`（id `eca9c2e8a96240028b5b086fd613ae80`），绑定名 `VERSION_KV`，键 `current`
- 当前值见 `kv-current.json`。`githubRepo` 字段会替换 urls 里的 `{githubRepo}` —— 换仓库只改这一处
- 改 KV：`wrangler kv key put --namespace-id=eca9c2e8a96240028b5b086fd613ae80 current "$(cat kv-current.json)" --remote`
- 改代码后重新部署：`cd cloudflare && wrangler deploy`

Release 资产固定文件名（由 `.github/workflows/release.yml` 生成）：
`guodrop-android.apk`、`guodrop-windows-setup.exe`、`guodrop-windows.zip`

---

## 九、强制更新规则（2026-10-07 起）

**只要 `latestVersion` 比 App 新，就一律强制更新，没有「以后再说」。**

- Worker 在返回前**强制改写**：`minVersion = latestVersion`、`forceUpdate = true`，
  不管 KV 里写的是什么。所以以后发版**只需要改 KV 里的 `latestVersion`**（和 `message`）。
- App 端也同样执行：本机版本 < `latestVersion` 一律显示强制更新页（`UpdateStatus.optional` 不再产生）。
- 「查不到版本就放行」的规则不变（断网 / 接口挂了不会拦人）。
- ⚠️ 先确认 GitHub Release 资产已上传可下载，**再**改 `latestVersion`，否则老用户会被拦住却下不到包。

发版流程：`tools/bump_version.sh x.y.z N` → commit → `git tag vx.y.z && git push --tags`
→ 等 Actions 生成 Release → 改 KV `latestVersion`。
