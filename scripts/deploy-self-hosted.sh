#!/usr/bin/env bash
# Capgo + Supabase self-hosted deploy (idempotent).
# Prerequisites (manual steps): docs/self-hosted-deploy-prerequisites.zh-CN.md
# Index: docs/self-hosted-deploy-index.md
# Full guide: SELF_HOSTED_FULL_STACK.zh-CN.md (repo-adjacent or /root/ on deploy host)
#
# Main env: CAPGO_REPO SUPABASE_PROJECT_DIR CONSOLE_DOMAIN SUPABASE_DOMAIN WEB_ROOT
#   RUN_DB_PUSH RUN_DB_SEED RUN_BOOTSTRAP_PLANS RUN_BOOTSTRAP_CLI_ANON_GRANT
#   INIT_ADMIN_* SECRETS_ENV_FILE SKIP_GIT_PULL USE_LETSENCRYPT (certbot not implemented)
set -euo pipefail

# ============ 可配置参数 ============
CAPGO_REPO="${CAPGO_REPO:-/root/capgos/capgo}"
SUPABASE_PROJECT_DIR="${SUPABASE_PROJECT_DIR:-/root/supabase-project}"
CONSOLE_DOMAIN="${CONSOLE_DOMAIN:-capgo.llorz.online}"
SUPABASE_DOMAIN="${SUPABASE_DOMAIN:-supa.llorz.online}"
WEB_ROOT="${WEB_ROOT:-/var/www/capgo/dist}"
USE_LETSENCRYPT="${USE_LETSENCRYPT:-false}"
SKIP_SUPABASE_CLONE="${SKIP_SUPABASE_CLONE:-false}"
SKIP_GIT_PULL="${SKIP_GIT_PULL:-false}"
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

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] ERROR: %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

load_secrets() {
  [[ -f "$SECRETS_ENV_FILE" ]] || die "未找到密钥文件: $SECRETS_ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_ENV_FILE"
  set +a
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
    log "克隆 Supabase docker 到 $SUPABASE_PROJECT_DIR (§3)"
    mkdir -p "$(dirname "$SUPABASE_PROJECT_DIR")"
    git clone --depth 1 https://github.com/supabase/supabase.git /tmp/supabase-upstream
    rsync -a /tmp/supabase-upstream/docker/ "$SUPABASE_PROJECT_DIR/"
    rm -rf /tmp/supabase-upstream
    if [[ -f "$SUPABASE_PROJECT_DIR/.env.example" ]] && [[ ! -f "$SECRETS_ENV_FILE" ]]; then
      cp "$SUPABASE_PROJECT_DIR/.env.example" "$SECRETS_ENV_FILE"
      log "已创建 $SECRETS_ENV_FILE — 请运行 generate-keys 并填写域名后重试"
      die "首次部署需配置 .env"
    fi
  fi
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

apply_migrations() {
  log "数据库迁移 (§5)"
  load_secrets
  local db_url="postgresql://postgres:${POSTGRES_PASSWORD}@127.0.0.1:5432/postgres?sslmode=disable"
  if [[ "$RUN_DB_PUSH" == "true" ]] && command -v supabase >/dev/null; then
    if (cd "$CAPGO_REPO" && supabase db push --db-url "$db_url"); then
      log "supabase db push 成功"
      return
    fi
    log "db push 失败，回退 psql 逐文件 (§5.2)"
  fi
  local mig_dir="$CAPGO_REPO/supabase/migrations"
  for f in $(ls -1 "$mig_dir"/*.sql | sort); do
    log "  $(basename "$f")"
    if grep -q 'CONCURRENTLY' "$f"; then
      docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f" || die "迁移失败: $f"
    else
      docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 -1 < "$f" || die "迁移失败: $f"
    fi
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
    log "自托管 CLI：授予 anon 执行 get_user_id(text)（capgo login）"
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
  mkdir -p "$vol/main"
  rsync -a --delete \
    --exclude 'deno.json' \
    "$CAPGO_REPO/supabase/functions/" "$vol/"
  rsync -a "$CAPGO_REPO/messages/" "$vol/messages/"
  cp "$CAPGO_REPO/supabase/functions/deno.json" "$vol/deno.capgo.json"
  rm -f "$vol/deno.json"
  cp "$CAPGO_REPO/scripts/templates/functions-main-index.ts" "$vol/main/index.ts"
  for d in "$vol"/*/; do
    local name=$(basename "$d")
    [[ "$name" == "main" || "$name" == "_backend" ]] && continue
    [[ -f "${d}index.ts" ]] || continue
    ln -sf ../deno.capgo.json "${d}deno.json"
  done
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
    (cd "$CAPGO_REPO" && git fetch && git checkout main && git pull)
    (cd "$CAPGO_REPO" && bun install)
  fi
  ensure_supabase_project
  if [[ -f "$SECRETS_ENV_FILE" ]]; then
    generate_keys_once
    load_secrets
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
