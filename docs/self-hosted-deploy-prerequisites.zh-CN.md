# 自托管一键部署：前置条件与手工步骤

本文说明：**在运行 `scripts/deploy-self-hosted.sh` 之前和之后，你必须自己完成哪些事**。  
一键脚本只负责 Docker、数据库迁移、Functions 同步、前端构建等；**不会**替你买域名、配 Nginx、申请证书。


| 文档                      | 路径                                                                               |
| ----------------------- | -------------------------------------------------------------------------------- |
| 全栈部署指南（权威、含 Nginx 完整示例） | `[/root/SELF_HOSTED_FULL_STACK.zh-CN.md](/root/SELF_HOSTED_FULL_STACK.zh-CN.md)` |
| 一键部署脚本                  | `[scripts/deploy-self-hosted.sh](../scripts/deploy-self-hosted.sh)`              |
| 部署索引                    | `[self-hosted-deploy-index.md](self-hosted-deploy-index.md)`                     |
| **组件 / 镜像版本锁定**         | `[self-hosted-version-pins.zh-CN.md](self-hosted-version-pins.zh-CN.md)`         |
| 踩坑记录                    | `[issues/](issues/)`                                                             |


---

## 开始之前：你需要准备什么？

用一句话概括：**两台「门面」+ 一台能跑 Docker 的服务器**。


| 你要准备的                    | 举例                     | 谁访问                                             |
| ------------------------ | ---------------------- | ----------------------------------------------- |
| **控制台域名**                | `capgo.example.com`    | 浏览器打开 Capgo 管理后台                                |
| **API 域名**               | `supa.example.com`     | 浏览器、手机 App、Capgo CLI 调接口                        |
| **服务器**                  | 一台 Linux VPS，公网 IP     | 上面跑 Docker + Nginx                              |
| **自托管 Supabase（Docker）** | 官方 Docker 模板（默认目录见 §0） | Auth、PostgreSQL、Kong、Storage、Edge Functions 运行时 |


流量大致如下（便于理解后面 Nginx 为什么要配两个站点）：

```text
用户浏览器 ──HTTPS──► Nginx ──► /var/www/capgo/dist     （控制台静态页）
用户浏览器 ──HTTPS──► Nginx ──► 127.0.0.1:8000 (Kong)  （Auth / REST / Functions / Storage）
Capgo CLI  ──HTTPS──► 同上 API 域名
```

**推荐顺序**：自托管 Supabase（Docker，§0）→ 装软件 → 域名解析 → 证书 + Nginx → 写好 Supabase `.env`（§6）→ 再跑一键脚本 → 最后按清单验收。

---

## 0. 自托管 Supabase（Docker）（第一次部署必做）

### 0.1 为什么需要

Capgo 自托管**依赖一个已在运行（或至少已按官方模板就绪）的自托管 Supabase（Docker 版）**：PostgreSQL、GoTrue Auth、Kong 网关、Storage、Edge Functions 等均在该栈内。  
一键脚本 `deploy-self-hosted.sh` **不会**从零替你完成 Supabase 的安装与运维培训；它假定你在 `SUPABASE_PROJECT_DIR` 下已有 **Supabase 官方 Docker 自托管模板** 的 clone。

### 0.2 怎么做

1. 按 Supabase 官方文档完成 Docker 自托管安装与首次启动：
  [Installing Supabase（Self-Hosting with Docker）](https://supabase.com/docs/guides/self-hosting/docker#installing-supabase)
2. 将项目目录与脚本对齐（可 export，默认如下）：

```bash
export SUPABASE_PROJECT_DIR=/root/supabase-project
```

该目录应包含官方模板中的 `**docker-compose.yml**`、`**volumes/**`、`**.env.example**`（以及后续生成的 `.env`）。若你尚未 clone，请先按上述官方文档操作，**不要**在未读文档的情况下仅依赖脚本自动拉取。

> **与脚本的关系**：若 `SUPABASE_PROJECT_DIR` 里还没有 `docker-compose.yml`，`deploy-self-hosted.sh` 会尝试 `git clone` 官方仓库的 `docker/` 子目录到该路径。
>
> **版本锁定**：`deploy-self-hosted.sh` 默认已 pin `SUPABASE_DOCKER_REF` / `CAPGO_REF`（与 [self-hosted-version-pins.zh-CN.md §2.0](self-hosted-version-pins.zh-CN.md#20-上游-commit-锁定强烈建议生产填具体-sha) 一致）。跟上游 Supabase 最新可 `export SUPABASE_DOCKER_REF=master`；跟 Capgo `main` 最新可 `export CAPGO_REF=main`。脚本会把实际 Supabase SHA 写到 `$SUPABASE_PROJECT_DIR/.supabase-docker-ref`。密钥与域名相关变量见 **§6**。

### 0.3 如何验证

```bash
test -f "$SUPABASE_PROJECT_DIR/docker-compose.yml" && test -f "$SUPABASE_PROJECT_DIR/.env.example"
cd "$SUPABASE_PROJECT_DIR" && docker compose ps
# 期望：db、kong、auth 等核心服务为 running（或你尚未 docker compose up 时，至少目录结构与官方模板一致）
```

---

## 1. 脚本会自动做什么（对照）

便于区分「不用管」和「必须自己做」：


| 脚本会做                                 | 脚本不会做                |
| ------------------------------------ | -------------------- |
| Docker 起 Supabase、打 compose 补丁       | 域名购买、DNS 解析          |
| 跑 Capgo 数据库迁移                        | Nginx 站点配置、HTTPS 证书  |
| 建 Storage 三桶、写 Vault（密钥正确时）          | 防火墙 / 安全组规则          |
| 同步 Edge Functions（含 `translation`）   | 发邮件（SMTP / Bento）    |
| `bun build` 并把 `dist/` 拷到 `WEB_ROOT` | 完整业务验收、CLI 上传 bundle |


默认还会执行（可用环境变量关闭）：

- `RUN_BOOTSTRAP_PLANS=true`：写入套餐表，否则**无法创建组织**
- `RUN_BOOTSTRAP_CLI_ANON_GRANT=true`：否则 `**capgo login` / `bundle upload` 会报 RPC 42501**（见 issues/008）
- 若设置 `INIT_ADMIN_PASSWORD`：创建平台管理员（默认邮箱 `admin@local.com`）

---

## 2. 服务器与基础软件（第一次部署必做）

### 2.1 为什么需要

脚本会调用 `docker`、`bun`、`nginx`、`python3`、`rsync`。缺任何一个，脚本开头就会报错退出。

### 2.2 怎么做

在 **Debian / Ubuntu** 上示例（其他发行版请换对应包名）：

```bash
# Docker（按官方文档安装 Engine + Compose 插件）
docker --version
docker compose version

# Bun（构建控制台）
curl -fsSL https://bun.sh/install | bash
source ~/.bashrc   # 或重新登录
bun --version

# Nginx（只做反向代理，脚本不会替你写配置）
sudo apt update && sudo apt install -y nginx

# 其余脚本会检查
python3 --version
rsync --version
```

### 2.3 防火墙建议


| 端口             | 建议           | 原因                            |
| -------------- | ------------ | ----------------------------- |
| **443**        | 对公网开放        | 用户访问控制台和 API                  |
| **22**         | 仅你的 IP 或 VPN | SSH 管理                        |
| **8000**（Kong） | **不要**对公网开放  | 只给本机 Nginx 用 `127.0.0.1:8000` |


检查 Kong 是否只监听本机（部署 Supabase 后）：

```bash
ss -tlnp | grep 8000
# 期望看到 127.0.0.1:8000，而不是 0.0.0.0:8000 对公网暴露
```

### 2.4 如何确认

```bash
docker compose version && bun --version && nginx -v && python3 --version
```

---

## 3. 域名与 DNS（第一次部署必做）

### 3.1 为什么需要

- 控制台和 API **必须是浏览器/CLI 能访问的 HTTPS 域名**，不能只用 IP（Auth 回调、Cookie、CORS 都依赖域名）。
- `.env` 里的 `SITE_URL`、`SUPABASE_PUBLIC_URL` 必须和真实域名一致，否则登录跳转会错。

### 3.2 需要几条记录？

至少 **2 个子域名**，都指向**同一台服务器公网 IP**：


| 记录类型      | 名称      | 值          | 用途                             |
| --------- | ------- | ---------- | ------------------------------ |
| A（或 AAAA） | `capgo` | `你的服务器 IP` | 控制台 → 对应 `capgo.example.com`   |
| A（或 AAAA） | `supa`  | `同上`       | API 网关 → 对应 `supa.example.com` |


在域名服务商或 Cloudflare 里添加后，等待生效（通常几分钟到几小时）。

### 3.3 如何确认 DNS 已生效

```bash
dig +short capgo.example.com
dig +short supa.example.com
# 两条都应返回你的服务器 IP
```

### 3.4 若使用 Cloudflare 橙云代理

- 源站证书可以是 **自签名** 或 Let's Encrypt；Cloudflare 到用户仍是 HTTPS。
- SSL/TLS 模式建议选 **「完全 (Full)」**，**不要**选「完全（严格）」除非源站已是受信任证书。
- 详见 [issues/005](issues/005-宿主机Nginx无法解析Studio容器名.md)。

### 3.5 与脚本的关系

脚本只会往 Supabase `.env` **追加**一行（若不存在）：

```bash
FUNCTIONS_PUBLIC_API_HOSTNAME=supa.example.com
```

**不会**替你注册域名；域名必须在你跑脚本之前就解析好。

---

## 4. HTTPS 证书（第一次部署必做）

### 4.1 为什么需要

- 现代浏览器对非 HTTPS 站点限制很多；Capgo 控制台和 Supabase Auth **强烈依赖 HTTPS**。
- 脚本里的 `USE_LETSENCRYPT` **目前没有实现**，不会自动跑 `certbot`。

### 4.2 推荐做法：Let's Encrypt + Nginx

在 **DNS 已生效**、**80/443 已指向本机** 后：

```bash
sudo apt install -y certbot python3-certbot-nginx

# 把域名换成你的；可先只申请 API 域名，或两个一起
sudo certbot --nginx -d supa.example.com -d capgo.example.com
```

按提示选择「重定向 HTTP 到 HTTPS」。证书会自动续期（`certbot` 定时任务）。

### 4.3 仅内网联调（不推荐生产）

可临时用自签证书（snakeoil）或 Cloudflare「灵活/完全」+ 自签源站。浏览器可能告警，需手动信任。

### 4.4 如何确认

```bash
curl -sI https://supa.example.com | head -1
curl -sI https://capgo.example.com | head -1
# 期望 HTTP/2 200 或 301/302，且无证书错误（curl -v 可看证书链）
```

---

## 5. Nginx 反向代理（第一次部署必做，最重要）

### 5.1 为什么需要

- Docker 里的 Kong 监听 `127.0.0.1:8000`，**公网不能直接访问**。
- 构建好的控制台在 `/var/www/capgo/dist`，也需要 Nginx 提供 HTTPS 和 SPA 路由。
- 预签名上传、WebSocket、CORS 都依赖正确的 **转发头**（`X-Forwarded-Host` 等）。

**脚本不会创建任何 Nginx 配置文件，也不会 `nginx -s reload`。**

### 5.2 要配几个站点？

**两个 `server { }` 块**（可以放在两个文件里）：


| 文件建议名        | `server_name`       | 作用                |
| ------------ | ------------------- | ----------------- |
| `capgo.conf` | `capgo.example.com` | 静态前端              |
| `supa.conf`  | `supa.example.com`  | 反代到 Kong + Studio |


下面用占位符 `capgo.example.com` / `supa.example.com`，请全部替换成你的域名。

---

### 5.3 控制台站点（`CONSOLE_DOMAIN`）

**目标**：用户访问 `https://capgo.example.com` 时，读到 `/var/www/capgo/dist` 里的 `index.html`，且前端路由（如 `/login`）不 404。

**最小配置要点**：

```nginx
server {
    listen 443 ssl http2;
    server_name capgo.example.com;

    # certbot 会自动填 ssl_certificate 路径，或你手动指定
    # ssl_certificate     /etc/letsencrypt/live/capgo.example.com/fullchain.pem;
    # ssl_certificate_key /etc/letsencrypt/live/capgo.example.com/privkey.pem;

    root /var/www/capgo/dist;   # 与脚本 WEB_ROOT 一致
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;   # SPA 必需
    }
}

server {
    listen 80;
    server_name capgo.example.com;
    return 301 https://$host$request_uri;
}
```

**检查**：

```bash
sudo nginx -t && sudo systemctl reload nginx
curl -sI -k https://capgo.example.com/ | head -5
# 跑完一键脚本后再测，应返回 200 且能打开登录页
```

---

### 5.4 API / Supabase 站点（`SUPABASE_DOMAIN`）

**目标**：把 `https://supa.example.com` 下的各类路径转到 Kong（`127.0.0.1:8000`）。


| 路径前缀                                                  | 转到                       | 说明                       |
| ----------------------------------------------------- | ------------------------ | ------------------------ |
| `/`                                                   | `http://127.0.0.1:54323` | Supabase Studio（管理界面，可选） |
| `/auth`、`/rest`、`/storage`、`/functions`、`/realtime` 等 | `http://127.0.0.1:8000`  | 经 Kong 进各服务              |


**重要**：

1. **不要**写 Docker 容器名（如 `http://studio:3000`），Nginx 在宿主机上解析不了，会 502。见 [issues/005](issues/005-宿主机Nginx无法解析Studio容器名.md)。
2. **必须**带转发头，否则预签名 URL 可能带 `:8000` 或 `http://`，CLI 上传失败。
3. **普通 API** 的 `location` 建议关闭缓冲，避免大 POST 卡住：

```nginx
proxy_buffering off;
proxy_request_buffering off;
```

1. `**/realtime/**` 单独一个 `location`，加 WebSocket 头（`Upgrade`、`Connection`）。
2. **不要**在 `location` 里用 `if` 处理 OPTIONS，交给 Kong 的 CORS。

**转发头模板**（每个 `proxy_pass` 到 Kong 的 location 都应包含）：

```nginx
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Port  443;
```

**完整可复制示例**见全栈文档 **[§4 反向代理](/root/SELF_HOSTED_FULL_STACK.zh-CN.md#4-反向代理nginx与常见故障)** 与 **[附录 A.3](/root/SELF_HOSTED_FULL_STACK.zh-CN.md#附录-a示例配置脱敏)**。本机已落地的两个站点配置参考 **§5.6**。

> **多域名场景**：若客户端 OTA 走独立域名（external bundle），见 `[self-hosted-updater-domain.zh-CN.md](self-hosted-updater-domain.zh-CN.md)`，本文 §5 仍是基础。

**检查**：

```bash
# Kong 健康（在服务器上）
curl -s http://127.0.0.1:8000/functions/v1/ok

# 经 Nginx + HTTPS（替换域名）
curl -sk https://supa.example.com/functions/v1/ok
# 期望 JSON 里含 "status":"ok"
```

---

### 5.5 本机参考配置（直接复制改域名 / 证书）

> 这两份是当前部署机上**已验证**可用的站点配置。占位说明：把 `capgo.example.com` / `supa.example.com` 换成你的域名；snakeoil 证书路径换成 certbot 自动写入的 Let's Encrypt 证书（`/etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem`）。

#### 5.5.1 `capgo.<domain>.conf`（控制台静态站点）

放置于 `/etc/nginx/sites-available/capgo.<domain>`，软链到 `sites-enabled/`，`nginx -t && systemctl reload nginx`。

```nginx
server {
    listen 80;
    server_name capgo.example.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name capgo.example.com;

    # 临时自签证书；生产请换成 Let's Encrypt
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    client_max_body_size 50m;

    root /var/www/capgo/dist;     # 与一键脚本 WEB_ROOT 一致
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;   # SPA 必需
    }
}
```

#### 5.5.2 `supa.<domain>.conf`（Supabase API 网关 + Studio）

```nginx
server {
    listen 80;
    server_name supa.example.com;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name supa.example.com;

    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    client_max_body_size 100m;
    proxy_http_version 1.1;

    # 通用转发头：缺 X-Forwarded-Host/Port，预签名 URL 会带 :8000，CLI 上传失败
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host  $host;
    proxy_set_header X-Forwarded-Port  $server_port;

    # Docker 内部 DNS，允许容器名解析（仅本机网络）
    resolver 127.0.0.11 valid=30s;

    # Supabase Studio：compose 映射 127.0.0.1:54323；勿写容器名（见 issues/005）
    location / {
        proxy_pass http://127.0.0.1:54323;
        proxy_redirect off;
    }

    # Realtime（WebSocket）：仅本 location 加 Upgrade/Connection；勿在 REST/Functions 上加
    location ~ ^/realtime/v1/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_redirect off;
    }

    # 普通 HTTP API：REST / Auth / Storage / Functions / GraphQL
    # 关闭缓冲：HTTP/2 客户端 + 上游 HTTP/1.1 时大 POST 会卡住直到 502
    location ~ ^/(rest|auth|storage|functions|graphql)/v1(/|$) {
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_pass http://127.0.0.1:8000;
        proxy_redirect off;
    }

    location /.well-known/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_redirect off;
    }

    location /sso/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_redirect off;
    }

    # Supabase MCP（如 Cursor 等 MCP 客户端访问 /mcp?features=…）
    location /mcp {
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_pass http://127.0.0.1:8000;
        proxy_redirect off;
    }
}
```

> 多域名（客户端 OTA 独立域名）的额外 `update.<domain>.conf` 见 `[self-hosted-updater-domain.zh-CN.md](self-hosted-updater-domain.zh-CN.md)` §3。

---

### 5.7 跨域 CORS（控制台与 API 不同域名时必查）

控制台在 `capgo.example.com`，接口在 `supa.example.com`，属于**跨域**。若登录或 API 报 CORS 错误：

- 在 Supabase 项目的 `volumes/api/kong.yml`（或你使用的网关配置）里，允许控制台来源，例如：  
`https://capgo.example.com`
- 改完后重启 Kong：`docker compose restart kong`

全栈说明见 **§3.4**。

---

## 6. Supabase `.env` 密钥（第一次部署必做）

### 6.1 为什么需要

- 一键脚本第一次发现没有 `.env` 时，会复制 `example` 然后 **直接退出**，提示你先配密钥。
- 弱密钥或占位符 `CHANGE_ME` 会导致：数据库被轻易攻破、JWT 伪造、队列任务不调 Edge Function。

### 6.2 项目目录

默认：

```bash
export SUPABASE_PROJECT_DIR=/root/supabase-project
```

目录内应有官方 Docker 模板的 `**docker-compose.yml**`、`**volumes/**`、`**.env.example**`（安装步骤见 **§0** 与[官方 Installing Supabase 文档](https://supabase.com/docs/guides/self-hosting/docker#installing-supabase)）。若目录里没有 `docker-compose.yml`，脚本会自动 `git clone` 官方 Supabase 的 `docker/` 子目录到该路径——仍建议你先按 §0 完成自托管 Supabase，再配置本节密钥。

### 6.3 第一次生成密钥（推荐流程）

```bash
cd "$SUPABASE_PROJECT_DIR"
cp .env.example .env    # 若脚本已复制可跳过

# 官方脚本：生成 POSTGRES_PASSWORD、JWT、ANON_KEY、SERVICE_ROLE_KEY 等
sh ./utils/generate-keys.sh
sh ./utils/add-new-auth-keys.sh 2>/dev/null || true
```

再用编辑器打开 `.env`，**至少**核对下表（把 `example.com` 换成你的域名）：


| 变量                    | 应填什么                             | 填错会怎样                           |
| --------------------- | -------------------------------- | ------------------------------- |
| `POSTGRES_PASSWORD`   | 强随机密码                            | 数据库不安全                          |
| `JWT_SECRET`          | 脚本生成的长串                          | 无法签发合法 JWT                      |
| `ANON_KEY`            | 脚本生成的 JWT                        | 前端/CLI 无法调 API                  |
| `SERVICE_ROLE_KEY`    | 脚本生成的 JWT                        | 管理员脚本、Auth Admin API 失败         |
| `SUPABASE_PUBLIC_URL` | `https://supa.example.com`       | Auth、Storage 公网地址错误             |
| `API_EXTERNAL_URL`    | 通常与上一项相同                         | 部分客户端连错地址                       |
| `SITE_URL`            | `https://capgo.example.com`      | **登录后跳转、邮件链接错误**                |
| `KONG_HTTP_PORT`      | `8000`（默认）                       | 与 Nginx `proxy_pass` 端口不一致会 502 |
| `CAPGO_API_SECRET`    | 自己生成一长串随机值（勿用 `CHANGE_ME`）       | Vault 不写 `apikey`，后台队列不工作       |
| `REGION`              | 如 `stub`（与 compose 里 storage 一致） | CLI 上传 bundle 可能 403            |


生成 `CAPGO_API_SECRET` 示例：

```bash
openssl rand -hex 32
# 写入 .env：CAPGO_API_SECRET=上面输出的字符串
```

### 6.4 脚本还会自动补什么？

若 `.env` 里没有，脚本会**追加**（不覆盖已有值）：

```bash
FUNCTIONS_PUBLIC_API_HOSTNAME=supa.example.com   # 与 SUPABASE 域名主机名一致，无 https://
```

`KONG_PORT_MAPS`、`functions` 的 `S3_*` 等由 `patch-supabase-compose.py` 写入 `docker-compose.yml`，无需手改 compose，但 **Nginx 转发头仍须配对**。

### 6.5 如何确认

```bash
grep -E '^(SITE_URL|SUPABASE_PUBLIC_URL|CAPGO_API_SECRET|ANON_KEY)=' "$SUPABASE_PROJECT_DIR/.env"
# CAPGO_API_SECRET 不应仍是 CHANGE_ME
```

---

## 7. Edge Functions 与邮件（按需配置）

### 7.1 脚本已替你做的

- 把 Capgo 的 `supabase/functions/` 同步到 `volumes/functions/`
- 创建 `volumes/functions/.env`（若不存在），并写入 `SUPABASE_REPLICATE_URL=https://supa.example.com`
- 构建控制台时关闭 Turnstile：`CAPTCHA_KEY=`、`VITE_CAPTCHA_KEY=`

### 7.2 你必须核对的两处密钥一致性


| 位置                       | 变量名                | 必须与谁一致                                                             |
| ------------------------ | ------------------ | ------------------------------------------------------------------ |
| Supabase 根目录 `.env`      | `CAPGO_API_SECRET` | ↓                                                                  |
| `volumes/functions/.env` | `API_SECRET`       | 同上                                                                 |
| Postgres Vault           | secret 名 `apikey`  | 同上（脚本在 `CAPGO_API_SECRET` 非 `CHANGE_ME` 时自动 `vault.create_secret`） |


若部署时 `CAPGO_API_SECRET` 还是 `CHANGE_ME`，脚本会**跳过** Vault，你需要改好 `.env` 后手动执行（全栈 **§5.4**）或重新跑 `db_post_steps` 相关 SQL。

**检查 Vault**（部署后）：

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
  "SELECT name FROM vault.secrets WHERE name IN ('db_url','apikey');"
```

### 7.3 邮件（可选，不配也能登录）


| 场景         | 配置位置                                 | 不配置的结果        |
| ---------- | ------------------------------------ | ------------- |
| 用户注册要收确认邮件 | Auth 服务 SMTP（`.env` 里 GoTrue 相关项）    | 注册卡在「等邮件」     |
| 内网快速联调     | `ENABLE_EMAIL_AUTOCONFIRM=true`      | 注册后自动确认（生产慎用） |
| 组织邀请成员     | `volumes/functions/.env` 里 `BENTO_*` | 邀请发不出去        |


自托管**中文控制台**不依赖 Cloudflare AI；`translation` 由仓库内桩函数提供（见 issues/006）。

---

## 8. 数据库与管理员（跑脚本时注意环境变量）

### 8.1 默认不会导入测试数据

`RUN_DB_SEED=false`（默认）**不会**执行 `seed.sql`，因此：

- 没有 `test@capgo.app` 等测试账号
- **不会**清空你已有的 `auth.users`

### 8.2 脚本会自动补的业务数据


| 内容         | 环境变量                                    | 不执行时的现象                                                              |
| ---------- | --------------------------------------- | -------------------------------------------------------------------- |
| 套餐 `plans` | `RUN_BOOTSTRAP_PLANS=true`（默认）          | 创建组织报 `cannot_get_plan`                                              |
| CLI 权限 RPC | `RUN_BOOTSTRAP_CLI_ANON_GRANT=true`（默认） | `login` 报 Invalid API key；`upload` 报 `get_org_perm_for_apikey` 42501 |


### 8.3 平台管理员（建议首次就设）

在跑脚本**之前**导出密码（不要写进 git）：

```bash
export INIT_ADMIN_EMAIL=admin@local.com
export INIT_ADMIN_PASSWORD='你的强密码'
```

脚本会调用 `init-self-hosted-admin.sh`：创建 Auth 用户、`public.users` 行、Vault `admin_users`。

若不设 `INIT_ADMIN_PASSWORD`，脚本会跳过，你需要自己在控制台注册（且要处理邮件确认问题）。

---

## 8.5 版本锁定（升级前建议阅读）

单独 `docker compose pull` 或 `git pull` 可能只升级某一个组件，导致预签名上传、CLI 登录、迁移与 Edge 不兼容。

- 已验证版本表：**[self-hosted-version-pins.zh-CN.md](self-hosted-version-pins.zh-CN.md)**
- 在服务器上刷新快照：

```bash
bash "$CAPGO_REPO/scripts/collect-self-hosted-versions.sh"
```

---

## 9. 跑一键脚本

### 9.1 推荐命令

```bash
# === 路径 ===
# Capgo 仓库根（含 scripts/、supabase/、src/ 等）
export CAPGO_REPO=/root/capgos/capgo
# Supabase 官方 Docker 模板所在目录（含 docker-compose.yml、volumes/、.env）
# 见 §0；脚本会在这里跑 patch / compose up / 写 .env
export SUPABASE_PROJECT_DIR=/root/supabase-project

# === 公网域名（必须先解析 + 证书就绪，见 §3 §4 §5）===
# 控制台域名：浏览器访问，对应 /var/www/capgo/dist
export CONSOLE_DOMAIN=capgo.example.com
# Supabase API 域名：浏览器 + CLI 调 Auth/REST/Storage/Functions，反代 Kong
export SUPABASE_DOMAIN=supa.example.com

# === 静态产物输出 ===
# 控制台 build 后的 dist 同步路径；必须与 Nginx 控制台站点的 root 一致（§5.5.1）
export WEB_ROOT=/var/www/capgo/dist

# === 平台管理员（可选但强烈建议）===
# 设置后脚本会创建 Auth 用户 + public.users 行 + Vault admin_users
export INIT_ADMIN_EMAIL=admin@local.com
export INIT_ADMIN_PASSWORD='你的强密码'   # 勿提交 git；首次部署后立刻改

# === 版本锁定（脚本内已有默认 pin，与 version-pins §2.0 一致；以下为可选覆盖）===
# 跟踪上游 Supabase 最新：export SUPABASE_DOCKER_REF=master
# 跟 Capgo main 分支最新：export CAPGO_REF=main
# 已部署的 Supabase SHA 会落盘到 $SUPABASE_PROJECT_DIR/.supabase-docker-ref，cleanup 默认保留

# === 代码同步策略 ===
# true = 跳过 `git fetch && git checkout $CAPGO_REF && git pull`；
# 当 Capgo 仓库里有本地未推送的改动（例如你刚改了 migrations 或 functions）时务必开启
export SKIP_GIT_PULL=true

bash "$CAPGO_REPO/scripts/deploy-self-hosted.sh"
```

> **失败时一键清理**：迁移卡住、Vault 写错、卷数据脏了时，先跑清理脚本回到「干净状态」，再重跑部署，避免在半套库上反复修补：
>
> ```bash
> # 默认保留 .env / nginx / 证书 / 仓库；只清容器 / 卷 / db data / functions 副本 / dist
> bash "$CAPGO_REPO/scripts/cleanup-self-hosted.sh" --yes
>
> # 连 .env 也一起清（之后由部署脚本重新 generate-keys）
> bash "$CAPGO_REPO/scripts/cleanup-self-hosted.sh" --yes --wipe-env
>
> # 看一眼会做什么、不动手
> bash "$CAPGO_REPO/scripts/cleanup-self-hosted.sh" --dry-run
>
> # 再次部署
> bash "$CAPGO_REPO/scripts/deploy-self-hosted.sh"
> ```

### 9.2 脚本常用环境变量速查


| 变量                             | 默认      | 说明                                                                 |
| ------------------------------ | ------- | ------------------------------------------------------------------ |
| `RUN_DB_SEED`                  | `false` | `true` = 跑完整 seed（**会清测试用户数据，生产慎用**）                               |
| `RUN_BOOTSTRAP_PLANS`          | `true`  | 写入 `plans` 表                                                       |
| `RUN_BOOTSTRAP_CLI_ANON_GRANT` | `true`  | 允许 CLI `login` / `upload`（`get_user_id`、`get_org_perm_for_apikey`） |
| `INIT_ADMIN_ENABLED`           | `true`  | 配合 `INIT_ADMIN_PASSWORD` 创建管理员                                     |
| `POSTGRES_DIRECT_PORT`         | `54322` | 宿主机直连 Postgres 端口（`${POSTGRES_PORT}` 是 Supavisor 池）                |
| `SUPABASE_DOCKER_REF`          | `09bbb7c323b017cda034ab307fe83edf2cbd0619` | Supabase `docker/` 的 commit；`master` 可跟踪上游；与 version-pins §2.0 同步 bump |
| `CAPGO_REF`                    | `955814dd39c66090958f41208a75a37c52f93e3c` | Capgo checkout 的 ref；`main` 可跟分支最新；与 version-pins 元数据同步 bump        |
| `USE_LETSENCRYPT`              | `false` | **未实现**，勿依赖                                                        |


### 9.3 若你改过本地 Capgo 代码

默认会 `git pull origin main`。仅本地有修改、未推送时务必：

```bash
export SKIP_GIT_PULL=true
```

### 9.4 一键脚本失败排查与清理

| 现象                                                                | 一般原因                                          | 处置                                                                                                                  |
| ----------------------------------------------------------------- | --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `Tenant or user not found`                                        | `db push` 连到 Supavisor，不是真实 Postgres          | 确认补丁脚本注入了 `127.0.0.1:54322`，或设 `POSTGRES_DIRECT_PORT`                                                              |
| `cannot drop extension uuid-ossp because other objects depend on it` | `storage.objects` 仍依赖；本仓库已不在迁移中 DROP，看是否拉了最新 | `git pull` Capgo 仓库后再跑 |
| `must be owner of table objects` | 迁移用 `postgres` 角色无法 `ALTER storage.*` | 该 ALTER 已从迁移移除；同上 `git pull` |
| `permission denied for function get_user_id`                      | 未跑 CLI anon bootstrap                         | 设 `RUN_BOOTSTRAP_CLI_ANON_GRANT=true`（默认 true）                                                                       |
| 半套库 / 卷数据脏 / 想推倒重来                                                 | 之前部署半途失败                                      | `bash "$CAPGO_REPO/scripts/cleanup-self-hosted.sh" --yes` 后重跑 deploy；密钥也要重生成时加 `--wipe-env`                          |

---

## 10. 部署后验收（建议逐项打勾）

### 10.1 API 与控制台基础

```bash
SUPA=supa.example.com
CON=capgo.example.com

# 1) Edge 健康
curl -sk "https://${SUPA}/functions/v1/ok" | jq .

# 2) 翻译（中文控制台依赖，避免白屏）
curl -sk -X POST "https://${SUPA}/functions/v1/translation/messages" \
  -H "Content-Type: application/json" \
  -d '{"targetLanguage":"zh-cn"}' | jq .status
# 期望: "ready"

# 3) 远程配置不能是 http://kong:8000
curl -sk "https://${SUPA}/functions/v1/private/config" | jq .supaHost
# 期望: "https://supa.example.com"

# 4) 控制台能打开
curl -sI -k "https://${CON}/" | head -3
```

### 10.2 浏览器里人工测

- 打开 `https://capgo.example.com/login`，用 `INIT_ADMIN_EMAIL` / 密码登录
- 创建组织（名称 ≥ 3 个字符）
- 创建应用（侧载选「否」）
- 若仍白屏：硬刷新 / 清站点数据（旧 Service Worker，见 issues/006）

### 10.3 Capgo CLI（在本机 App 工程目录）

`capacitor.config` 中需有（`ANON_KEY` 与服务器 `.env` 一致）：

```json
"CapacitorUpdater": {
  "localSupa": "https://supa.example.com",
  "localSupaAnon": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...."
}
```

```bash
npx @capgo/cli@latest login <控制台里复制的 API Key>
npx @capgo/cli@latest app list
# bundle 上传见全栈 §12.1
```

登录失败见 [issues/008](issues/008-CLI-login-get_user_id权限拒绝.md)。

### 10.4 数据库快速核对

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c "SELECT name, mau FROM public.plans ORDER BY mau;"
docker exec -i supabase-db psql -U postgres -d postgres -c \
  "SELECT has_function_privilege('anon', 'public.get_user_id(text)', 'EXECUTE');"
docker exec -i supabase-db psql -U postgres -d postgres -c \
  "SELECT has_function_privilege('anon', 'public.get_org_perm_for_apikey(text,text)', 'EXECUTE');"
```

---

## 11. 推荐执行顺序（ checklist ）

可复制打印，按顺序打勾：

```text
□ 自托管 Supabase（Docker）：SUPABASE_PROJECT_DIR 为官方模板（§0），compose 可 up / ps 正常
□ 服务器已装 Docker、Bun、Nginx、python3、rsync
□ 防火墙：443 开放，8000 不对公网
□ DNS：capgo.* 与 supa.* 指向本机 IP（dig 已验证）
□ HTTPS：certbot 或等价证书，nginx -t 通过
□ Nginx：控制台 root = WEB_ROOT；API 反代 127.0.0.1:8000 + 转发头
□ Supabase .env：密钥已生成，SITE_URL / SUPABASE_PUBLIC_URL / CAPGO_API_SECRET 正确
□ 已 export INIT_ADMIN_PASSWORD（可选但建议）
□ 已 export CONSOLE_DOMAIN / SUPABASE_DOMAIN / CAPGO_REPO
□ 运行 deploy-self-hosted.sh
□ 失败时跑 cleanup-self-hosted.sh（必要时 --wipe-env）后再重跑
□ §10 验收：ok、translation、private/config、登录、建组织
□ （可选）CLI login + bundle upload §12.1
```

---

## 12. 与 issues 的对应关系


| issues  | 主题                       | 你要手工做的                                                                     |
| ------- | ------------------------ | -------------------------------------------------------------------------- |
| 001     | psql 迁移单事务               | 一般不用；脚本已处理                                                                 |
| 002     | CONCURRENTLY             | 一般不用；脚本已处理                                                                 |
| 003–004 | Functions 路由 / deno      | 一般不用；脚本已同步                                                                 |
| 005     | Studio 502               | **Nginx 用 127.0.0.1:54323**，勿写容器名                                          |
| 006     | 控制台白屏                    | 确认 translation；必要时硬刷新                                                      |
| 007     | 无法建组织                    | 确认 `RUN_BOOTSTRAP_PLANS` 或手跑 bootstrap SQL                                 |
| 008     | CLI login / upload 42501 | 确认 `RUN_BOOTSTRAP_CLI_ANON_GRANT` 或手跑 `self-hosted-bootstrap-cli-anon.sql` |
| 009     | 其他 CLI RPC 42501         | 对照表 [issues/009](issues/009-CLI-anon-RPC权限对照表.md)；bootstrap 已批量 GRANT      |


---

## 13. 小结


| 类别                                         | 谁来做                          |
| ------------------------------------------ | ---------------------------- |
| Docker、迁移、Functions、前端 build、bootstrap SQL | **一键脚本**                     |
| 域名、DNS、证书、Nginx、`.env` 生产密钥、邮件             | **你（本文 §2–§7）**              |
| 登录、建组织、CLI 上传                              | **你（本文 §10 + 全栈 §11、§12.1）** |


完成 **§11 checklist** 后再跑脚本，可避免「接口 200 但控制台白屏 / 无法建组织 / CLI 登录失败」等常见问题。