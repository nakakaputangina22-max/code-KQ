/*
# Fix send_chat_message return type for supabase-js compatibility

1. Problem
- The function returns `chat_messages` (a composite/record type). The supabase-js
  client has trouble with composite return types from .rpc() calls — the response
  shape doesn't match what the PostgREST API expects, causing errors.

2. Fix
- Change the return type from `RETURNS chat_messages` to `RETURNS TABLE(...)` 
  with explicit column definitions matching chat_messages columns.
- This makes PostgREST return a proper JSON array/object that supabase-js can parse.
- Drop and recreate the function (parameter types unchanged so grants still apply,
  but we re-grant to be safe).
*/

DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text);

CREATE OR REPLACE FUNCTION public.send_chat_message(p_user_id uuid, p_body text)
RETURNS TABLE(
  id uuid,
  user_id uuid,
  sender_id uuid,
  sender_role text,
  body text,
  read_at timestamptz,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_row public.chat_messages;
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
    RAISE EXCEPTION 'Message too long (max 2000 characters)' USING ERRCODE = '23514';
  END IF;

  v_is_admin := public.is_admin();

  IF NOT v_is_admin AND p_user_id <> auth.uid() THEN
    RAISE EXCEPTION 'Not allowed' USING ERRCODE = '42501';
  END IF;

  INSERT INTO public.chat_messages (user_id, sender_id, sender_role, body)
  VALUES (p_user_id, auth.uid(), CASE WHEN v_is_admin THEN 'admin' ELSE 'user' END, v_body)
  RETURNING * INTO v_row;

  RETURN QUERY SELECT v_row.id, v_row.user_id, v_row.sender_id, v_row.sender_role, v_row.body, v_row.read_at, v_row.created_at;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.send_chat_message(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.send_chat_message(uuid, text) TO authenticated;
