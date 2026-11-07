/*
# Race results history and settlement records

1. New Tables
- `race_results`: one row per race and bet type that has been settled.
  - `race_id`: the race the result belongs to (deleted with the race).
  - `bet_type`: FC, DD, XD, DD1, WTA or PICK6.
  - `winners`: the declared winning horses, exactly as the admin entered them.
  - `dividend`: the payout per ₱5 base bet.
  - `total_staked`: total amount wagered on that bet type for the race.
  - `winning_bets`: how many tickets won.
  - `total_payout`: total amount paid to winners.
  - `settled_at`: when the result was recorded.

2. Modified Functions
- `settle_race` now writes a `race_results` row each time a bet type is settled.
- Settling the same bet type for the same race a second time is refused, so a
  recorded result can never be silently overwritten after payouts were made.

3. Security
- Row level security is enabled on `race_results`.
- Signed-in users may read results. Only the settlement function writes them;
  no insert, update or delete policy is granted to any role.
- The table is granted SELECT to `authenticated` only.

4. Notes
- Existing settled races have no result rows; they are not back-filled.
*/

CREATE TABLE IF NOT EXISTS public.race_results (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  race_id uuid NOT NULL REFERENCES public.races(id) ON DELETE CASCADE,
  bet_type text NOT NULL CHECK (bet_type IN ('FC', 'DD', 'XD', 'DD1', 'WTA', 'PICK6')),
  winners jsonb NOT NULL,
  dividend numeric(14,2) NOT NULL CHECK (dividend >= 0),
  total_staked numeric(14,2) NOT NULL DEFAULT 0,
  winning_bets integer NOT NULL DEFAULT 0,
  total_payout numeric(14,2) NOT NULL DEFAULT 0,
  settled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (race_id, bet_type)
);

ALTER TABLE public.race_results ENABLE ROW LEVEL SECURITY;

GRANT SELECT ON public.race_results TO authenticated;

DROP POLICY IF EXISTS "select_race_results" ON public.race_results;
CREATE POLICY "select_race_results" ON public.race_results FOR SELECT
  TO authenticated USING (true);

CREATE OR REPLACE FUNCTION public.settle_race(p_race_id uuid, p_winners jsonb, p_dividend numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_type text;
v_won int := 0;
v_lost int := 0;
v_total_payout numeric(14,2) := 0;
v_total_staked numeric(14,2) := 0;
v_bet public.bets%ROWTYPE;
v_match boolean;
v_payout numeric(14,2);
v_bet_legs jsonb;
v_win_legs jsonb;
v_i int;
BEGIN
IF NOT public.is_admin() THEN
RAISE EXCEPTION 'Admin only';
END IF;
IF p_dividend IS NULL OR p_dividend < 0 THEN
RAISE EXCEPTION 'Invalid dividend';
END IF;

v_type := p_winners->>'type';
IF v_type IS NULL OR v_type NOT IN ('FC', 'DD', 'XD', 'DD1', 'WTA', 'PICK6') THEN
RAISE EXCEPTION 'Invalid bet type to settle';
END IF;
v_win_legs := p_winners->'legs';
IF v_type <> 'FC' AND (v_win_legs IS NULL OR jsonb_typeof(v_win_legs) <> 'array') THEN
RAISE EXCEPTION 'Winning horses are missing';
END IF;

IF EXISTS (SELECT 1 FROM public.race_results WHERE race_id = p_race_id AND bet_type = v_type) THEN
RAISE EXCEPTION '% is already settled for this race', v_type;
END IF;

FOR v_bet IN
SELECT * FROM public.bets
WHERE race_id = p_race_id AND status = 'PENDING' AND bet_type = v_type
LOOP
v_match := false;
v_total_staked := v_total_staked + v_bet.amount;

IF v_type = 'FC' THEN
v_match := (v_bet.selections->>'first' = p_winners->>'first'
AND v_bet.selections->>'second' = p_winners->>'second');
ELSE
v_bet_legs := v_bet.selections->'legs';
v_match := jsonb_array_length(v_bet_legs) = jsonb_array_length(v_win_legs);
IF v_match THEN
FOR v_i IN 0..jsonb_array_length(v_win_legs) - 1 LOOP
IF (v_bet_legs->v_i->>'race') IS DISTINCT FROM (v_win_legs->v_i->>'race')
OR (v_bet_legs->v_i->>'horse') IS DISTINCT FROM (v_win_legs->v_i->>'horse') THEN
v_match := false;
END IF;
END LOOP;
END IF;
END IF;

IF v_match THEN
v_payout := (v_bet.amount / 5.0) * p_dividend;
UPDATE public.bets
SET status = 'WON', payout_amount = v_payout, settled_at = now()
WHERE id = v_bet.id;
PERFORM public.adjust_balance(v_bet.user_id, v_payout);
INSERT INTO public.transactions
(user_id, type, amount, status, related_bet_id, note, processed_at)
VALUES (v_bet.user_id, 'WIN', v_payout, 'APPROVED', v_bet.id,
'Winnings: ' || v_bet.ticket_code, now());
v_won := v_won + 1;
v_total_payout := v_total_payout + v_payout;
ELSE
UPDATE public.bets SET status = 'LOST', settled_at = now() WHERE id = v_bet.id;
v_lost := v_lost + 1;
END IF;
END LOOP;

INSERT INTO public.race_results
(race_id, bet_type, winners, dividend, total_staked, winning_bets, total_payout)
VALUES (p_race_id, v_type, p_winners, p_dividend, v_total_staked, v_won, v_total_payout);

UPDATE public.races
SET status = 'settled', betting_open = false, updated_at = now()
WHERE id = p_race_id;

RETURN jsonb_build_object(
'won', v_won,
'lost', v_lost,
'total_payout', v_total_payout
);
END;
$function$;
