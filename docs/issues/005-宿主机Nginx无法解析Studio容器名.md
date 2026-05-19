# 宿主机 Nginx 无法通过 Docker DNS 访问 Studio

## 背景

`supa.example.com` 的 `location /` 需反代 Supabase Studio（全栈 **§4**、附录 A.3.2）。

## 现象

将 `proxy_pass` 设为 `http://supabase-studio:3000`（配合 `resolver 127.0.0.11`）时，HTTPS 访问根路径返回 **502**。`172.18.0.x` 写死则在容器重建后失效。

## 根因

Nginx 进程运行在**宿主机**上时，`127.0.0.11` 的 Docker 嵌入式 DNS **通常不可用**，无法解析 `supabase-studio` 服务名。

## 解决步骤

1. 增加 `docker-compose.override.yml`，将 Studio 映射到宿主机：
   ```yaml
   services:
     studio:
       ports:
         - "127.0.0.1:54323:3000"
   ```
2. Nginx 使用 `proxy_pass http://127.0.0.1:54323;`
3. `docker compose up -d studio && nginx -t && systemctl reload nginx`

## 验证方式

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1/ -H 'Host: supa.example.com'
```

期望 200 或 307（重定向），非 502。

## 关联文件

- `/root/supabase-project/docker-compose.override.yml`
- `/etc/nginx/sites-enabled/supa.example.com`
- 全栈文档 **§4**
