/*
# Starting races for WTA and Pick 6 bets (bet pools)

1. New table `bet_pools`
- One row per WTA or PICK 6 instance and the race it starts on.
- `bet_type` is 'WTA' or 'PICK6'. `start_race` is the race number (1 to 8).
- A WTA pool covers its start race up to the race before the next WTA start. The last WTA pool runs to race 7.
- A PICK 6 pool covers six consecutive races from its start race and settles on the last of them.

2. Modified table `bets`
- New column `pool_id` links each WTA and PICK 6 bet to its pool. Other bet types leave it empty.

3. Functions
- `place_bet` now takes the pool id. WTA bets must fall inside a WTA pool's races. PICK 6 bets must cover the six races from the pool's start, in order, and are stored against the last of them.
- The previous 4-argument `place_bet` is removed so only one version exists.

4. Security
- Row level security enabled on `bet_pools`. Signed-in users can read pools. Only administrators (is_admin()) can add or remove them.
- Grants: SELECT, INSERT and DELETE to `authenticated` only. `place_bet` is executable by `authenticated` only.

5. Existing data
- A WTA pool and a PICK 6 pool starting on race 1 are created so the current card keeps its behaviour.

6. Notes
- Deleting a pool keeps its bets; their pool link is cleared and they still settle per race.
- The realtime publication includes `bet_pools` so the bet slip updates when admins change starting races.
*/

CREATE TABLE IF NOT EXISTS public.bet_pools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bet_type text NOT NULL CHECK (bet_type IN ('WTA', 'PICK6')),
  start_race integer NOT NULL CHECK (start_race BETWEEN 1 AND 8),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (bet_type, start_race)
);

ALTER TABLE public.bet_pools ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, DELETE ON public.bet_pools TO authenticated;

DROP POLICY IF EXISTS "select_bet_pools" ON public.bet_pools;
CREATE POLICY "select_bet_pools" ON public.bet_pools FOR SELECT
  TO authenticated USING (true);

DROP POLICY IF EXISTS "insert_bet_pools" ON public.bet_pools;
CREATE POLICY "insert_bet_pools" ON public.bet_pools FOR INSERT
  TO authenticated WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "delete_bet_pools" ON public.bet_pools;
CREATE POLICY "delete_bet_pools" ON public.bet_pools FOR DELETE
  TO authenticated USING (public.is_admin());

INSERT INTO public.bet_pools (bet_type, start_race)
VALUES ('WTA', 1), ('PICK6', 1)
ON CONFLICT (bet_type, start_race) DO NOTHING;

ALTER TABLE public.bets ADD COLUMN IF NOT EXISTS pool_id uuid REFERENCES public.bet_pools(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS bets_pool_id_idx ON public.bets (pool_id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'bet_pools'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.bet_pools;
  END IF;
END $$;

DROP FUNCTION IF EXISTS public.place_bet(uuid, text, jsonb, numeric);

CREATE OR REPLACE FUNCTION public.place_bet(
  p_race_id uuid,
  p_bet_type text,
  p_selections jsonb,
  p_amount numeric,
  p_pool_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_race public.races%ROWTYPE;
  v_pool public.bet_pools%ROWTYPE;
  v_pool_id uuid := NULL;
  v_window_end int;
  v_balance numeric(14,2);
  v_bet public.bets%ROWTYPE;
  v_tx_id uuid;
  v_legs jsonb;
  v_leg_race int;
  v_leg_open boolean;
  v_leg_status text;
  v_i int;
  v_expected_legs int;
BEGIN
  IF p_amount < 5 THEN
    RAISE EXCEPTION 'Minimum bet is 5.00';
  END IF;
  IF mod(p_amount, 5) <> 0 THEN
    RAISE EXCEPTION 'Bet must be in increments of 5.00';
  END IF;
  IF p_bet_type NOT IN ('FC', 'DD', 'XD', 'DD1', 'WTA', 'PICK6') THEN
    RAISE EXCEPTION 'Invalid bet type';
  END IF;

  SELECT * INTO v_race FROM public.races WHERE id = p_race_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Race not found';
  END IF;

  IF p_bet_type IN ('WTA', 'PICK6') THEN
    IF p_pool_id IS NULL THEN
      RAISE EXCEPTION 'Choose the starting race for this bet';
    END IF;
    SELECT * INTO v_pool FROM public.bet_pools WHERE id = p_pool_id AND bet_type = p_bet_type;
    IF NOT FOUND THEN
      RAISE EXCEPTION '% starting race was not found', p_bet_type;
    END IF;
    v_pool_id := v_pool.id;
  END IF;

  IF p_bet_type = 'WTA' THEN
    SELECT COALESCE(MIN(start_race) - 1, 7) INTO v_window_end
    FROM public.bet_pools
    WHERE bet_type = 'WTA' AND start_race > v_pool.start_race;
    IF v_race.race_number < v_pool.start_race OR v_race.race_number > v_window_end THEN
      RAISE EXCEPTION 'This WTA covers races % to %', v_pool.start_race, v_window_end;
    END IF;
  END IF;

  IF p_bet_type = 'PICK6' THEN
    SELECT * INTO v_race FROM public.races WHERE race_number = v_pool.start_race + 5;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Pick 6 starting at race % needs races % to % on the card',
        v_pool.start_race, v_pool.start_race, v_pool.start_race + 5;
    END IF;
  END IF;

  IF NOT v_race.betting_open OR v_race.status IN ('closed', 'settled') THEN
    RAISE EXCEPTION 'Betting is closed for this race';
  END IF;

  IF p_bet_type <> 'FC' THEN
    v_legs := p_selections->'legs';
    v_expected_legs := CASE p_bet_type
      WHEN 'DD1' THEN 3
      WHEN 'PICK6' THEN 6
      WHEN 'WTA' THEN 1
      ELSE 2
    END;
    IF v_legs IS NULL OR jsonb_array_length(v_legs) <> v_expected_legs THEN
      RAISE EXCEPTION 'Invalid legs for %', p_bet_type;
    END IF;

    IF p_bet_type = 'DD'
    AND ((v_legs->0->>'race')::int <> v_race.race_number
    OR (v_legs->1->>'race')::int <> v_race.race_number + 1) THEN
      RAISE EXCEPTION 'DD requires the current race and the next race';
    END IF;
    IF p_bet_type = 'XD'
    AND ((v_legs->0->>'race')::int <> v_race.race_number
    OR (v_legs->1->>'race')::int <> v_race.race_number + 2) THEN
      RAISE EXCEPTION 'XD requires the current race and the race two positions ahead';
    END IF;
    IF p_bet_type = 'DD1'
    AND ((v_legs->0->>'race')::int <> v_race.race_number
    OR (v_legs->1->>'race')::int <> v_race.race_number + 1
    OR (v_legs->2->>'race')::int <> v_race.race_number + 2) THEN
      RAISE EXCEPTION 'DD+1 requires the current race and the next two races';
    END IF;
    IF p_bet_type = 'WTA' AND (v_legs->0->>'race')::int <> v_race.race_number THEN
      RAISE EXCEPTION 'WTA must be placed on the race it covers';
    END IF;
    IF p_bet_type = 'PICK6' THEN
      FOR v_i IN 0..5 LOOP
        IF (v_legs->v_i->>'race')::int <> v_pool.start_race + v_i THEN
          RAISE EXCEPTION 'Pick 6 must cover races % to % in order', v_pool.start_race, v_pool.start_race + 5;
        END IF;
      END LOOP;
    END IF;

    FOR v_i IN 0..jsonb_array_length(v_legs) - 1 LOOP
      v_leg_race := (v_legs->v_i->>'race')::int;
      SELECT betting_open, status INTO v_leg_open, v_leg_status
      FROM public.races
      WHERE race_number = v_leg_race;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Leg race % does not exist in the schedule', v_leg_race;
      END IF;
      IF NOT v_leg_open OR v_leg_status IN ('closed', 'settled') THEN
        RAISE EXCEPTION 'Betting is closed for leg race %', v_leg_race;
      END IF;
    END LOOP;
  END IF;

  SELECT balance INTO v_balance FROM public.profiles WHERE id = auth.uid();
  IF v_balance IS NULL THEN
    RAISE EXCEPTION 'Wallet not found';
  END IF;
  IF v_balance < p_amount THEN
    RAISE EXCEPTION 'Insufficient balance (need %, have %)', p_amount, v_balance;
  END IF;

  PERFORM public.adjust_balance(auth.uid(), -p_amount);

  INSERT INTO public.bets (user_id, race_id, bet_type, selections, amount, pool_id)
  VALUES (auth.uid(), v_race.id, p_bet_type, p_selections, p_amount, v_pool_id)
  RETURNING * INTO v_bet;

  INSERT INTO public.transactions
    (user_id, type, amount, status, related_bet_id, note, processed_at)
  VALUES (auth.uid(), 'BET', p_amount, 'SETTLED', v_bet.id, 'Bet placed: ' || v_bet.ticket_code, now())
  RETURNING id INTO v_tx_id;

  RETURN jsonb_build_object(
    'bet_id', v_bet.id,
    'ticket_code', v_bet.ticket_code,
    'amount', v_bet.amount,
    'bet_type', v_bet.bet_type,
    'status', v_bet.status
  );
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.place_bet(uuid, text, jsonb, numeric, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_bet(uuid, text, jsonb, numeric, uuid) TO authenticated;
