-- Migration: Replace extensions.uuid_generate_v4() with gen_random_uuid() on Capgo public tables
--
-- gen_random_uuid() is:
-- - Built-in since PostgreSQL 13 (no extension needed)
-- - ~3.5x faster than uuid_generate_v4()
-- - Functionally equivalent (both generate UUID v4)
--
-- 自托管 Supabase：storage.objects 等表属 supabase_storage_admin，迁移会话常用 postgres
-- 非 owner 会报「must be owner of table objects」，无法改其 DEFAULT。
-- 因此不在此迁移中 ALTER storage.*，也不 DROP uuid-ossp（仍被官方 Storage 默认依赖）。
-- 保留扩展无副作用；Capgo 业务表已全部改用 gen_random_uuid()。

DO $$
DECLARE
  r RECORD;
BEGIN
  ALTER TABLE public.apps
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.build_logs
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.build_requests
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.deleted_account
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.plans
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.usage_credit_grants
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  ALTER TABLE public.usage_overage_events
  ALTER COLUMN id SET DEFAULT gen_random_uuid();

  -- 仅 public：避免触及 storage/auth 等由其他角色拥有的系统表
  FOR r IN
    SELECT n.nspname AS sch, c.relname AS tbl, a.attname AS col
    FROM pg_catalog.pg_attrdef d
    JOIN pg_catalog.pg_attribute a
      ON d.adrelid = a.attrelid AND d.adnum = a.attnum AND NOT a.attisdropped AND a.attnum > 0
    JOIN pg_catalog.pg_class c ON a.attrelid = c.oid
    JOIN pg_catalog.pg_namespace n ON c.relnamespace = n.oid
    WHERE pg_get_expr(d.adbin, d.adrelid) LIKE '%uuid_generate_v4%'
      AND n.nspname = 'public'
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I ALTER COLUMN %I SET DEFAULT gen_random_uuid()',
      r.sch, r.tbl, r.col
    );
  END LOOP;
END $$;
