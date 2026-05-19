#!/usr/bin/env python3
"""Patch official Supabase docker-compose.yml for Capgo self-hosting."""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

DEFAULT_SUPABASE_PROJECT_DIR = "/root/supabase-project"


def resolve_compose_path(project_dir: Path) -> Path:
    return project_dir / "docker-compose.yml"


def patch_compose(text: str) -> str:
    miss: list[str] = []

    kong_patch = """      KONG_PROXY_ACCESS_LOG: /dev/stdout combined
      #KONG_SSL_CERT: /home/kong/server.crt"""
    kong_repl = """      KONG_PROXY_ACCESS_LOG: /dev/stdout combined
      KONG_PORT_MAPS: "443:8000,443:8443"
      KONG_TRUSTED_IPS: "0.0.0.0/0,::/0"
      KONG_REAL_IP_HEADER: "X-Forwarded-For"
      #KONG_SSL_CERT: /home/kong/server.crt"""
    if "KONG_PORT_MAPS" not in text:
        new_text = text.replace(kong_patch, kong_repl, 1)
        if new_text == text:
            miss.append("kong KONG_PORT_MAPS / KONG_TRUSTED_IPS / KONG_REAL_IP_HEADER")
        text = new_text

    storage_patch = """      REQUEST_ALLOW_X_FORWARDED_PATH: "true"
      FILE_SIZE_LIMIT: 52428800"""
    storage_repl = """      REQUEST_ALLOW_X_FORWARDED_PATH: "true"
      S3_PROTOCOL_PREFIX: "/storage/v1"
      FILE_SIZE_LIMIT: 52428800"""
    if "S3_PROTOCOL_PREFIX" not in text:
        new_text = text.replace(storage_patch, storage_repl, 1)
        if new_text == text:
            miss.append("storage S3_PROTOCOL_PREFIX")
        text = new_text

    funcs_old = """  functions:
    container_name: supabase-edge-functions
    image: supabase/edge-runtime:v1.71.2
    restart: unless-stopped
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
      - deno-cache:/root/.cache/deno
    depends_on:
      kong:
        condition: service_healthy
    environment:"""

    funcs_new = """  functions:
    container_name: supabase-edge-functions
    image: supabase/edge-runtime:v1.71.2
    restart: unless-stopped
    volumes:
      - ./volumes/functions:/home/deno/functions:Z
      - deno-cache:/root/.cache/deno
    depends_on:
      kong:
        condition: service_healthy
    env_file:
      - ./volumes/functions/.env
    extra_hosts:
      - "${FUNCTIONS_PUBLIC_API_HOSTNAME}:host-gateway"
    environment:"""

    # 精确截取 supabase-edge-functions 服务定义块（避免 pg-functions:// 等子串误切）
    funcs_block = ""
    m_block = re.search(
        r"(?ms)^  functions:\n(?:.*?)(?=^  [A-Za-z_-]+:\n|\Z)",
        text,
    )
    if m_block:
        funcs_block = m_block.group(0)
    if "env_file:" not in funcs_block:
        new_text = text.replace(funcs_old, funcs_new, 1)
        if new_text == text:
            miss.append(
                "functions env_file / extra_hosts (检查 edge-runtime tag 是否与补丁的 v1.71.2 一致)"
            )
        text = new_text

    verify_patch = """      VERIFY_JWT: "${FUNCTIONS_VERIFY_JWT}"
    command:"""
    verify_repl = """      VERIFY_JWT: "${FUNCTIONS_VERIFY_JWT}"
      API_SECRET: ${CAPGO_API_SECRET}
      S3_ENDPOINT: kong:8000/storage/v1/s3
      S3_REGION: ${REGION}
      S3_SSL: "false"
      S3_ACCESS_KEY_ID: ${S3_PROTOCOL_ACCESS_KEY_ID}
      S3_SECRET_ACCESS_KEY: ${S3_PROTOCOL_ACCESS_KEY_SECRET}
      S3_BUCKET: capgo
    command:"""
    if "S3_ENDPOINT: kong" not in text:
        new_text = text.replace(verify_patch, verify_repl, 1)
        if new_text == text:
            miss.append("functions API_SECRET / S3_* (VERIFY_JWT 锚点未命中)")
        text = new_text

    if miss:
        print(
            "WARN: 以下补丁未命中（疑似上游 docker-compose.yml 结构变更，请检查 SUPABASE_DOCKER_REF）:\n  - "
            + "\n  - ".join(miss),
            file=sys.stderr,
        )

    # 官方模板：宿主机 ${POSTGRES_PORT} 映射的是 Supavisor（连接池），不是 Postgres。
    # 宿主机 supabase db push 若连 127.0.0.1:5432 会得到 FATAL: Tenant or user not found。
    # 为 db 容器增加仅本机绑定的直连端口，供迁移 CLI 使用（默认 54322）。
    if "127.0.0.1:54322:5432" not in text:
        m = re.search(
            r"(container_name: supabase-db\n"
            r"    image: supabase/postgres:[^\n]+\n"
            r"    restart: unless-stopped\n)"
            r"(    volumes:)",
            text,
        )
        if m:
            text = (
                text[: m.start(1)]
                + m.group(1)
                + "    ports:\n"
                + '      # Capgo: host -> real Postgres (avoid Supavisor on ${POSTGRES_PORT})\n'
                + '      - "127.0.0.1:54322:5432"\n'
                + m.group(2)
                + text[m.end(2) :]
            )
        else:
            print(
                "WARN: 未能在 docker-compose.yml 中为 supabase-db 注入 127.0.0.1:54322:5432；"
                "若 supabase db push 仍报 Tenant or user not found，请检查上游 compose 结构是否变更。",
                file=sys.stderr,
            )

    return text


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Patch Supabase docker-compose.yml for Capgo self-hosting."
    )
    parser.add_argument(
        "--project-dir",
        dest="project_dir",
        default=os.environ.get("SUPABASE_PROJECT_DIR", DEFAULT_SUPABASE_PROJECT_DIR),
        help=(
            "Supabase Docker project root (contains docker-compose.yml). "
            f"Default: env SUPABASE_PROJECT_DIR or {DEFAULT_SUPABASE_PROJECT_DIR}"
        ),
    )
    args = parser.parse_args()
    project_dir = Path(args.project_dir).expanduser().resolve()
    compose = resolve_compose_path(project_dir)

    if not compose.is_file():
        raise SystemExit(f"Compose file not found: {compose}")

    text = compose.read_text()
    compose.write_text(patch_compose(text))
    print("Patched", compose)


if __name__ == "__main__":
    main()
