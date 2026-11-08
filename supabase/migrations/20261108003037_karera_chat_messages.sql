/*
# Chat / Messenger for admin and users

1. Purpose
- Lets users send private messages to the admin and the admin reply.
- Powers a support/concern channel so users can ask questions and raise issues.
- The admin sees a shared inbox of all conversations and replies to any user.

2. New Tables
- `chat_messages`
  - `id` uuid primary key (gen_random_uuid)
  - `user_id` uuid NOT NULL — the user the conversation belongs to (FK profiles.id ON DELETE CASCADE)
  - `sender_id` uuid NOT NULL — who actually sent the message (FK auth.users.id ON DELETE CASCADE)
  - `sender_role` text NOT NULL, CHECK in ('user','admin') — denormalized for fast rendering
  - `body` text NOT NULL — the message text (trimmed, length 1..2000 enforced in app)
  - `read_at` timestamptz NULL — when the recipient opened it (NULL = unread)
  - `created_at` timestamptz DEFAULT now()

3. Indexes
- `chat_messages_user_created_idx` on (user_id, created_at) — conversation ordering
- `chat_messages_unread_idx` on (user_id) WHERE read_at IS NULL — unread counts
- `chat_messages_sender_idx` on (sender_id)

4. Security
- Enable RLS on `chat_messages`.
- Grant SELECT, INSERT, UPDATE to `authenticated` only (no anon — app requires sign-in).
- No DELETE granted to frontend roles (messages are retained).
- SELECT policy: a user sees messages in their own conversation; an admin sees all.
- INSERT policy: a user can send a message in their own conversation; an admin can send a message in any conversation.
- UPDATE policy: a user can mark messages in their own conversation as read; an admin can mark any as read.
- sender_id defaults to auth.uid() so client inserts without it still satisfy WITH CHECK.

5. Realtime
- Add `chat_messages` to the existing `supabase_realtime` publication so realtime subscriptions fire.
*/

CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_role text NOT NULL DEFAULT 'user' CHECK (sender_role IN ('user','admin')),
  body text NOT NULL DEFAULT '',
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS chat_messages_user_created_idx ON chat_messages (user_id, created_at);
CREATE INDEX IF NOT EXISTS chat_messages_unread_idx ON chat_messages (user_id) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS chat_messages_sender_idx ON chat_messages (sender_id);

ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON chat_messages TO authenticated;

DROP POLICY IF EXISTS "select_own_or_all_chat" ON chat_messages;
CREATE POLICY "select_own_or_all_chat"
ON chat_messages FOR SELECT
TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
);

DROP POLICY IF EXISTS "insert_chat" ON chat_messages;
CREATE POLICY "insert_chat"
ON chat_messages FOR INSERT
TO authenticated
WITH CHECK (
  sender_id = auth.uid()
  AND (
    (user_id = auth.uid() AND sender_role = 'user')
    OR (
      sender_role = 'admin'
      AND EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
    )
  )
);

DROP POLICY IF EXISTS "update_chat_read" ON chat_messages;
CREATE POLICY "update_chat_read"
ON chat_messages FOR UPDATE
TO authenticated
USING (
  user_id = auth.uid()
  OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
)
WITH CHECK (
  user_id = auth.uid()
  OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
);

-- Realtime publication for live chat updates
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END $$;
