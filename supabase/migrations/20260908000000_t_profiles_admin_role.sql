-- InfraGo Tey module: allow 'admin' in profiles.role.
--
-- current_user_is_admin() and every admin RLS policy added in
-- 20260904000000_t_admin_policies_rating_anon.sql check
-- lower(profiles.role::text) = 'admin', but profiles_role_check (defined
-- outside this repo's migrations, alongside the base profiles table) only
-- ever allowed ('commuter', 'driver'). No profile row could legally hold
-- role = 'admin', so the entire admin review module (T3 identity review,
-- T4 vehicle review) was structurally unreachable - not one account could
-- ever pass current_user_is_admin(), independent of any other bug.
--
-- Widening an existing CHECK constraint to add one more allowed value is
-- safe: every existing row is already 'commuter' or 'driver' and stays
-- valid; this only permits a new value going forward.
ALTER TABLE profiles DROP CONSTRAINT IF EXISTS profiles_role_check;
ALTER TABLE profiles ADD CONSTRAINT profiles_role_check
  CHECK (role = ANY (ARRAY['commuter'::text, 'driver'::text, 'admin'::text]));
