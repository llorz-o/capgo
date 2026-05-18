#!/usr/bin/env bash
# Create or update a platform admin user (Auth + public.users + vault.admin_users).
# Idempotent: safe to re-run deploy.
set -euo pipefail

SECRETS_ENV_FILE="${SECRETS_ENV_FILE:-/root/supabase-project/.env}"
DB_CTN="${DB_CTN:-supabase-db}"
KONG_PORT="${KONG_PORT:-8000}"

INIT_ADMIN_EMAIL="${INIT_ADMIN_EMAIL:-admin@local.com}"
INIT_ADMIN_PASSWORD="${INIT_ADMIN_PASSWORD:-}"
INIT_ADMIN_FIRST_NAME="${INIT_ADMIN_FIRST_NAME:-Admin}"
INIT_ADMIN_LAST_NAME="${INIT_ADMIN_LAST_NAME:-Local}"

log() { printf '[init-admin] %s\n' "$*"; }
die() { printf '[init-admin] ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$SECRETS_ENV_FILE" ]] || die "未找到: $SECRETS_ENV_FILE"

read_env_var() {
  local key="$1"
  local line
  line="$(grep -E "^${key}=" "$SECRETS_ENV_FILE" | tail -1 || true)"
  [[ -n "$line" ]] || return 1
  printf '%s' "${line#*=}" | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"
}

SERVICE_ROLE_KEY="${SERVICE_ROLE_KEY:-$(read_env_var SERVICE_ROLE_KEY || true)}"
KONG_PORT="${KONG_PORT:-$(read_env_var KONG_HTTP_PORT || echo 8000)}"

[[ -n "$INIT_ADMIN_PASSWORD" ]] || die "请设置 INIT_ADMIN_PASSWORD（勿写入 git）"
[[ -n "$SERVICE_ROLE_KEY" ]] || die ".env 缺少 SERVICE_ROLE_KEY"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

require_cmd curl
require_cmd jq
require_cmd docker

auth_admin() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local url="http://127.0.0.1:${KONG_PORT}${path}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" "$url" \
      -H "apikey: ${SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body"
  else
    curl -sf -X "$method" "$url" \
      -H "apikey: ${SERVICE_ROLE_KEY}" \
      -H "Authorization: Bearer ${SERVICE_ROLE_KEY}" \
      -H "Content-Type: application/json"
  fi
}

get_user_id_by_email() {
  local email="$1"
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -tAc \
    "SELECT id::text FROM auth.users WHERE lower(email) = lower('${email//\'/\'\'}') LIMIT 1;" 2>/dev/null | tr -d '[:space:]'
}

ensure_auth_user() {
  local email="$1"
  local password="$2"
  local existing_id
  existing_id="$(get_user_id_by_email "$email")"

  if [[ -n "$existing_id" ]]; then
    log "Auth 用户已存在: $email ($existing_id)，更新密码并确认邮箱" >&2
    auth_admin PUT "/auth/v1/admin/users/${existing_id}" "$(jq -nc \
      --arg p "$password" \
      '{password: $p, email_confirm: true}')" >/dev/null
    echo "$existing_id"
    return
  fi

  log "创建 Auth 用户: $email" >&2
  local resp
  resp="$(auth_admin POST "/auth/v1/admin/users" "$(jq -nc \
    --arg e "$email" \
    --arg p "$password" \
    '{email: $e, password: $p, email_confirm: true}')")"
  echo "$resp" | jq -r '.id // .user.id // empty'
}

ensure_public_user() {
  local user_id="$1"
  local email="$2"
  local first="$3"
  local last="$4"
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
INSERT INTO public.users (id, email, first_name, last_name, country, enable_notifications, opt_for_newsletters, created_at, updated_at)
VALUES (
  '${user_id}'::uuid,
  '${email//\'/\'\'}',
  '${first//\'/\'\'}',
  '${last//\'/\'\'}',
  NULL,
  true,
  true,
  NOW(),
  NOW()
)
ON CONFLICT (id) DO UPDATE SET
  email = EXCLUDED.email,
  first_name = EXCLUDED.first_name,
  last_name = EXCLUDED.last_name,
  updated_at = NOW();
SQL
}

ensure_vault_platform_admin() {
  local user_id="$1"
  docker exec -i "$DB_CTN" psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
DECLARE
  v_user_id uuid := '${user_id}'::uuid;
  v_admins jsonb;
  v_new jsonb;
  v_secret_id uuid;
BEGIN
  SELECT id, decrypted_secret::jsonb
  INTO v_secret_id, v_admins
  FROM vault.decrypted_secrets
  WHERE name = 'admin_users'
  LIMIT 1;

  IF v_secret_id IS NULL THEN
    PERFORM vault.create_secret(
      jsonb_build_array(v_user_id::text)::text,
      'admin_users',
      'platform admin user ids'
    );
    RETURN;
  END IF;

  IF jsonb_typeof(v_admins) = 'array' THEN
    IF v_admins @> to_jsonb(v_user_id::text) THEN
      RETURN;
    END IF;
    v_new := v_admins || to_jsonb(v_user_id::text);
  ELSIF jsonb_typeof(v_admins) = 'object' THEN
    IF v_admins ? v_user_id::text THEN
      RETURN;
    END IF;
    v_new := v_admins || jsonb_build_object(v_user_id::text, true);
  ELSE
    v_new := jsonb_build_array(v_user_id::text);
  END IF;

  PERFORM vault.update_secret(v_secret_id, v_new::text);
END \$\$;
SQL
}

main() {
  local user_id
  user_id="$(ensure_auth_user "$INIT_ADMIN_EMAIL" "$INIT_ADMIN_PASSWORD")"
  [[ -n "$user_id" ]] || die "无法获取用户 ID"
  ensure_public_user "$user_id" "$INIT_ADMIN_EMAIL" "$INIT_ADMIN_FIRST_NAME" "$INIT_ADMIN_LAST_NAME"
  ensure_vault_platform_admin "$user_id"
  log "完成: $INIT_ADMIN_EMAIL (platform admin, id=$user_id)"
  log "登录: https://${CONSOLE_DOMAIN:-capgo.example.com}/login"
}

main "$@"
