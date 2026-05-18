# CREATE INDEX CONCURRENTLY 不可在 psql -1 事务内执行

## 背景

补跑剩余迁移时，对全部文件统一使用 `psql -1`（单事务）。

## 现象

`20260513152636_replace_manifest_cleanup_index.sql` 失败：

```
ERROR: CREATE INDEX CONCURRENTLY cannot run inside a transaction block
```

## 根因

PostgreSQL 规定 **§5.2** 同类运维：`CONCURRENTLY` 索引必须在 autocommit 模式下执行。

## 解决步骤

对含 `CONCURRENTLY` 的迁移文件单独执行，**不加** `-1`：

```bash
docker exec -i supabase-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  < /path/to/20260513152636_replace_manifest_cleanup_index.sql
```

其余迁移可继续使用 `-1`。

## 验证方式

```bash
docker exec supabase-db psql -U postgres -d postgres -tAc \
  "SELECT indexname FROM pg_indexes WHERE indexname LIKE '%manifest%cleanup%';"
```

## 关联文件

- `/root/capgos/capgo/supabase/migrations/20260513152636_replace_manifest_cleanup_index.sql`
- 全栈文档 **§5.2**
