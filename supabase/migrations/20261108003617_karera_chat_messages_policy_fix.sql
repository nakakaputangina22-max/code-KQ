/*
# Fix chat_messages RLS policies for reliable inserts

1. Problem
- The insert policy used a raw `EXISTS (SELECT 1 FROM profiles ...)` subquery to
  check admin status. That subquery runs as the authenticated user and is subject
  to profiles RLS, which can cause inserts to fail in edge cases.
- The update policy had the same fragile subquery.

2. Fix
- Replace the raw admin-check subqueries with the existing `is_admin()` SECURITY
  DEFINER function (bypasses RLS, used everywhere else in this schema).
- Simplify the insert WITH CHECK: sender must be themselves (sender_id = auth.uid())
  AND either writing to their own conversation (user_id = auth.uid()) OR is_admin().
- Simplify the update USING/WITH CHECK the same way.

3. Security
- No new grants changed — SELECT, INSERT, UPDATE on authenticated remain.
- No DELETE granted to frontend roles.
*/

DROP POLICY IF EXISTS "insert_chat" ON chat_messages;
CREATE POLICY "insert_chat"
ON chat_messages FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND (user_id = auth.uid() OR is_admin())
);

DROP POLICY IF EXISTS "update_chat_read" ON chat_messages;
CREATE POLICY "update_chat_read"
ON chat_messages FOR UPDATE
TO authenticated
USING (user_id = auth.uid() OR is_admin())
WITH CHECK (user_id = auth.uid() OR is_admin());
