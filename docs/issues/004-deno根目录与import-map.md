# 根目录 deno.json 导致 main worker 无法启动

## 背景

Edge Functions 使用 `edge-runtime` 的 `--main-service /home/deno/functions/main`（全栈 **§7.2**）。

## 现象

1. 容器反复重启：`failed to bootstrap runtime: No such file or directory`
2. 去掉根目录 `deno.json` 后 main 能启动，但子 worker 报 `hono/http-exception` 无法解析
3. 仅在 `ok/deno.json` 存在时 `/functions/v1/ok` 返回 `{"status":"ok"}`

## 根因

- `volumes/functions/deno.json`（自 Capgo rsync）在 **main worker 引导阶段**被 Edge Runtime 当作工作区 import map，npm/jsr 依赖在 bootstrap 时失败，错误信息表现为 OS error 2。
- `EdgeRuntime.userWorkers.create({ importMapPath })` 在本镜像版本下**未**可靠作用于子 worker；须在**各子服务目录**提供 `deno.json`（可 `ln -sf ../deno.capgo.json`）。

## 解决步骤

1. rsync 后删除 `volumes/functions/deno.json`，保留 `deno.capgo.json`。
2. 为每个含 `index.ts` 的一级函数目录创建：`ln -sf ../deno.capgo.json <dir>/deno.json`（跳过 `main/`、`_backend/`）。
3. 使用不依赖 `deno.land/x/jose` 的精简 `main/index.ts`（`FUNCTIONS_VERIFY_JWT=false` 时），或确保 main 目录不受根 import map 影响。

## 验证方式

```bash
curl -s http://127.0.0.1:8000/functions/v1/ok
```

## 关联文件

- `/root/supabase-project/volumes/functions/main/index.ts`
- `/root/supabase-project/volumes/functions/deno.capgo.json`
- 全栈文档 **§7.2**
