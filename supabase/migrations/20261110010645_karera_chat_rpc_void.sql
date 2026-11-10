/*
# Simplify send_chat_message to return void

1. Problem
- RETURNS TABLE causes issues with PostgREST/supabase-js parsing.
- Other RPC functions in this app (approve_transaction, admin_adjust_balance)
  return void and work reliably.

2. Fix
- Drop the RETURNS TABLE version, replace with RETURNS void.
- Same authorization logic, same insert, just no return value.
- Frontend will reload messages after send succeeds.
*/

DROP FUNCTION IF EXISTS public.send_chat_message(uuid, text);

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
