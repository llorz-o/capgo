-- Minimal plan catalog for self-hosted (no full seed.sql).
-- Required for POST /functions/v1/organization (getInitialPlanForMau).
-- Idempotent: safe to re-run.

INSERT INTO public.plans (
  created_at, updated_at, name, description, price_m, price_y, stripe_id, credit_id, id,
  price_m_id, price_y_id, storage, bandwidth, mau, market_desc, build_time_unit, native_build_concurrency
) VALUES
  (NOW(), NOW(), 'Solo', 'plan.solo.desc', 14, 146, 'prod_LQIregjtNduh4q', 'prod_TJRd2hFHZsBIPK', '526e11d8-3c51-4581-ac92-4770c602f47c',
   'price_1LVvuZGH46eYKnWwuGKOf4DK', 'price_1LVvuIGH46eYKnWwHMDCrxcH', 1073741824, 13958643712, 2000, 'Best for independent developers', 1800, 2),
  (NOW(), NOW(), 'Maker', 'plan.maker.desc', 39, 396, 'prod_LQIs1Yucml9ChU', 'prod_TJRd2hFHZsBIPK', '440cfd69-0cfd-486e-b59b-cb99f7ae76a0',
   'price_1KjSGyGH46eYKnWwL4h14DsK', 'price_1KjSKIGH46eYKnWwFG9u4tNi', 3221225472, 268435456000, 10000, 'Best for small business owners', 3600, 3),
  (NOW(), NOW(), 'Team', 'plan.team.desc', 99, 998, 'prod_LQIugvJcPrxhda', 'prod_TJRd2hFHZsBIPK', 'abd76414-8f90-49a5-b3a4-8ff4d2e12c77',
   'price_1KjSIUGH46eYKnWwWHvg8XYs', 'price_1KjSLlGH46eYKnWwAwMW2wiW', 6442450944, 536870912000, 100000, 'Best for medium enterprises', 18000, 4),
  (NOW(), NOW(), 'Enterprise', 'plan.payasyougo.desc', 239, 4799, 'prod_MH5Jh6ajC9e7ZH', 'prod_TJRd2hFHZsBIPK', '745d7ab3-6cd6-4d65-b257-de6782d5ba50',
   'price_1LYX8yGH46eYKnWwzeBjISvW', 'price_1LYX8yGH46eYKnWwzeBjISvW', 12884901888, 3221225472000, 1000000, 'Best for scalling enterprises', 600000, 6)
ON CONFLICT (stripe_id) DO UPDATE SET
  updated_at = EXCLUDED.updated_at,
  name = EXCLUDED.name,
  mau = EXCLUDED.mau,
  storage = EXCLUDED.storage,
  bandwidth = EXCLUDED.bandwidth,
  build_time_unit = EXCLUDED.build_time_unit,
  native_build_concurrency = EXCLUDED.native_build_concurrency,
  description = EXCLUDED.description,
  price_m = EXCLUDED.price_m,
  price_y = EXCLUDED.price_y,
  credit_id = EXCLUDED.credit_id,
  price_m_id = EXCLUDED.price_m_id,
  price_y_id = EXCLUDED.price_y_id,
  market_desc = EXCLUDED.market_desc;
