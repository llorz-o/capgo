# 自托管多域名：客户端更新域名独立部署

把 **Supabase / 控制台 / CLI** 与 **客户端热更新 API** 拆到不同域名，便于：

- 客户端 API 走 CDN / Cloudflare 全球加速；管理域名只对内网或开发者
- 用 `bundle upload --external` 后，客户端拉 bundle 完全走外部存储，**不经过本机 Supabase**
- 可以单独限流、单独切流、单独换证书，互不影响

> **场景前提**：`bundle upload` 已使用 `--external <url>`，bundle 文件托管在外部存储（CDN、对象存储、GitHub Release 等），不上传到自托管 Supabase Storage。

| 文档 | 路径 |
| --- | --- |
| 前置条件 / 单域名场景 | [`self-hosted-deploy-prerequisites.zh-CN.md`](self-hosted-deploy-prerequisites.zh-CN.md) |
| 部署索引 | [`self-hosted-deploy-index.md`](self-hosted-deploy-index.md) |
| 全栈指南（Nginx 详解） | [`/root/SELF_HOSTED_FULL_STACK.zh-CN.md`](/root/SELF_HOSTED_FULL_STACK.zh-CN.md) **§4** |

---

## 1. 域名规划

| 用途 | 占位域名 | 暴露给 | 路径 |
| --- | --- | --- | --- |
| Capgo 控制台 | `capgo.example.com` | 浏览器（内部用户） | 静态文件 `/var/www/capgo/dist` |
| Supabase API / Studio | `supa.example.com` | 开发者浏览器 + `@capgo/cli` | 反代 Kong + Studio（全路径） |
| **客户端更新 API（新）** | `update.example.com` | **手机 App / native 客户端** | **仅** `/functions/v1/{updates,stats,channel_self,ok,latency}` |

> **本机当前环境示例**：`capgo.llorz.online` / `supa.llorz.online` / `update.llorz.online`

### 为什么客户端域名不暴露其他路径

- 客户端只调更新插件 4–5 个端点，其余路径（`/auth`、`/rest`、`/storage`、Studio）一旦暴露，等于把数据库管理面暴露给整张公网
- external 模式下 bundle 下载走外部存储，所以**不需要** `/storage/v1/*`
- 缩小攻击面、降低被滥用导致的迁移风险

---

## 2. DNS 与 TLS

1. 在 DNS 添加 A/AAAA 记录：

   ```text
   update.example.com    A    <服务器公网 IP>
   ```

2. 申请证书（Let's Encrypt 示例）：

   ```bash
   sudo certbot --nginx -d update.example.com
   ```

   或加到已有 certbot 任务里：

   ```bash
   sudo certbot --nginx -d supa.example.com -d capgo.example.com -d update.example.com
   ```

3. 走 Cloudflare 时：SSL/TLS 模式选 **完全 (Full)**；若需要客户端真实 IP，**保留** `CF-Connecting-IP` 头不要剥离。

---

## 3. Nginx 配置（直接复制即可）

> 替换 `update.example.com` 为你的真实域名，路径替换为实际证书路径。  
> 把以下内容写入 `/etc/nginx/sites-available/update.conf`，然后 `ln -s` 到 `sites-enabled/`，最后 `sudo nginx -t && sudo systemctl reload nginx`。

```nginx
# /etc/nginx/sites-available/update.conf
#
# 客户端更新 API 专用：仅反代 /functions/v1/{updates,stats,channel_self,ok,latency}
# 配合 bundle upload --external 使用，不需要 /storage/v1/。

# HTTP → HTTPS 强制跳转
server {
    listen 80;
    listen [::]:80;
    server_name update.example.com;

    # ACME 续期路径（certbot 默认）
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://$host$request_uri;
    }
}

# HTTPS 正式服务
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name update.example.com;

    ssl_certificate     /etc/letsencrypt/live/update.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/update.example.com/privkey.pem;

    # 推荐安全头（按需调整）
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "no-referrer" always;

    # 客户端请求体不会很大（JSON 即可），保留默认或略小
    client_max_body_size 1m;
    client_body_timeout  30s;

    # 通用 proxy 模板（被下方 location 包含）
    proxy_http_version 1.1;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;   # oracle guard / rate limit 必需
    proxy_set_header   X-Forwarded-Host  $host;
    proxy_set_header   X-Forwarded-Proto $scheme;
    proxy_set_header   X-Forwarded-Port  443;
    proxy_set_header   Connection        "";
    proxy_buffering         off;
    proxy_request_buffering off;
    proxy_read_timeout      60s;
    proxy_send_timeout      60s;

    # ============ 允许的客户端端点 ============
    # /updates           : 检查热更新
    # /stats             : 客户端统计回调
    # /channel_self      : 客户端切换 channel（按需开放）
    # /ok                : 健康探活
    # /latency           : 延迟检测
    location ~ ^/functions/v1/(updates|stats|channel_self|ok|latency)(/.*)?$ {
        proxy_pass http://127.0.0.1:8000;
    }

    # 其他路径全部 404，避免无意暴露其他 Supabase 接口
    location / {
        return 404 "Not Found\n";
        default_type text/plain;
    }
}
```

### 配置要点解释

| 行 | 为什么 |
| --- | --- |
| `X-Forwarded-For` | `updates` 接口的 [oracle 防护与 rate limit](#5-与-oracle--速率限制的关系) 按客户端 IP 工作；缺失则防护失效 |
| `X-Forwarded-Host` / `-Proto` / `-Port` | Edge Functions 用来生成回调 URL；虽然 external 模式下不会签 S3，但 `stats` 等仍会读 |
| `proxy_buffering off` | 大量短连接的更新请求，缓冲反而拖慢；与 supa 站点保持一致 |
| `location ~ ^/functions/v1/(...)` | **白名单**：只放 5 个端点；其它一律 404 |
| `Connection ""` | 关掉默认的 keep-alive 头透传，避免上游误判 |

---

## 4. 客户端 `capacitor.config` 配置

只改 `CapacitorUpdater` 三项即可（其他保持原值）：

```json
{
  "appId": "com.example.app",
  "plugins": {
    "CapacitorUpdater": {
      "updateUrl":  "https://update.example.com/functions/v1/updates",
      "statsUrl":   "https://update.example.com/functions/v1/stats",
      "channelUrl": "https://update.example.com/functions/v1/channel_self"
    }
  }
}
```

> **`localSupa` / `localSupaAnon` / `localApi` / `localApiFiles` 仅供 CLI 使用**，与客户端无关，可不写入打包给终端的 `capacitor.config`。开发机仍配 `supa.example.com`。

---

## 5. CLI 端：上传 external bundle

仍走 **管理域名** `supa.example.com`：

```bash
# 1. 上传到你的外部存储（CDN / OSS / GitHub Release）
#    bundle 文件名建议带版本号或 hash，方便缓存失效

# 2. 把元数据写入自托管 Capgo（不上传文件）
npx @capgo/cli@latest bundle upload \
  --supa-host     https://supa.example.com \
  --supa-anon     <ANON_KEY> \
  --external      https://cdn.example.com/bundles/com.example.app-1.0.3.zip \
  --encrypted-checksum <sha256-签名> \
  --channel       production
```

| 关键参数 | 说明 |
| --- | --- |
| `--external` | 客户端将直接 GET 此 URL；**必须 HTTPS 且对客户端可达** |
| `--encrypted-checksum` | 客户端凭 checksum 校验 bundle 完整性，强烈建议配合使用 |
| `--key-v2` | 私钥签名 bundle（v2 系统），即便 external 主机被攻破也不会装错包 |
| `--no-delta` / 不传 `--delta` | external 模式不支持增量更新，永远全量下载 |

---

## 6. 部署验收清单

```bash
SUPA=supa.example.com
CON=capgo.example.com
UPD=update.example.com

# A) 管理域名仍可用
curl -sk "https://${SUPA}/functions/v1/ok" | jq .status

# B) 更新域名 5 个端点都可达
for p in ok updates stats channel_self latency; do
  echo -n "$p: "
  curl -sk -o /dev/null -w "%{http_code}\n" -X POST "https://${UPD}/functions/v1/${p}" \
    -H "Content-Type: application/json" -d '{}'
done
# 期望 200 / 400（参数缺失）等业务错误，不能是 404 / 502

# C) 其他路径必须 404（验证白名单生效）
for p in auth/v1/health rest/v1/ storage/v1/object/public/ functions/v1/private/config; do
  echo -n "$p: "
  curl -sk -o /dev/null -w "%{http_code}\n" "https://${UPD}/${p}"
done
# 期望全部 404

# D) X-Forwarded-For 透传正确
curl -sk -X POST "https://${UPD}/functions/v1/updates" \
  -H "Content-Type: application/json" \
  -d '{"app_id":"com.example.app","device_id":"test-device","version_name":"0.0.0","version_code":"1","platform":"ios"}'
# 在服务器上查 supabase-edge-functions 日志，应能看到非 "unknown" 的客户端 IP

# E) 客户端实战
#   - 安装 App，触发热更新
#   - 服务器观察 stats / updates 请求日志
```

---

## 7. 与 oracle 防护 / 速率限制的关系

`update.example.com` 入站请求会经过 `updates` 接口的两层保护，**全部以客户端 IP 为粒度**：

| 机制 | 行为 | 触发后果 | 可调环境变量 |
| --- | --- | --- | --- |
| **Oracle guard** | 同 IP 在 15 分钟内对 `app_id` 的「不存在」回答累计 ≥ 5 次 | `429 on_premise_app` 封禁 15 分钟 | `RATE_LIMIT_UPDATE_ENUMERATION_MISSES`、`RATE_LIMIT_UPDATE_ENUMERATION_HASH_SECRET` |
| **API rate limit** | 同 API Key 每分钟 ≥ 2000 次 | `429` | `RATE_LIMIT_API_KEY` |

**Nginx 必须传 `X-Forwarded-For`**，否则 Edge 拿到的 IP 是 `'unknown'`，oracle guard 直接跳过（日志 `Update enumeration guard skipped: unknown IP`），保护失效。

**走 Cloudflare 时**：边缘会注入 `CF-Connecting-IP`，Edge 优先用它，所以 CDN 后面也能拿到真实 IP；不需要在 Nginx 里额外解析。

**自托管阈值建议**：

```bash
# volumes/functions/.env
RATE_LIMIT_UPDATE_ENUMERATION_MISSES=20     # 客户群体大、NAT 严重时放宽
RATE_LIMIT_API_KEY=5000                     # 默认 2000，按你 App 真实并发调
```

改完执行：

```bash
docker compose -f /root/supabase-project/docker-compose.yml restart functions
```

---

## 8. 升级与切流策略（推荐）

1. **先双跑**：保留 `supa.example.com` 也能访问 `/functions/v1/updates`，新 App 先用 `update.example.com`。
2. **观察 1–2 周**：对比两个域名的请求量、错误率、`stats` 入库一致性。
3. **逐步切**：在 App 端 OTA 推一个新版本，`capacitor.config` 全切到 `update.example.com`。
4. **限流回收**：确认旧 App 不再请求 `supa.example.com` 的 `/updates` 后，可在 `supa.example.com` 的 Nginx 里把 `/functions/v1/updates|stats|channel_self` 单独 deny，强制只接受新域名。
5. **CDN 接入**：在 `update.example.com` 前挂 Cloudflare / 自家 CDN，给 `/updates` 加边缘缓存（注意 TTL 不能比客户端轮询间隔长）。

---

## 9. 与单域名场景的区别速查

| 项 | 单域名 | 多域名（本文） |
| --- | --- | --- |
| `capacitor.config` `updateUrl` 等 | 默认走 `localSupa` | **必填**指向 `update.example.com` |
| 新域名需反代 `/storage/v1/*` | 是（自托管 bundle） | **否**（external bundle） |
| 新域名需反代 `/auth`、`/rest` | 是 | **否**（白名单 4–5 个） |
| `FUNCTIONS_PUBLIC_API_HOSTNAME` | `supa.example.com` | **不变**，仍是 `supa.example.com`（Edge 内部回调用） |
| Kong CORS / `kong.yml` | 含控制台 origin | **不变**（client 是 native 无 CORS） |
| 升级时的回退 | 改 Nginx | 改 App `capacitor.config` 再发版 |

---

## 10. 常见问题

**Q：客户端报 `429 on_premise_app`？**  
A：触发了 oracle 防护。查 `app_id` 是否拼错（导致大量 miss），或调高 `RATE_LIMIT_UPDATE_ENUMERATION_MISSES`。

**Q：客户端能收到更新响应，但下载 bundle 报 404 / 403？**  
A：external bundle 的 URL 不可达。直接 `curl -I` 该 URL 验证；检查 CDN 缓存策略。**与 `update.example.com` 反代无关**。

**Q：可以把 `update.example.com` 挂在另一台机器吗？**  
A：可以——它只是个 Nginx，转发到 Kong（127.0.0.1:8000）。如果 Kong 在另一台机器，把 `proxy_pass` 改成 `http://<kong-host>:8000` 即可，仍要保留所有 `X-Forwarded-*` 头。

**Q：可以同时支持 self-hosted bundle 和 external bundle 吗？**  
A：可以——给 `update.example.com` 也加上 `/storage/v1/*` 反代即可（参见前置文档 §5.4）。external bundle 不走这里，self-hosted bundle 走这里。

**Q：怎么验证 oracle guard 真的在用 X-Forwarded-For？**  
A：

```bash
docker logs supabase-edge-functions 2>&1 | grep -i "enumeration guard skipped"
# 不应该出现 "unknown IP"；若出现，说明 X-Forwarded-For 没传到
```
