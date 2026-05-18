# 007 — 自托管创建组织失败：`cannot_get_plan`

## 现象

创建组织时 `POST /functions/v1/organization` 返回：

```json
{
  "error": "cannot_get_plan",
  "message": "Cannot get plan",
  "moreInfo": {
    "error": "Cannot coerce the result to a single JSON object",
    "estimatedMau": 2000
  }
}
```

## 根因

`organization/post.ts` 中 `getInitialPlanForMau` 从 `public.plans` 按 MAU 选取套餐：

```sql
SELECT ... FROM plans WHERE mau >= :estimatedMau ORDER BY mau ASC LIMIT 1
```

一键部署默认 **不** 执行 `seed.sql`（`RUN_DB_SEED=false`），`plans` 表为空，`.single()` 无行可返回，PostgREST 报错 *Cannot coerce the result to a single JSON object*。

## 解决

1. 执行 [`supabase/self-hosted-bootstrap-plans.sql`](../../supabase/self-hosted-bootstrap-plans.sql)（仅插入 4 档套餐，可重复执行）。
2. 或设置 `RUN_DB_SEED=true` 跑完整 seed（会清空并重置大量测试数据，**生产慎用**）。
3. 部署脚本已默认 `RUN_BOOTSTRAP_PLANS=true`，在 `db_post_steps` 中自动写入 plans。

## 验证

```bash
docker exec -i supabase-db psql -U postgres -d postgres -c \
  "SELECT name, mau, stripe_id FROM public.plans ORDER BY mau;"
```

应至少有 `Solo`（mau=2000）等 4 行。

## 全栈文档对照

- 相关章节：**§5**（迁移与数据）、**§10.1**（创建组织）
- 参考：[`/root/SELF_HOSTED_FULL_STACK.zh-CN.md`](/root/SELF_HOSTED_FULL_STACK.zh-CN.md)
