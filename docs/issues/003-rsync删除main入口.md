# rsync --delete 覆盖掉 Supabase 官方 main worker

## 背景

阶段 4 将 Capgo `supabase/functions/` 同步到 `$SUPABASE_PROJECT_DIR/volumes/functions/`（全栈 **§7.1**）。

## 现象

`curl http://127.0.0.1:8000/functions/v1/ok` 返回 503，`supabase-edge-functions` 日志：

```
could not find an appropriate entrypoint
```

Compose 中 `--main-service /home/deno/functions/main` 指向的目录不存在。

## 根因

`rsync -a --delete` 删除了官方 Docker 模板自带的 `volumes/functions/main/`。Capgo 仓库函数树不含该路由 worker，仅含各子服务目录（`ok/`、`bundle/` 等）。

## 解决步骤

1. 从 [Supabase 官方模板](https://github.com/supabase/supabase/tree/master/docker/volumes/functions/main) 恢复 `main/index.ts`。
2. 按全栈 **§7.2** 将 `importMapPath` 设为 `/home/deno/functions/deno.capgo.json`。
3. 后续 rsync 应排除 `main/`，或在同步后由部署脚本重新写入 `main/index.ts`。

## 验证方式

```bash
curl -s http://127.0.0.1:8000/functions/v1/ok
```

应返回 JSON 而非 503。

## 关联文件

- `/root/supabase-project/volumes/functions/main/index.ts`
- 全栈文档 **§7.1**、**§7.2**
