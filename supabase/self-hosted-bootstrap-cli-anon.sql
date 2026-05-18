-- Self-hosted: restore anon EXECUTE on get_user_id(text) for @capgo/cli login.
--
-- Upstream migration 20260427105909 revokes this from anon (GHSA / API-key oracle hardening).
-- Published CLI still validates login via RPC get_user_id({ apikey }) with the anon JWT + capgkey header.
-- Until CLI switches to capgkey-bound helpers, self-hosted installs need this grant.
--
-- Idempotent: safe to re-run.

GRANT EXECUTE ON FUNCTION public.get_user_id(text) TO anon;
