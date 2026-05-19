#!/usr/bin/env bash
# Capgo + Supabase self-hosted deploy (idempotent).
# Prerequisites (manual steps): docs/self-hosted-deploy-prerequisites.zh-CN.md
# Index: docs/self-hosted-deploy-index.md
# Full guide: SELF_HOSTED_FULL_STACK.zh-CN.md (repo-adjacent or /root/ on deploy host)
#
# Main env: CAPGO_REPO SUPABASE_PROJECT_DIR CONSOLE_DOMAIN SUPABASE_DOMAIN WEB_ROOT
#   POSTGRES_DIRECT_PORT (默认 54322，直连 Postgres；勿与 Supavisor 的 ${POSTGRES_PORT} 混淆)
#   SUPABASE_DOCKER_REF  Supabase docker/ 目录的 commit SHA / tag / branch；空 = 上游 master HEAD
#                        建议设为 self-hosted-version-pins.zh-CN.md §2 记录的已验证 SHA，避免上游漂移
#   CAPGO_REF            Capgo 仓库要 checkout 的 ref（默认 main，SKIP_GIT_PULL=true 时忽略）
#   RUN_DB_PUSH RUN_DB_SEED RUN_BOOTSTRAP_PLANS RUN_BOOTSTRAP_CLI_ANON_GRANT
#   INIT_ADMIN_* SECRETS_ENV_FILE SKIP_GIT_PULL USE_LETSENCRYPT (certbot not implemented)
set -euo pipefail

# ============ 可配置参数 ============
CAPGO_REPO="${CAPGO_REPO:-/root/capgos/capgo}"
SUPABASE_PROJECT_DIR="${SUPABASE_PROJECT_DIR:-/root/supabase-project}"
CONSOLE_DOMAIN="${CONSOLE_DOMAIN:-capgo.example.com}"
SUPABASE_DOMAIN="${SUPABASE_DOMAIN:-supa.example.com}"
WEB_ROOT="${WEB_ROOT:-/var/www/capgo/dist}"
USE_LETSENCRYPT="${USE_LETSENCRYPT:-false}"
SKIP_SUPABASE_CLONE="${SKIP_SUPABASE_CLONE:-false}"
SKIP_GIT_PULL="${SKIP_GIT_PULL:-false}"
# 版本锁定：避免「supabase/supabase master HEAD」漂移导致 patch 失效 / 镜像 tag 突变
# 留空 = 跟上游 master HEAD（不推荐生产）；填具体 commit SHA / tag = 可重建快照
SUPABASE_DOCKER_REF="${SUPABASE_DOCKER_REF:-}"
SUPABASE_DOCKER_REPO="${SUPABASE_DOCKER_REPO:-https://github.com/supabase/supabase.git}"
SUPABASE_REF_FILE="${SUPABASE_REF_FILE:-$SUPABASE_PROJECT_DIR/.supabase-docker-ref}"
CAPGO_REF="${CAPGO_REF:-main}"
RUN_DB_SEED="${RUN_DB_SEED:-false}"
RUN_BOOTSTRAP_PLANS="${RUN_BOOTSTRAP_PLANS:-true}"
# 恢复 anon 对 get_user_id(text) 的执行权，供 @capgo/cli login（见 supabase/self-hosted-bootstrap-cli-anon.sql）
RUN_BOOTSTRAP_CLI_ANON_GRANT="${RUN_BOOTSTRAP_CLI_ANON_GRANT:-true}"
RUN_DB_PUSH="${RUN_DB_PUSH:-true}"
# 自托管初始平台管理员（勿将 INIT_ADMIN_PASSWORD 提交到 git）
INIT_ADMIN_ENABLED="${INIT_ADMIN_ENABLED:-true}"
INIT_ADMIN_EMAIL="${INIT_ADMIN_EMAIL:-admin@local.com}"
INIT_ADMIN_PASSWORD="${INIT_ADMIN_PASSWORD:-}"
INIT_ADMIN_FIRST_NAME="${INIT_ADMIN_FIRST_NAME:-Admin}"
INIT_ADMIN_LAST_NAME="${INIT_ADMIN_LAST_NAME:-Local}"
# 密钥：优先从外部 env 文件加载（勿提交 git）
SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-$SUPABASE_PROJECT_DIR/.env}"
FUNCTIONS_ENV_FILE="${FUNCTIONS_ENV_FILE:-$SUPABASE_PROJECT_DIR/volumes/functions/.env}"
DB_CTN="${DB_CTN:-supabase-db}"
KONG_PORT="${KONG_PORT:-8000}"
# 官方 compose：${POSTGRES_PORT} 映射 Supavisor；直连 Postgres 见 patch-supabase-compose.py 暴露的 54322
POSTGRES_DIRECT_PORT="${POSTGRES_DIRECT_PORT:-54322}"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

load_secrets() {
  # 用 compose 风格解析 .env：按第一个 '=' 切分、取字面值，避免上游模板里
  # 形如 STUDIO_DEFAULT_ORGANIZATION=Default Organization 的未加引号字段
  # 在 `source` 时被 bash 当成命令执行。
  [[ -f "$SECRETS_ENV_FILE" ]] || die "未找到密钥文件: $SECRETS_ENV_FILE"
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "${line//[[:space:]]/}" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" != *=* ]] && continue
    key="${line%%=*}"
    val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    if [[ "${val:0:1}" == '"' && "${val: -1}" == '"' ]] || \
       [[ "${val:0:1}" == "'" && "${val: -1}" == "'" ]]; then
      val="${val:1:${#val}-2}"
    fi
    export "$key=$val"
  done < "$SECRETS_ENV_FILE"
}

preflight() {
  log "前置检查 (§0)"
  require_cmd docker
  require_cmd bun
  require_cmd nginx
  require_cmd python3
  require_cmd rsync
  docker compose version >/dev/null || die "需要 docker compose v2"
  ss -tlnp | grep -q ":${KONG_PORT} " || log "提示: 端口 ${KONG_PORT} 尚未监听（Supabase 未启动时正常）"
}

ensure_supabase_project() {
  if [[ "$SKIP_SUPABASE_CLONE" == "true" ]] && [[ -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ]]; then
    log "跳过 Supabase clone（已有 $SUPABASE_PROJECT_DIR）"
    return
  fi
  if [[ ! -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ]]; then
    mkdir -p "$(dirname "$SUPABASE_PROJECT_DIR")"
    local tmp ref_actual
    tmp="$(mktemp -d)"
    trap "rm -rf '$tmp'" RETURN
    if [[ -n "$SUPABASE_DOCKER_REF" ]]; then
      log "克隆 Supabase docker 到 $SUPABASE_PROJECT_DIR @ ref=$SUPABASE_DOCKER_REF (§3)"
      git clone --filter=blob:none --no-checkout "$SUPABASE_DOCKER_REPO" "$tmp/supabase-upstream"
      git -C "$tmp/supabase-upstream" checkout "$SUPABASE_DOCKER_REF" \
        || die "SUPABASE_DOCKER_REF 不存在: $SUPABASE_DOCKER_REF"
    else
      log "克隆 Supabase docker 到 $SUPABASE_PROJECT_DIR @ master HEAD（未锁定，生产建议设 SUPABASE_DOCKER_REF）(§3)"
      git clone --depth 1 "$SUPABASE_DOCKER_REPO" "$tmp/supabase-upstream"
    fi
    ref_actual="$(git -C "$tmp/supabase-upstream" rev-parse HEAD)"
    rsync -a "$tmp/supabase-upstream/docker/" "$SUPABASE_PROJECT_DIR/"
    printf '%s\n' "$ref_actual" > "$SUPABASE_REF_FILE"
    log "已记录 Supabase docker ref: $ref_actual -> $SUPABASE_REF_FILE"
    if [[ -f "$SUPABASE_PROJECT_DIR/.env.example" ]] && [[ ! -f "$SECRETS_ENV_FILE" ]]; then
      cp "$SUPABASE_PROJECT_DIR/.env.example" "$SECRETS_ENV_FILE"
      log "已创建 $SECRETS_ENV_FILE — 请运行 generate-keys 并填写域名后重试"
      die "首次部署需配置 .env"
    fi
  else
    if [[ -f "$SUPABASE_REF_FILE" ]] && [[ -n "$SUPABASE_DOCKER_REF" ]]; then
      local pinned current
      current="$(tr -d '[:space:]' < "$SUPABASE_REF_FILE")"
      pinned="$SUPABASE_DOCKER_REF"
      if [[ "$current" != "$pinned" && "$current" != "$pinned"* && "$pinned" != "$current"* ]]; then
        log "提示: 已部署的 Supabase docker ref=$current 与当前 SUPABASE_DOCKER_REF=$pinned 不一致；如需重置请先跑 cleanup-self-hosted.sh"
      fi
    fi
  fi
}

# Compose 补丁会为 functions 挂载 env_file；首次 up 前必须存在，否则
# "env file .../volumes/functions/.env not found"。
ensure_functions_env_file() {
  mkdir -p "$(dirname "$FUNCTIONS_ENV_FILE")"
  if [[ ! -f "$FUNCTIONS_ENV_FILE" ]]; then
    cat > "$FUNCTIONS_ENV_FILE" <<EOF
API_SECRET=${CAPGO_API_SECRET:-CHANGE_ME}
WEBAPP_URL=https://${CONSOLE_DOMAIN}
SUPABASE_REPLICATE_URL=https://${SUPABASE_DOMAIN}
CAPGO_PREVENT_BACKGROUND_FUNCTIONS=true
EOF
  fi
  grep -q '^SUPABASE_REPLICATE_URL=' "$FUNCTIONS_ENV_FILE" 2>/dev/null || \
    echo "SUPABASE_REPLICATE_URL=https://${SUPABASE_DOMAIN}" >> "$FUNCTIONS_ENV_FILE"
}

generate_keys_once() {
  if grep -q 'CHANGE_ME\|your-super-secret' "$SECRETS_ENV_FILE" 2>/dev/null; then
    log "运行 generate-keys.sh (§3)"
    (cd "$SUPABASE_PROJECT_DIR" && sh ./utils/generate-keys.sh)
    (cd "$SUPABASE_PROJECT_DIR" && sh ./utils/add-new-auth-keys.sh 2>/dev/null || true)
  fi
  grep -q "^FUNCTIONS_PUBLIC_API_HOSTNAME=" "$SECRETS_ENV_FILE" || \
    echo "FUNCTIONS_PUBLIC_API_HOSTNAME=${SUPABASE_DOMAIN}" >> "$SECRETS_ENV_FILE"
  grep -q "^CAPGO_API_SECRET=" "$SECRETS_ENV_FILE" || \
    echo "CAPGO_API_SECRET=CHANGE_ME" >> "$SECRETS_ENV_FILE"
  grep -q "^SITE_URL=https://${CONSOLE_DOMAIN}" "$SECRETS_ENV_FILE" || {
    log "请确认 .env 中 SITE_URL / SUPABASE_PUBLIC_URL / API_EXTERNAL_URL (§3)"
  }
}

patch_and_up_supabase() {
  log "补丁 compose (§3.5 / 附录 A.4)"
  export SUPABASE_PROJECT_DIR
  python3 "$CAPGO_REPO/scripts/patch-supabase-compose.py" --project-dir "$SUPABASE_PROJECT_DIR"
  log "启动 Supabase 栈"
  (cd "$SUPABASE_PROJECT_DIR" && docker compose pull && docker compose up -d)
  (cd "$SUPABASE_PROJECT_DIR" && docker compose up -d kong storage functions)
}

# 供 supabase CLI 连接「真实 Postgres」：须用 POSTGRES_DIRECT_PORT（见 patch），勿用 ${POSTGRES_PORT}（Supavisor）
migration_db_url() {
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}" POSTGRES_DIRECT_PORT="${POSTGRES_DIRECT_PORT:-54322}" python3 <<'PY'
import os
from urllib.parse import quote_plus
pw = os.environ.get("POSTGRES_PASSWORD") or ""
port = os.environ.get("POSTGRES_DIRECT_PORT") or "54322"
print(f"postgresql://postgres:{quote_plus(pw)}@127.0.0.1:{port}/postgres?sslmode=disable")
PY
}

# psql 逐文件回退路径不会自动写迁移历史，重跑会重复执行 base.sql 等导致 "already exists"
ensure_supabase_migration_history_table() {
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE SCHEMA IF NOT EXISTS supabase_migrations;
CREATE TABLE IF NOT EXISTS supabase_migrations.schema_migrations (
  version text NOT NULL PRIMARY KEY
);
ALTER TABLE supabase_migrations.schema_migrations
  ADD COLUMN IF NOT EXISTS name text NOT NULL DEFAULT '';
ALTER TABLE supabase_migrations.schema_migrations
  ADD COLUMN IF NOT EXISTS statements text[] NOT NULL DEFAULT ARRAY[]::text[];
SQL
}

migration_version_from_filename() {
  local base
  base="$(basename "$1")"
  printf '%s' "${base%%_*}"
}

is_migration_version_applied() {
  local ver="$1"
  local out
  out="$(docker exec "$DB_CTN" psql -U postgres -d postgres -tAc \
    "SELECT EXISTS (SELECT 1 FROM supabase_migrations.schema_migrations WHERE version = '$ver')" \
    2>/dev/null | tr -d '[:space:]')"
  [[ "$out" == "t" ]]
}

record_migration_applied() {
  local ver="$1" fname="$2"
  ver="${ver//\'/\'\'}"
  fname="${fname//\'/\'\'}"
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
INSERT INTO supabase_migrations.schema_migrations (version, name, statements)
VALUES ('$ver', '$fname', ARRAY[]::text[])
ON CONFLICT (version) DO NOTHING;
SQL
}

apply_migrations() {
  log "数据库迁移 (§5)"
  load_secrets
  local db_url
  db_url="$(migration_db_url)"
  if [[ "$RUN_DB_PUSH" == "true" ]] && command -v supabase >/dev/null; then
    # PGSSLMODE：部分环境下 CLI 仍走 libpq/SSL 探测；与 URL 中 sslmode=disable 双保险
    if (
      cd "$CAPGO_REPO" && PGSSLMODE=disable PGGSSENCMODE=disable \
        supabase db push --db-url "$db_url" --yes
    ); then
      log "supabase db push 成功"
      return
    fi
    log "db push 失败，回退 psql 逐文件 (§5.2)"
  fi
  ensure_supabase_migration_history_table
  local drift
  drift="$(docker exec "$DB_CTN" psql -U postgres -d postgres -tAc \
    "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'public' AND t.typname = 'action_type')" \
    2>/dev/null | tr -d '[:space:]')"
  if [[ "$drift" == "t" ]] && ! is_migration_version_applied "20250530233128"; then
    die "库内已有 public.action_type，但迁移表未记录 20250530233128。常见原因：(1) docker compose down -v 不会删除 bind mount 的 volumes/db/data，请另执行 sudo rm -rf $SUPABASE_PROJECT_DIR/volumes/db/data 后再 up；(2) 此前 psql 回退未写迁移历史。无法安全重放 base.sql。若确认基线已完整应用，可手工向 supabase_migrations.schema_migrations 插入 version=20250530233128。"
  fi
  local mig_dir="$CAPGO_REPO/supabase/migrations"
  local f ver bn
  for f in $(ls -1 "$mig_dir"/*.sql | sort); do
    bn="$(basename "$f")"
    ver="$(migration_version_from_filename "$f")"
    if is_migration_version_applied "$ver"; then
      log "  跳过（已记录） $bn"
      continue
    fi
    log "  $bn"
    if grep -q 'CONCURRENTLY' "$f"; then
      docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f" || die "迁移失败: $f"
    else
      docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -1 < "$f" || die "迁移失败: $f"
    fi
    record_migration_applied "$ver" "$bn"
  done
}

db_post_steps() {
  log "PostgREST + 三桶 + Vault (§5.3–§5.4, §6)"
  (cd "$SUPABASE_PROJECT_DIR" && docker compose restart rest)
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO storage.buckets (id, name, owner, created_at, updated_at, public)
VALUES
  ('capgo', 'capgo', NULL, NOW(), NOW(), true),
  ('apps', 'apps', NULL, NOW(), NOW(), false),
  ('images', 'images', NULL, NOW(), NOW(), false)
ON CONFLICT (id) DO NOTHING;
SQL
  if [[ -n "${CAPGO_API_SECRET:-}" ]] && [[ "$CAPGO_API_SECRET" != "CHANGE_ME" ]]; then
    docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
SELECT vault.create_secret('http://kong:8000', 'db_url', 'pg_net -> Kong');
SELECT vault.create_secret('${CAPGO_API_SECRET}', 'apikey', 'queue_consumer apisecret');
SQL
  else
    log "跳过 Vault apikey：请在 .env 设置 CAPGO_API_SECRET 后手动 vault.create_secret (§5.4)"
  fi
  if [[ "$RUN_BOOTSTRAP_PLANS" == "true" ]]; then
    log "写入自托管套餐目录 (plans)"
    docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      < "$CAPGO_REPO/supabase/self-hosted-bootstrap-plans.sql"
  fi
  if [[ "$RUN_BOOTSTRAP_CLI_ANON_GRANT" == "true" ]]; then
    log "自托管 CLI：授予 anon 执行 CLI 所需 RPC（login、upload、org 等，见 issues/009）"
    docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
      < "$CAPGO_REPO/supabase/self-hosted-bootstrap-cli-anon.sql"
  fi
  if [[ "$RUN_DB_SEED" == "true" ]]; then
    log "执行 seed.sql"
    docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$CAPGO_REPO/supabase/seed.sql"
  fi
}

init_admin_user() {
  if [[ "$INIT_ADMIN_ENABLED" != "true" ]]; then
    log "跳过初始化 admin（INIT_ADMIN_ENABLED=false）"
    return
  fi
  if [[ -z "$INIT_ADMIN_PASSWORD" ]]; then
    log "跳过初始化 admin：请设置环境变量 INIT_ADMIN_PASSWORD"
    return
  fi
  log "初始化平台管理员 (§9)"
  export SECRETS_ENV_FILE DB_CTN KONG_PORT CONSOLE_DOMAIN
  export INIT_ADMIN_EMAIL INIT_ADMIN_PASSWORD INIT_ADMIN_FIRST_NAME INIT_ADMIN_LAST_NAME
  bash "$CAPGO_REPO/scripts/init-self-hosted-admin.sh"
}

sync_functions() {
  log "同步 Edge Functions (§7)"
  local vol="$SUPABASE_PROJECT_DIR/volumes/functions"
  rsync -a --delete \
    --exclude 'deno.json' \
    "$CAPGO_REPO/supabase/functions/" "$vol/"
  rsync -a "$CAPGO_REPO/messages/" "$vol/messages/"
  cp "$CAPGO_REPO/supabase/functions/deno.json" "$vol/deno.capgo.json"
  rm -f "$vol/deno.json"
  # main/ 不在仓库 functions 树内，若先于 rsync 创建会被 --delete 删掉
  mkdir -p "$vol/main"
  cp "$CAPGO_REPO/scripts/templates/functions-main-index.ts" "$vol/main/index.ts"
  for d in "$vol"/*/; do
    local name=$(basename "$d")
    [[ "$name" == "main" || "$name" == "_backend" ]] && continue
    [[ -f "${d}index.ts" ]] || continue
    ln -sf ../deno.capgo.json "${d}deno.json"
  done
  ensure_functions_env_file
  (cd "$SUPABASE_PROJECT_DIR" && docker compose up -d --force-recreate --no-deps functions)
}

build_console() {
  log "构建控制台 (§8)"
  load_secrets
  export BRANCH=prod
  export BASE_DOMAIN="$CONSOLE_DOMAIN"
  export SUPA_URL="https://${SUPABASE_DOMAIN}"
  export SUPA_ANON="${ANON_KEY:-}"
  export API_DOMAIN="${SUPABASE_DOMAIN}/functions/v1"
  export CAPTCHA_KEY=
  export VITE_CAPTCHA_KEY=
  export VITE_STRIPE_ENABLED=false
  (cd "$CAPGO_REPO" && bun install && bun run build)
  mkdir -p "$WEB_ROOT"
  rsync -a "$CAPGO_REPO/dist/" "$WEB_ROOT/"
}

health_check() {
  log "健康检查 (§11, §12.1)"
  local ok=0
  curl -sf "http://127.0.0.1:${KONG_PORT}/functions/v1/ok" | grep -q '"status":"ok"' && ok=1
  if [[ "$ok" -eq 1 ]]; then
    log "  functions/v1/ok: OK"
  else
    log "  functions/v1/ok: FAIL"
  fi
  local s3r
  s3r=$(docker exec supabase-edge-functions printenv S3_REGION 2>/dev/null || echo "")
  local reg
  reg=$(docker exec supabase-edge-functions printenv REGION 2>/dev/null || echo "")
  if [[ "$s3r" == "${REGION:-stub}" ]] || [[ -n "$s3r" && "$s3r" != "" ]]; then
    log "  S3_REGION=${s3r} (compose REGION=${REGION:-stub})"
  fi
  curl -sf -o /dev/null -H "Host: ${SUPABASE_DOMAIN}" -H "apikey: ${ANON_KEY:-}" \
    "https://127.0.0.1/auth/v1/health" -k && log "  auth health: OK" || log "  auth health: 需公网/DNS"
  curl -sf -o /dev/null -H "Host: ${CONSOLE_DOMAIN}" "https://127.0.0.1/" -k && log "  console: OK" || true
  log "bundle 上传请按 §12.1 用 Capgo CLI 实测 upload_link → PUT"
}

backup_cron_hint() {
  log "备份建议 (§3 HA 基础)"
  cat <<'CRON'

# 示例 crontab（postgres 密码勿写入命令行历史）:
# 0 3 * * * docker exec supabase-db pg_dump -U postgres postgres | gzip > /var/backups/supabase-$(date +\%F).sql.gz

CRON
}

main() {
  preflight
  [[ -d "$CAPGO_REPO" ]] || die "Capgo 仓库不存在: $CAPGO_REPO"
  if [[ "$SKIP_GIT_PULL" != "true" ]]; then
    log "同步 Capgo 仓库到 ref=$CAPGO_REF"
    (cd "$CAPGO_REPO" && git fetch --tags origin && git checkout "$CAPGO_REF" \
      && { git rev-parse --verify --quiet "$CAPGO_REF^{commit}" >/dev/null && \
           git symbolic-ref -q HEAD >/dev/null && git pull --ff-only origin "$CAPGO_REF" || true; })
    (cd "$CAPGO_REPO" && bun install)
  fi
  ensure_supabase_project
  if [[ -f "$SECRETS_ENV_FILE" ]]; then
    generate_keys_once
    load_secrets
    ensure_functions_env_file
    patch_and_up_supabase
    apply_migrations
    db_post_steps
    init_admin_user
    sync_functions
    build_console
    health_check
    backup_cron_hint
  else
    die "缺少 $SECRETS_ENV_FILE"
  fi
  log "完成。请验收: https://${CONSOLE_DOMAIN} https://${SUPABASE_DOMAIN}/functions/v1/ok"
  log "手工前置项见: $CAPGO_REPO/docs/self-hosted-deploy-prerequisites.zh-CN.md"
  log "问题记录: $CAPGO_REPO/docs/issues/"
}

main "$@"
