-- Self-hosted: restore anon EXECUTE on @capgo/cli-facing RPCs revoked by security migrations.
--
-- Upstream (e.g. 20260427105909, 20260308203352) revokes API-key oracle / org-status RPCs from anon.
-- Published CLI still uses anon JWT + capgkey header and calls these via PostgREST.
--
-- Do NOT grant: find_apikey_by_value, get_user_id(text,text), get_org_perm_for_apikey_v2 (oracle / legacy).
-- Idempotent: safe to re-run.

-- Core: login + bundle/channel/app permission checks
GRANT EXECUTE ON FUNCTION public.get_user_id(text) TO anon;
GRANT EXECUTE ON FUNCTION public.get_org_perm_for_apikey(text, text) TO anon;

-- Upload path: trial / plan warnings (missing grant → silent false, misleading warnings)
GRANT EXECUTE ON FUNCTION public.is_paying_org(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.is_trial_org(uuid) TO anon;

-- Org CLI: members list, 2FA / password-policy toggles
GRANT EXECUTE ON FUNCTION public.get_org_members(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_identity_apikey_only(public.key_mode[]) TO anon;
GRANT EXECUTE ON FUNCTION public.check_org_members_2fa_enabled(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.check_org_members_password_policy(uuid) TO anon;
