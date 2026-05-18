# 009 — Capgo CLI 与 `anon` RPC 权限对照表

## 背景

自托管 CLI 使用 **Supabase `ANON_KEY`** 建连，并在请求头带 **`capgkey`**。  
上游为修复 API Key oracle（GHSA）会 **撤销 `anon` 对部分 SECURITY DEFINER RPC 的 EXECUTE**。  
表现均为 PostgREST **`42501 permission denied`**，CLI 文案各异。

自托管通过 [`self-hosted-bootstrap-cli-anon.sql`](../../supabase/self-hosted-bootstrap-cli-anon.sql) 恢复 CLI 必需权限（`RUN_BOOTSTRAP_CLI_ANON_GRANT=true`）。

## 全栈文档对照

- **§10.3** CLI 与自托管  
- **§5.5** bootstrap SQL  
- 相关：[008](008-CLI-login-get_user_id权限拒绝.md)

---

## 对照表（CLI 调用的 RPC）

| RPC | `anon` 默认（迁移后） | 自托管 bootstrap | 影响的 CLI 命令 | 缺权限时的表现 |
| --- | --- | --- | --- | --- |
| `get_user_id(text)` | 否 | **是** | `login`、多数命令鉴权 | Invalid API key |
| `get_org_perm_for_apikey(text,text)` | 否 | **是** | `bundle upload`、channel、app 权限 | Cannot get permissions for organization |
| `is_paying_org(uuid)` | 否 | **是** | `bundle upload`（套餐提示） | 试用/付费警告不准（不阻断） |
| `is_trial_org(uuid)` | 否 | **是** | 同上 | 同上 |
| `get_org_members(uuid)` | 否 | **是** | `org members`、`org set` | 42501 / 空列表 |
| `get_identity_apikey_only(key_mode[])` | 否 | **是** | `org set`（2FA 等） | 42501 |
| `check_org_members_2fa_enabled(uuid)` | 否 | **是** | `org set` | 42501 |
| `check_org_members_password_policy(uuid)` | 否 | **是** | `org set` | 42501 |
| `cli_check_permission(...)` | 是 | — | RBAC 权限检查 | — |
| `get_orgs_v7()` | 是 | — | `org list`、选组织 | — |
| `exist_app_v2` / `exist_app_versions` | 是 | — | `app` / `upload` | — |
| `get_app_versions` | 是 | — | `upload` | — |
| `is_allowed_action` / `is_allowed_action_org*` | 是 | — | 套餐 / 配额 | — |
| `get_organization_cli_warnings` | 是 | — | `upload` 前提示 | — |
| `reject_access_due_to_2fa_for_*` | 是 | — | 2FA 门禁 | — |
| `has_2fa_enabled()` | 是 | — | `org set` | — |

## 故意不授予（安全）

| RPC | 原因 |
| --- | --- |
| `find_apikey_by_value(text)` | 任意 key 探测 |
| `get_user_id(text, text)` | 带 app_id 的 oracle 变体 |
| `get_org_perm_for_apikey_v2` | 仅 service_role；CLI 用 v1 |
| `get_orgs_v7(uuid)` | CLI 调用无参版 `get_orgs_v7()` |

## RLS 辅助函数（非 CLI 直调，但 `app list` 等依赖）

以下由迁移 [`20260427175506_temporary_cli_apps_list_anon_helper_grants.sql`](../../supabase/migrations/20260427175506_temporary_cli_apps_list_anon_helper_grants.sql) 等保留给 `anon`，**不在** bootstrap 中重复 GRANT：

- `get_apikey_header()`
- `is_apikey_expired(timestamptz)`
- `get_identity_org_appid(...)`
- `check_min_rights(...)`

## 验证

```bash
# 应全部为 t
docker exec -i supabase-db psql -U postgres -d postgres -c "
SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS fn,
       has_function_privilege('anon', p.oid, 'EXECUTE') AS ok
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN (
    'get_user_id','get_org_perm_for_apikey','is_paying_org','is_trial_org',
    'get_org_members','get_identity_apikey_only',
    'check_org_members_2fa_enabled','check_org_members_password_policy'
  )
ORDER BY 1;
"
```

## 升级注意

拉取 Capgo 新迁移后若再次 **REVOKE anon**，需重跑 bootstrap SQL 或设置 `RUN_BOOTSTRAP_CLI_ANON_GRANT=true` 重新部署。
