# 自托管组件与镜像版本锁定

记录当前**已验证可部署**的组件版本，避免单独升级某个镜像/插件导致 Kong、Storage、Edge、迁移或 CLI 上传链路不兼容。

| 元数据 | 值 |
| --- | --- |
| **记录日期** | 2026-05-19 |
| **Capgo 仓库提交** | `955814dd39c66090958f41208a75a37c52f93e3c`（`deploy-self-hosted.sh` 默认 `CAPGO_REF`） |
| **Capgo 应用版本** | `12.139.0`（`package.json`） |
| **部署环境示例** | `capgo.example.com` / `supa.example.com` |
| **Supabase 项目目录** | `/root/supabase-project` |

升级任一区块前，请先阅读文末 [升级原则](#升级原则)，并在测试环境完整跑通 [验收清单](self-hosted-deploy-prerequisites.zh-CN.md#10-部署后验收建议逐项打勾)。

---

## 如何刷新本表

在部署机上执行（会打印 Markdown 片段，可对照更新本文 Docker / 工具章节）：

```bash
export CAPGO_REPO=/root/capgos/capgo
export SUPABASE_PROJECT_DIR=/root/supabase-project
bash "$CAPGO_REPO/scripts/collect-self-hosted-versions.sh"
```

---

## 1. 宿主机工具（构建与脚本）

| 组件 | 锁定版本 | 说明 |
| --- | --- | --- |
| **Linux 内核** | `6.1.x`（示例） | 以 `uname -r` 为准 |
| **Docker Engine** | `28.5.1` | `docker --version` |
| **Docker Compose** | `v2.40.1` | 须为 Compose 插件，非独立 `docker-compose` |
| **Bun** | `1.3.11` | 构建控制台；`bun --version` |
| **Python 3** | `3.11.2` | `patch-supabase-compose.py` |
| **Nginx** | `1.22.1` | 仅反代；脚本不安装 |
| **rsync** | 系统包 | 同步 `dist/` 与 Functions |

**建议**：生产环境对 Docker / Bun 做**小版本**升级前先在副本机验证 `deploy-self-hosted.sh` 全流程。

---

## 2. Supabase Docker 镜像（核心栈）

来源：`$SUPABASE_PROJECT_DIR/docker-compose.yml`（自官方 [Supabase Docker](https://github.com/supabase/supabase/tree/master/docker) 克隆后经 `patch-supabase-compose.py` 补丁）。

### 2.0 上游 commit 锁定（**强烈建议生产填具体 SHA**）

| 项 | 值 |
| --- | --- |
| **Supabase docker/ 仓库** | `https://github.com/supabase/supabase.git` |
| **当前已部署 ref（默认 pin）** | `09bbb7c323b017cda034ab307fe83edf2cbd0619`（`deploy-self-hosted.sh` 默认 `SUPABASE_DOCKER_REF`；与 `master` HEAD 2026-05-19 一致） |
| **此 ref 抓取日期** | 2026-05-19 |

- 一键脚本默认 `SUPABASE_DOCKER_REF` / `CAPGO_REF` 与本表一致；跟分支开发可 `export CAPGO_REF=main`；跟踪上游 Supabase 最新可 `export SUPABASE_DOCKER_REF=master`（不推荐生产）。
- 首次部署完成后，脚本会把实际 Supabase SHA 写到 `$SUPABASE_PROJECT_DIR/.supabase-docker-ref`，若与上表不同请更新本表。

下面的镜像表「随这一行 SHA 一起被锁定」；只升级镜像 tag 而不更新 `SUPABASE_DOCKER_REF` 会导致 compose 文件结构变化，`patch-supabase-compose.py` 可能命中不上，部署日志会出现 `WARN: 以下补丁未命中` 警告。

| 服务 | 镜像 | 容器名 |
| --- | --- | --- |
| Postgres | `supabase/postgres:15.8.1.085` | `supabase-db` |
| Kong 网关 | `kong/kong:3.9.1` | `supabase-kong` |
| GoTrue (Auth) | `supabase/gotrue:v2.186.0` | `supabase-auth` |
| PostgREST | `postgrest/postgrest:v14.8` | `supabase-rest` |
| Realtime | `supabase/realtime:v2.76.5` | `realtime-dev.supabase-realtime` |
| Storage API | `supabase/storage-api:v1.48.26` | `supabase-storage` |
| **Edge Runtime** | `supabase/edge-runtime:v1.71.2` | `supabase-edge-functions` |
| Studio | `supabase/studio:2026.04.27-sha-5f60601` | `supabase-studio` |
| Postgres Meta | `supabase/postgres-meta:v0.96.3` | `supabase-meta` |
| Logflare (Analytics) | `supabase/logflare:1.36.1` | `supabase-analytics` |
| Supavisor (Pooler) | `supabase/supavisor:2.7.4` | `supabase-pooler` |
| imgproxy | `darthsim/imgproxy:v3.30.1` | `supabase-imgproxy` |
| Vector | `timberio/vector:0.53.0-alpine` | `supabase-vector` |

### 2.1 Capgo 补丁依赖的镜像能力

`patch-supabase-compose.py` **假定** compose 里 Functions 镜像为 `supabase/edge-runtime:v1.71.2`。若官方模板改为其他 tag，补丁中的字符串替换可能失效，需人工合并：

| 补丁项 | 作用 | 不兼容时现象 |
| --- | --- | --- |
| `KONG_PORT_MAPS` | 预签名 URL 不出现 `:8000` | CLI `fetch failed`、上传超时 |
| `S3_PROTOCOL_PREFIX` | Storage SigV4 路径一致 | bundle PUT `403` |
| `functions.env_file` + `S3_*` | Edge 内 s3-lite 预签名 | `unknown_error` / Invalid endPoint |
| `extra_hosts` + `FUNCTIONS_PUBLIC_API_HOSTNAME` | 避免 NAT hairpin | `WorkerRequestCancelled` |

### 2.2 `.env` 中与版本相关的变量

| 变量 | 示例值 | 须与谁一致 |
| --- | --- | --- |
| `REGION` | `stub`（常见） | `functions` 的 `S3_REGION`、Storage |
| `KONG_HTTP_PORT` | `8000` | Nginx `proxy_pass` |
| Postgres 主版本 | `15` | 镜像 `15.8.1.085`；勿混用 PG16 镜像 + PG15 数据卷 |

---

## 3. Capgo 应用与构建链

| 组件 | 版本 | 文件 |
| --- | --- | --- |
| Capgo 控制台 / 仓库 | `12.139.0` | `package.json` `version` |
| **Vite** | `8.0.10` | `devDependencies` |
| **Vue** | `3.5.33` | `dependencies` |
| **TypeScript** | `6.0.3` | `devDependencies` |
| **@supabase/supabase-js**（前端） | `2.105.1` | `dependencies` |
| **Supabase CLI**（可选，迁移） | `^2.98.2` | `devDependencies`；`bunx supabase --version` |

构建时自托管覆盖变量见 [前置文档 §6](self-hosted-deploy-prerequisites.zh-CN.md#6-supabase-env-密钥第一次部署必做) 与全栈 **附录 A.1**。

---

## 4. Edge Functions（Deno 依赖）

主 import map：`supabase/functions/deno.json`（同步到 `volumes/functions/deno.capgo.json`）。

| 包 | 锁定版本 |
| --- | --- |
| `hono` | `4.12.15` |
| `@supabase/supabase-js` | `2.105.1` |
| `stripe` | `22.1.0` |
| `drizzle-orm` | `1.0.0-rc.1` |
| `dayjs` | `1.11.20` |
| `pg` | `8.20.0` |
| `@bradenmacdonald/s3-lite-client` | `0.9.6` (JSR) |

Edge 运行时版本由镜像 **`supabase/edge-runtime:v1.71.2`** 内置 Deno 决定；勿仅升级 `deno.json` 而长期不升级 edge-runtime 镜像（反之亦然）。

---

## 5. Capacitor 与 Capgo 插件（App / 控制台演示）

控制台仓库同时包含 Capacitor 8 依赖。下表为 `package.json` 声明；**精确解析版本以 `bun.lock` 为准**。

### 5.1 Capacitor 核心

| 包 | 范围 / 锁定 |
| --- | --- |
| `@capacitor/core` | `^8.3.3` |
| `@capacitor/cli` | `^8.3.3` |
| `@capacitor/android` / `ios` | `^8.3.3` |

### 5.2 与 OTA / 自托管强相关

| 包 | 范围 / 锁定 | 说明 |
| --- | --- | --- |
| **`@capgo/capacitor-updater`** | `^8.45.11`（lock: `8.45.11`） | 终端热更新；须与 CLI、服务端 API 匹配 |
| `@capgo/cli`（workspace） | `7.102.0` | `cli/package.json` |
| **npm 发布 CLI**（本机常用） | `7.104.0`（`npx @capgo/cli@latest` 实测） | 依赖 bootstrap 授予 `get_user_id`、`get_org_perm_for_apikey` |

### 5.3 其他 `@capgo/*` 插件（节选）

| 包 | 版本 |
| --- | --- |
| `@capgo/capacitor-native-biometric` | `^8.4.5` |
| `@capgo/inappbrowser` | `^8.6.5` |
| `@capgo/native-audio` | `^8.4.2` |

完整列表见 `package.json` `dependencies`；升级插件后需重新 `bun install` 并 `cap sync`（若构建移动客户端）。

---

## 6. 数据库迁移

| 项 | 说明 |
| --- | --- |
| **迁移来源** | `capgo/supabase/migrations/*.sql`（按文件名排序） |
| **与 Capgo 提交绑定** | 升级 `main` 后务必跑迁移 + `db_post_steps` |
| **自托管 bootstrap** | `self-hosted-bootstrap-plans.sql`、`self-hosted-bootstrap-cli-anon.sql`（非 `seed.sql`） |

禁止：只升级 Postgres 镜像大版本而不做官方升级文档要求的 dump/restore。

---

## 7. 已知「跨组件」兼容组合（摘要）

以下为当前栈上已踩坑、文档化过的组合约束：

| 若升级… | 建议同时检查… |
| --- | --- |
| `storage-api` | `S3_PROTOCOL_PREFIX`、Kong 转发头、§12.1 上传 |
| `edge-runtime` | `deno.json`、`deno.capgo.json` 符号链接、Functions 日志 |
| `kong` | `KONG_PORT_MAPS`、`KONG_TRUSTED_IPS`、Nginx `X-Forwarded-*` |
| Capgo `main` 拉取 | 新 migrations、bootstrap SQL、是否需重建控制台 |
| `@capgo/cli` 大版本 | `RUN_BOOTSTRAP_CLI_ANON_GRANT`、issues/008 |
| 仅 `docker compose pull` | 不要跳过 PostgREST restart 与 Functions `--force-recreate` |

---

## 8. 升级原则

1. **一次只动一层**：例如先只升 Storage 镜像，验证 bundle 上传，再动 Kong。
2. **先备份**：`pg_dump`（见 `deploy-self-hosted.sh` 末尾 crontab 提示）。
3. **锁定 compose**：升级前复制 `docker-compose.yml` 与 `.env`；记录 `docker compose images` 输出。
4. **Capgo 代码**：用 `CAPGO_REF=<sha>`（或 `SKIP_GIT_PULL=true`）固定在已知 commit，验证后再切到新分支/tag。
5. **不要**在生产首次试用 `latest` 标签的 Supabase 全家桶；优先改 tag 后 `pull` + 回归 §10 / §12.1。
6. 升级后执行：`bash scripts/collect-self-hosted-versions.sh`，更新本文「记录日期」与表格。

### 8.1 推荐 bump 流程（Supabase docker ref）

```bash
# 1) 测试机：先抓上游最新 commit
git ls-remote https://github.com/supabase/supabase.git HEAD     # 拿到 NEW_SHA

# 2) 测试机：用 NEW_SHA 全新部署（清掉旧环境与锁文件）
bash "$CAPGO_REPO/scripts/cleanup-self-hosted.sh" --yes --wipe-env
SUPABASE_DOCKER_REF=NEW_SHA bash "$CAPGO_REPO/scripts/deploy-self-hosted.sh"

# 3) 跑前置文档 §10 验收 + §12.1 CLI bundle upload；
#    若 patch-supabase-compose.py 打印 "WARN: 以下补丁未命中"，先修补丁

# 4) 通过后回到生产机：
SUPABASE_DOCKER_REF=NEW_SHA bash "$CAPGO_REPO/scripts/deploy-self-hosted.sh"
#    （建议先 cleanup-self-hosted.sh --yes 重抓；或手工备份 .env / db_dump）

# 5) 把 NEW_SHA 与新日期写入本文 §2.0，更新下方镜像 tag 表
```

---

## 9. 相关文档

- [部署索引](self-hosted-deploy-index.md)
- [前置条件](self-hosted-deploy-prerequisites.zh-CN.md)
- [issues/](issues/)（按现象反查版本/配置）
- [全栈指南](/root/SELF_HOSTED_FULL_STACK.zh-CN.md)
