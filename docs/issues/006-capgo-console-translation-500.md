# 006 — 控制台白屏/无响应：`translation` Edge Function 缺失

## 现象

- `https://supa.llorz.online/functions/v1/ok` 正常
- `https://capgo.llorz.online/` 在浏览器中长时间停在 `#app-loader` 或看似无响应
- 服务器侧 `curl https://capgo.llorz.online/` 返回 **200**

## 原因

1. 控制台在加载非英语语言时会请求  
   `POST {VITE_API_HOST}/translation/messages`（自托管为 `https://supa.llorz.online/functions/v1/translation/messages`）。
2. 自托管仅同步了 `ok/`、`bundle/` 等子目录，**没有** `translation/` worker，主路由 `main/index.ts` 创建 worker 失败：
   ```
   InvalidWorkerCreation: could not find an appropriate entrypoint
   ```
   HTTP **500**。
3. `GET /private/config` 默认返回 `supaHost: http://kong:8000`（容器内 `SUPABASE_URL`），浏览器无法使用该地址（前端 build 仍用 `VITE_SUPABASE_URL`，但依赖远程 config 的逻辑会混淆）。

## 修复

1. 增加 `supabase/functions/translation/index.ts`：自托管返回 bundled `messages/en.json`（无 Cloudflare Workers AI）。
2. `deploy-self-hosted.sh` 同步 `messages/` 到 `volumes/functions/messages/`。
3. 每个子函数目录（含新建的 `translation/`）必须有 `deno.json -> ../deno.capgo.json` 符号链接，否则 worker 启动报 `hono/utils/buffer` 等模块解析错误。
4. `volumes/functions/.env` 设置 `SUPABASE_REPLICATE_URL=https://<supabase 域名>`。
5. `config.ts` 回退顺序：`SUPABASE_REPLICATE_URL` → `SUPABASE_PUBLIC_URL` → `SUPABASE_URL`。

## 验证

```bash
curl -sk -X POST "https://supa.llorz.online/functions/v1/translation/messages" \
  -H "Content-Type: application/json" \
  -d '{"targetLanguage":"zh-cn"}' | jq .status

curl -sk "https://supa.llorz.online/functions/v1/private/config" \
  -H "Origin: https://capgo.llorz.online" | jq .supaHost
```

期望：`status` 为 `"ready"`，`supaHost` 为公网 `https://supa.llorz.online`。

## 若仍无响应

- 浏览器硬刷新 / 清除站点数据（旧 Service Worker 可能触发重载）。
- Cloudflare SSL：**Full**（源站为 snakeoil 自签证书时勿用 Strict）。
- DevTools → Network：确认 `index-*.js`、Auth `getSession` 未挂起。
