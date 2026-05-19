#!/usr/bin/env bash
# Capgo + Supabase self-hosted cleanup (idempotent, safe by default).
# 用于一键脚本失败/库迁移卡死时把环境清回「干净」状态再重跑 deploy-self-hosted.sh。
#
# 默认 NOT 删除：
#   - /etc/nginx 站点配置与 /etc/letsencrypt 证书
#   - Capgo 仓库 /root/capgos
#   - Supabase 项目根目录下的 .env / docker-compose.yml / 初始化 SQL 等配置
#   - Docker 镜像（可加 --prune-images）
#
# 默认 DO 删除（最常见的失败源头）：
#   - 全部 supabase-* 容器、命名卷、专属网络
#   - PostgreSQL bind mount 数据目录 volumes/db/data
#   - Storage bind mount 数据目录 volumes/storage
#   - Edge Functions 同步副本 volumes/functions（仓库源码不动）
#   - 控制台静态产物 $WEB_ROOT（默认 /var/www/capgo）
#
# 用法：
#   bash cleanup-self-hosted.sh                # 默认清理，含确认
#   bash cleanup-self-hosted.sh --yes          # 跳过确认
#   bash cleanup-self-hosted.sh --keep-env     # 保留 .env（默认就保留；显式声明）
#   bash cleanup-self-hosted.sh --wipe-env     # 同时删 .env（密钥要重生成）
#   bash cleanup-self-hosted.sh --prune-images # 顺手 docker image prune -a -f
#   bash cleanup-self-hosted.sh --dry-run      # 只打印将要做什么
#   SUPABASE_PROJECT_DIR=/path WEB_ROOT=/var/www/capgo bash cleanup-self-hosted.sh

set -euo pipefail

SUPABASE_PROJECT_DIR="${SUPABASE_PROJECT_DIR:-/root/supabase-project}"
WEB_ROOT="${WEB_ROOT:-/var/www/capgo}"

ASSUME_YES=false
DRY_RUN=false
WIPE_ENV=false
PRUNE_IMAGES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)        ASSUME_YES=true ;;
    --dry-run|-n)    DRY_RUN=true ;;
    --wipe-env)      WIPE_ENV=true ;;
    --keep-env)      WIPE_ENV=false ;;
    --prune-images)  PRUNE_IMAGES=true ;;
    -h|--help)
      sed -n '2,32p' "$0"
      exit 0
      ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
  shift
done

log()  { printf '[cleanup] %s\n' "$*"; }
warn() { printf '[cleanup] WARN: %s\n' "$*" >&2; }
run()  {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    eval "$@"
  fi
}

# ============ 探查 ============

discover() {
  log "项目目录: $SUPABASE_PROJECT_DIR"
  log "控制台 WEB_ROOT: $WEB_ROOT"
  if [[ -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ]]; then
    log "compose 文件存在: $SUPABASE_PROJECT_DIR/docker-compose.yml"
  else
    warn "compose 文件不存在；将仅按名称兜底清理 supabase-* 容器"
  fi

  log "--- 当前 supabase-* 容器 ---"
  local ctn_lines
  ctn_lines="$(docker ps -a --format '{{.Names}}\t{{.Status}}' 2>/dev/null | grep -E '^(supabase-|realtime-dev.supabase)' || true)"
  if [[ -n "$ctn_lines" ]]; then printf '  %s\n' "$ctn_lines"; else log "  (无)"; fi

  log "--- 命名卷 supabase_* ---"
  local vol_lines
  vol_lines="$(docker volume ls -q --filter 'name=^supabase_' 2>/dev/null || true)"
  if [[ -n "$vol_lines" ]]; then printf '  %s\n' "$vol_lines"; else log "  (无)"; fi

  log "--- 网络 supabase_* ---"
  local net_lines
  net_lines="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^supabase_' || true)"
  if [[ -n "$net_lines" ]]; then printf '  %s\n' "$net_lines"; else log "  (无)"; fi

  log "--- 关键目录 ---"
  for p in \
      "$SUPABASE_PROJECT_DIR/volumes/db/data" \
      "$SUPABASE_PROJECT_DIR/volumes/storage" \
      "$SUPABASE_PROJECT_DIR/volumes/functions" \
      "$WEB_ROOT" ; do
    if [[ -e "$p" ]]; then
      printf '  %s  (%s)\n' "$p" "$(du -sh "$p" 2>/dev/null | awk '{print $1}')"
    else
      printf '  %s  (不存在)\n' "$p"
    fi
  done

  log "--- .env / 版本锁文件处理策略 ---"
  if [[ -f "$SUPABASE_PROJECT_DIR/.env" ]]; then
    if [[ "$WIPE_ENV" == "true" ]]; then
      log "  WILL DELETE $SUPABASE_PROJECT_DIR/.env (--wipe-env)"
    else
      log "  保留 $SUPABASE_PROJECT_DIR/.env（如需重新生成密钥请加 --wipe-env）"
    fi
  fi
  if [[ -f "$SUPABASE_PROJECT_DIR/.supabase-docker-ref" ]]; then
    local ref
    ref="$(tr -d '[:space:]' < "$SUPABASE_PROJECT_DIR/.supabase-docker-ref" 2>/dev/null || true)"
    if [[ "$WIPE_ENV" == "true" ]]; then
      log "  WILL DELETE .supabase-docker-ref (当前: $ref)"
    else
      log "  保留 .supabase-docker-ref (当前: $ref)；保证下次部署仍用同一 Supabase docker ref"
    fi
  fi

  log "--- 镜像处理 ---"
  if [[ "$PRUNE_IMAGES" == "true" ]]; then
    log "  WILL RUN docker image prune -a -f"
  else
    log "  保留镜像（如需释放磁盘加 --prune-images）"
  fi

  log "--- 不会动 ---"
  log "  /etc/nginx, /etc/letsencrypt, /root/capgos 仓库, compose/init SQL 模板"
}

confirm() {
  [[ "$ASSUME_YES" == "true" ]] && return 0
  [[ "$DRY_RUN" == "true" ]] && return 0
  printf '\n确认按以上计划清理？输入 YES 继续: '
  local ans
  read -r ans
  [[ "$ans" == "YES" ]] || { log "已取消。"; exit 1; }
}

# ============ 清理 ============

stop_compose() {
  if [[ -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" ]]; then
    log "docker compose down -v --remove-orphans"
    run "(cd '$SUPABASE_PROJECT_DIR' && docker compose down -v --remove-orphans)"
  fi
}

remove_residual_containers() {
  local ids
  ids="$(docker ps -aq --filter 'name=^supabase-' 2>/dev/null; docker ps -aq --filter 'name=^realtime-dev.supabase' 2>/dev/null)"
  ids="$(echo "$ids" | tr '\n' ' ' | xargs)"
  if [[ -n "$ids" ]]; then
    log "兜底删除残留容器: $ids"
    run "docker rm -f $ids"
  fi
}

remove_named_volumes() {
  local vols
  vols="$(docker volume ls -q --filter 'name=^supabase_' 2>/dev/null | tr '\n' ' ' | xargs)"
  if [[ -n "$vols" ]]; then
    log "删除残留命名卷: $vols"
    run "docker volume rm $vols" || warn "部分卷仍被占用，可重跑或手工排查"
  fi
}

remove_networks() {
  if docker network inspect supabase_default >/dev/null 2>&1; then
    log "删除网络 supabase_default"
    run "docker network rm supabase_default" || warn "网络仍被占用"
  fi
}

remove_bind_mounts() {
  local paths=(
    "$SUPABASE_PROJECT_DIR/volumes/db/data"
    "$SUPABASE_PROJECT_DIR/volumes/storage"
    "$SUPABASE_PROJECT_DIR/volumes/functions"
  )
  local p
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      log "rm -rf $p"
      run "rm -rf '$p'"
    fi
  done
}

remove_console_dist() {
  if [[ -e "$WEB_ROOT" ]]; then
    log "rm -rf $WEB_ROOT"
    run "rm -rf '$WEB_ROOT'"
  fi
}

handle_env_file() {
  if [[ "$WIPE_ENV" == "true" ]]; then
    if [[ -f "$SUPABASE_PROJECT_DIR/.env" ]]; then
      log "删除 $SUPABASE_PROJECT_DIR/.env（密钥将被重生成）"
      run "rm -f '$SUPABASE_PROJECT_DIR/.env'"
    fi
    if [[ -f "$SUPABASE_PROJECT_DIR/.env.old" ]]; then
      run "rm -f '$SUPABASE_PROJECT_DIR/.env.old'"
    fi
    # 仅在 --wipe-env 时一起清掉版本锁记录；正常清理保留它，重建仍指向同一 ref
    if [[ -f "$SUPABASE_PROJECT_DIR/.supabase-docker-ref" ]]; then
      log "删除 $SUPABASE_PROJECT_DIR/.supabase-docker-ref（下次部署按 SUPABASE_DOCKER_REF 重抓）"
      run "rm -f '$SUPABASE_PROJECT_DIR/.supabase-docker-ref'"
    fi
  fi
}

prune_images_if_requested() {
  if [[ "$PRUNE_IMAGES" == "true" ]]; then
    log "docker image prune -a -f"
    run "docker image prune -a -f"
  fi
}

verify() {
  log "--- 清理后核对 ---"
  local left_ctn left_vol left_net
  left_ctn="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(supabase-|realtime-dev.supabase)' || true)"
  left_vol="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^supabase_' || true)"
  left_net="$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -E '^supabase_' || true)"
  printf '  容器: %s\n' "${left_ctn:-无}"
  printf '  卷:   %s\n' "${left_vol:-无}"
  printf '  网络: %s\n' "${left_net:-无}"
  for p in \
      "$SUPABASE_PROJECT_DIR/volumes/db/data" \
      "$SUPABASE_PROJECT_DIR/volumes/storage" \
      "$SUPABASE_PROJECT_DIR/volumes/functions" \
      "$WEB_ROOT" ; do
    if [[ -e "$p" ]]; then
      printf '  %s 仍存在\n' "$p"
    else
      printf '  %s OK\n' "$p"
    fi
  done
}

main() {
  command -v docker >/dev/null || { echo "缺少 docker"; exit 1; }
  discover
  confirm
  stop_compose
  remove_residual_containers
  remove_named_volumes
  remove_networks
  remove_bind_mounts
  remove_console_dist
  handle_env_file
  prune_images_if_requested
  verify
  log "完成。重新部署: bash \"\$CAPGO_REPO/scripts/deploy-self-hosted.sh\""
}

main "$@"
