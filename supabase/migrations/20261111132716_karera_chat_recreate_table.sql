/*
# Recreate chat_messages table to fix PostgREST schema cache

## Problem
PostgREST reports "Could not find the table 'public.chat_messages' in the schema cache"
for every API request to chat_messages. The table exists in PostgreSQL but PostgREST
has not loaded it into its internal cache. NOTIFY pgrst reload did not fix it.

## Fix
Drop and recreate the chat_messages table from scratch. This forces PostgREST to
reload its schema cache and recognize the table. The table had 0 rows so no data loss.

## Tables
- chat_messages: stores chat messages between users and admin support
  - id (uuid PK)
  - user_id (uuid FK to profiles, NOT NULL) — the conversation owner
  - sender_id (uuid FK to auth.users, NOT NULL, default auth.uid()) — who sent it
  - sender_role (text, NOT NULL, default 'user') — 'user' or 'admin'
  - body (text, NOT NULL) — message content
  - read_at (timestamptz, nullable) — when admin message was read by user
  - created_at (timestamptz, NOT NULL, default now())

## Security
- RLS enabled
- Grants: SELECT, INSERT, UPDATE, DELETE to authenticated only
- Policies:
  - SELECT: users see their own conversations, admins see all
  - INSERT: sender_id must be auth.uid(), user_id must be own or admin
  - UPDATE: users or admins can update (e.g. mark as read)
  - DELETE: not granted (no delete policy needed)

## Functions
- send_chat_message(p_user_id, p_body) returns void — SECURITY DEFINER
  Inserts a chat message. Admins can send to any user; users can only send to themselves.
*/

-- Drop old table and function
DROP TABLE IF EXISTS public.chat_messages CASCADE;
DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text);

-- Recreate table
CREATE TABLE public.chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL DEFAULT auth.uid() REFERENCES auth.users(id) ON DELETE CASCADE,
  sender_role text NOT NULL DEFAULT 'user' CHECK (sender_role IN ('user', 'admin')),
  body text NOT NULL CHECK (length(btrim(body)) > 0),
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Index for conversation queries
CREATE INDEX chat_messages_user_id_idx ON public.chat_messages(user_id);
CREATE INDEX chat_messages_created_at_idx ON public.chat_messages(created_at);

-- Enable RLS
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;

-- Grants: only authenticated role (app has sign-in)
GRANT SELECT, INSERT, UPDATE, DELETE ON public.chat_messages TO authenticated;

-- Policies
DROP POLICY IF EXISTS "select_own_or_all_chat" ON public.chat_messages;
CREATE POLICY "select_own_or_all_chat"
  ON public.chat_messages FOR SELECT
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

DROP POLICY IF EXISTS "insert_chat" ON public.chat_messages;
CREATE POLICY "insert_chat"
  ON public.chat_messages FOR INSERT
  TO authenticated
  WITH CHECK (
    sender_id = auth.uid()
    AND (
      user_id = auth.uid()
      OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
    )
  );

DROP POLICY IF EXISTS "update_chat_read" ON public.chat_messages;
CREATE POLICY "update_chat_read"
  ON public.chat_messages FOR UPDATE
  TO authenticated
  USING (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  )
  WITH CHECK (
    user_id = auth.uid()
    OR EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

DROP POLICY IF EXISTS "delete_chat" ON public.chat_messages;
CREATE POLICY "delete_chat"
  ON public.chat_messages FOR DELETE
  TO authenticated
  USING (
    EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = auth.uid() AND p.role = 'admin')
  );

-- Recreate send_chat_message RPC
CREATE OR REPLACE FUNCTION public.send_chat_message(p_user_id uuid, p_body text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_is_admin boolean;
  v_body text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  v_body := btrim(p_body);
  IF v_body IS NULL OR length(v_body) = 0 THEN
    RAISE EXCEPTION 'Message body cannot be empty' USING ERRCODE = '23514';
  END IF;
  IF length(v_body) > 2000 THEN
    RAISE EXCEPTION 'Message too long' USING ERRCODE = '23514';
  END IF;

  v_is_admin := public.is_admin();

  IF NOT v_is_admin AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not allowed' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_messages (user_id, sender_id, sender_role, body)
  VALUES (p_user_id, auth.uid(), CASE WHEN v_is_admin THEN 'admin' ELSE 'user' END, v_body);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_chat_message(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(uuid, text) TO authenticated;

-- Add to realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;

-- Force PostgREST schema reload
NOTIFY pgrst, 'reload schema';
