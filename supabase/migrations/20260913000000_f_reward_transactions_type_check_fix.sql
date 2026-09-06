ALTER TABLE reward_transactions
DROP CONSTRAINT IF EXISTS reward_transactions_type_check;

ALTER TABLE reward_transactions
ADD CONSTRAINT reward_transactions_type_check
CHECK (type IN ('demo_grant', 'earn', 'redeem', 'restore'));
