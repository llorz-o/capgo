# psql 逐文件迁移：临时表 ON COMMIT DROP 与单事务

## 背景

阶段 3 使用 `docker exec psql` 按文件名排序逐个执行 `supabase/migrations/*.sql`（全栈 **§5.2** 路径 B）。

## 现象

迁移 `20260319155734_fix_global_stats_build_seconds_and_conversion_rate.sql` 报错：

```
ERROR: relation "temp_daily_build_stats" does not exist
```

此前 `supabase db push` 亦因 TLS 无法连接 `127.0.0.1:5432` 失败。

## 根因

1. **§5.2**：默认 `psql` 每条语句自动提交；该迁移使用 `CREATE TEMP TABLE ... ON COMMIT DROP`，在 `UPDATE ... FROM temp_daily_build_stats` 执行前临时表已被提交边界销毁。
2. 首次失败后部分 `ALTER` 已生效，重跑整文件会报 `column "build_minutes_day_ios" does not exist`。

## 解决步骤

1. 对含临时表/多语句依赖的片段，使用 `psql -1`（单事务）执行；或仅重跑未完成的 SQL 段（本机补跑 temp 表 backfill 部分）。
2. `db push` 若需使用，连接串加 `sslmode=disable`；本机仍优先 `docker exec` 连容器内 Postgres。
3. 记录失败文件名，勿从头全量重跑已部分应用的文件。

## 验证方式

```bash
docker exec supabase-db psql -U postgres -d postgres -tAc "SELECT count(*) FROM public.apps;"
```

应返回表存在（count 可为 0）。

## 关联文件

- `/root/capgos/capgo/supabase/migrations/20260319155734_fix_global_stats_build_seconds_and_conversion_rate.sql`
- 全栈文档 **§5.2**
