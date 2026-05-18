# Capgo 自托管部署文档索引

本目录收录**本机部署过程**中的问题记录与步骤索引。端到端技术细节与踩坑排查以服务器上的全栈指南为准。

## 权威参考（必读）

| 文档 | 路径 | 说明 |
| --- | --- | --- |
| **全栈部署指南** | [`/root/SELF_HOSTED_FULL_STACK.zh-CN.md`](/root/SELF_HOSTED_FULL_STACK.zh-CN.md) | 已验证的 Supabase Docker + Capgo 完整流程；**执行部署前必须先读** |
| **一键脚本前置条件（手工步骤）** | [`self-hosted-deploy-prerequisites.zh-CN.md`](self-hosted-deploy-prerequisites.zh-CN.md) | **`deploy-self-hosted.sh` 不会自动完成的事项**，须先配置再跑脚本 |
| **组件 / 镜像版本锁定** | [`self-hosted-version-pins.zh-CN.md`](self-hosted-version-pins.zh-CN.md) | Docker、Edge、Capacitor、CLI 等已验证版本，升级前必读 |
| **本仓库部署计划** | Cursor 计划 `capgo_自托管部署_8ea0d250.plan.md` | 与本机域名、路径、验收清单对齐的执行清单 |
| **Capgo README** | 仓库根目录 `README.md` | 自托管环境变量、Functions、Bento 等 |

## 关键章节速查（全栈文档）

| 主题 | 章节 |
| --- | --- |
| Kong 预签名 URL / `KONG_PORT_MAPS` | §3.5 |
| 数据库迁移与 `db push` 回退 | §5.1–§5.2 |
| PostgREST 重启 | §5.3 |
| Postgres Vault `db_url` / `apikey` | §5.4 |
| 自托管 bootstrap（`plans` / CLI `get_user_id`） | §5.5 |
| Storage 三桶 `capgo` / `apps` / `images` | §6 |
| Edge Functions / `deno.capgo.json` | §7 |
| Nginx 反代 | §4 |
| 验证清单 | §11 |
| Capgo CLI `login` / `capacitor.config` | §10.3；issues/008 |
| **Capgo CLI bundle 上传** | **§12.1** |

## 仓库内脚本与补丁

| 资源 | 路径 |
| --- | --- |
| 一键部署脚本 | [`scripts/deploy-self-hosted.sh`](../scripts/deploy-self-hosted.sh) |
| 版本采集脚本 | [`scripts/collect-self-hosted-versions.sh`](../scripts/collect-self-hosted-versions.sh) |
| 初始化平台管理员 | [`scripts/init-self-hosted-admin.sh`](../scripts/init-self-hosted-admin.sh) |
| **部署前置（脚本不涵盖）** | [`self-hosted-deploy-prerequisites.zh-CN.md`](self-hosted-deploy-prerequisites.zh-CN.md) |
| Compose 补丁 | [`scripts/patch-supabase-compose.py`](../scripts/patch-supabase-compose.py) |
| Functions 主路由模板 | [`scripts/templates/functions-main-index.ts`](../scripts/templates/functions-main-index.ts) |
| 自托管套餐 bootstrap | [`supabase/self-hosted-bootstrap-plans.sql`](../supabase/self-hosted-bootstrap-plans.sql) |
| 自托管 CLI login bootstrap | [`supabase/self-hosted-bootstrap-cli-anon.sql`](../supabase/self-hosted-bootstrap-cli-anon.sql) |
| 默认 Supabase 项目目录 | `SUPABASE_PROJECT_DIR=/root/supabase-project` |
| 迁移 SQL | [`supabase/migrations/`](../supabase/migrations/) |
| Functions 示例 env | [`supabase/functions/.env.example`](../supabase/functions/.env.example) |

### 一键脚本常用环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `RUN_DB_SEED` | `false` | 完整 `seed.sql`（会清空测试用户，生产慎用） |
| `RUN_BOOTSTRAP_PLANS` | `true` | 写入 `public.plans`（创建组织必需） |
| `RUN_BOOTSTRAP_CLI_ANON_GRANT` | `true` | 供 `@capgo/cli login`（见 issues/008） |
| `INIT_ADMIN_PASSWORD` | 空 | 设置后创建/更新平台管理员 |
| `SKIP_GIT_PULL` | `false` | 本地未推送代码时设为 `true` |
| `USE_LETSENCRYPT` | `false` | **未实现**，证书须手工配置 |

运行补丁示例：

```bash
export CAPGO_REPO=/root/capgos/capgo
export SUPABASE_PROJECT_DIR=/root/supabase-project
python3 "$CAPGO_REPO/scripts/patch-supabase-compose.py" --project-dir "$SUPABASE_PROJECT_DIR"
```

## 部署问题记录（issues）

部署中遇到的非平凡问题写入 [`issues/`](issues/)，命名与模板见 [`issues/README.md`](issues/README.md)。

**要求**：每篇 issues 文档须引用全栈文档章节号（如 §3.5、§5.4、§12.1），便于检索与复现。

## 本机域名（当前环境）

| 用途 | 域名 |
| --- | --- |
| Capgo 控制台 | `capgo.llorz.online` |
| Supabase API / Studio | `supa.llorz.online` |
