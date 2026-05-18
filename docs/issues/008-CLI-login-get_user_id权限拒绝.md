# 008 — Capgo CLI `login` 报 Invalid API key（实为 RPC 权限）

## 现象

在项目目录执行（`capacitor.config.json` 已配置 `localSupa` / `localSupaAnon`）：

```bash
npx @capgo/cli@latest login <你的-api-key-uuid>
```

输出：

```text
Using custom supabase instance from capacitor.config.json
Invalid API key or insufficient permissions.
```

## 根因

1. API Key 在 `public.apikeys` 中**可能完全有效**（控制台创建、未过期）。
2. 当前 `@capgo/cli` 登录仍调用 PostgREST RPC：`get_user_id({ apikey })`，使用 **anon JWT**。
3. 上游安全迁移（如 `20260427105909_fix_apikey_helper_rpc_public_execute.sql`）已 **撤销 `anon` 对 `get_user_id(text)` 的 EXECUTE**，防止匿名探测任意 API Key。
4. PostgREST 返回 `42501 permission denied`，CLI 统一显示为「Invalid API key」。

直接验证：

```bash
curl -sk -X POST "https://<SUPABASE_DOMAIN>/rest/v1/rpc/get_user_id" \
  -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"apikey":"<你的-key>"}'
# 修复前: permission denied
```

带 `capgkey` 的 `get_orgs_v7` 仍可成功，说明 key 本身可用。

## 解决（自托管推荐）

1. **部署脚本默认已处理**：`RUN_BOOTSTRAP_CLI_ANON_GRANT=true` 会执行  
   [`supabase/self-hosted-bootstrap-cli-anon.sql`](../../supabase/self-hosted-bootstrap-cli-anon.sql)：

   ```sql
   GRANT EXECUTE ON FUNCTION public.get_user_id(text) TO anon;
   ```

2. **手工补跑**（已有环境、未重跑部署时）：

   ```bash
   docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
     < /path/to/capgo/supabase/self-hosted-bootstrap-cli-anon.sql
   ```

3. **应用项目** `capacitor.config` 须包含（与控制台构建用的 anon key 一致）：

   ```json
   "CapacitorUpdater": {
     "localSupa": "https://supa.example.com",
     "localSupaAnon": "<ANON_KEY>"
   }
   ```

## 安全说明

恢复 `anon` 对 `get_user_id` 的调用会重新开放「用任意字符串探测 user_id」的 oracle 面（与上游 GHSA 修复前类似）。**仅建议在受控的自托管内网使用**；官方 CLI 改用 `capgkey` 绑定校验后可设 `RUN_BOOTSTRAP_CLI_ANON_GRANT=false` 并撤销该 GRANT。

## 验证

```bash
# RPC 应返回用户 UUID 字符串
curl -sk -X POST "https://<SUPABASE_DOMAIN>/rest/v1/rpc/get_user_id" \
  -H "apikey: <ANON_KEY>" -H "Authorization: Bearer <ANON_KEY>" \
  -H "Content-Type: application/json" \
  -d '{"apikey":"<你的-key>"}'

npx @capgo/cli@latest login <你的-key>
```

## 全栈文档对照

- 相关章节：**§10.3**（CLI 与自托管）、**§12.1**（bundle 上传，登录成功后）
- 部署脚本：[`scripts/deploy-self-hosted.sh`](../../scripts/deploy-self-hosted.sh) 参数 `RUN_BOOTSTRAP_CLI_ANON_GRANT`
- 参考：[`/root/SELF_HOSTED_FULL_STACK.zh-CN.md`](/root/SELF_HOSTED_FULL_STACK.zh-CN.md)
