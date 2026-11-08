/*
# Add send_chat_message RPC function

1. Problem
- Direct INSERT on chat_messages from the client consistently fails with RLS
  errors, even though the policies look correct. The rest of this app uses
  SECURITY DEFINER RPC functions for mutations (place_bet, approve_transaction,
  etc.) — chat should follow the same pattern.

2. Fix
- Create `send_chat_message(p_user_id uuid, p_body text)` SECURITY DEFINER
  function that:
  - Validates the caller is authenticated (auth.uid() is not null)
  - For regular users: p_user_id must equal auth.uid(), sender_role = 'user'
  - For admins: is_admin() must be true, sender_role = 'admin', p_user_id can
    be any user (admin replying to a user's conversation)
  - Trims the body, rejects empty or >2000 char messages
  - Inserts the row and returns it
- REVOKE EXECUTE from PUBLIC/anon, GRANT to authenticated only.

3. Security
- SECURITY DEFINER runs with the function owner's privileges (bypasses RLS)
- All authorization checks are done inside the function body BEFORE the insert
- The function only writes sender_id = auth.uid(), so the caller cannot spoof
  the sender
*/

CREATE OR REPLACE FUNCTION public.send_chat_message(p_user_id uuid, p_body text)
RETURNS public.chat_messages
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.chat_messages;
  v_is_admin boolean;
  v_body text;
BEGIN
  -- Must be authenticated
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  -- Trim and validate body
  v_body := btrim(p_body);
  IF v_body IS NULL OR length(v_body) = 0 THEN
    RAISE EXCEPTION 'Message body cannot be empty' USING ERRCODE = '23514';
  END IF;
  IF length(v_body) > 2000 THEN
    RAISE EXCEPTION 'Message too long (max 2000 characters)' USING ERRCODE = '23514';
  END IF;

  -- Check admin status
  v_is_admin := public.is_admin();

  -- Authorization: user can only send to their own conversation, admin can send to any
  IF NOT v_is_admin AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not allowed' USING ERRCODE = '42501';
  END IF;

  -- Insert and return the row
  INSERT INTO public.chat_messages (user_id, sender_id, sender_role, body)
  VALUES (p_user_id, auth.uid(), CASE WHEN v_is_admin THEN 'admin' ELSE 'user' END, v_body)
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_chat_message(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(uuid, text) TO authenticated;
