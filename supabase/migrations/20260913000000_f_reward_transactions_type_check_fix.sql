-- InfraGo Foo module fix: 20260903000000_t_rewards_earn.sql already contains
-- this exact DROP/ADD to widen reward_transactions_type_check to include
-- 'earn', but nothing ever exercised the earn path until reward earning was
-- wired up, so the gap went unnoticed — earn_completion_reward's own INSERT
-- was failing with "violates check constraint reward_transactions_type_check"
-- because the live constraint still only allowed
-- ('demo_grant', 'redeem', 'restore'). Re-applying the same statement here
-- is a safe no-op if it was already fixed, and closes the gap if it wasn't.

ALTER TABLE reward_transactions
DROP CONSTRAINT IF EXISTS reward_transactions_type_check;

ALTER TABLE reward_transactions
ADD CONSTRAINT reward_transactions_type_check
CHECK (type IN ('demo_grant', 'earn', 'redeem', 'restore'));
