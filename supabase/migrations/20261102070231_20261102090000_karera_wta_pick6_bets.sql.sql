/*
# Add WTA and Pick 6 bets, and settle each bet type separately

1. Bet types
- WTA (Winner-Take-All): pick the single winning horse of one race. Offered on races 1 to 7.
- PICK6: pick the winning horse of each of races 1 to 6. Offered from races 1 to 6. The bet is recorded against race 6 (its final leg) so it settles when race 6 is settled.

2. Modified functions
- place_bet: accepts WTA and PICK6, checks leg count and race order for each bet type, and stores Pick 6 bets against race 6.
- settle_race: only settles pending bets whose type matches the bet type declared by the admin. Previously settling one bet type on a race could also mark bets of another type on that race as won or lost, and an FC settlement with no legs could mark combination bets as won.

3. Security
- No new tables or policies. Existing grants and row level security are unchanged.

4. Notes
- The bets type check is widened to include WTA and PICK6. Existing bets are unaffected.
- Pending bets of a type are settled only when the admin settles that type, so a race can be settled once per bet type.
*/

ALTER TABLE public.bets DROP CONSTRAINT IF EXISTS bets_bet_type_check;
ALTER TABLE public.bets ADD CONSTRAINT bets_bet_type_check
  CHECK (bet_type = ANY (ARRAY['FC'::text, 'DD'::text, 'XD'::text, 'DD1'::text, 'WTA'::text, 'PICK6'::text]));

CREATE OR REPLACE FUNCTION public.place_bet(p_race_id uuid, p_bet_type text, p_selections jsonb, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_race public.races%ROWTYPE;
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

  IF p_bet_type = 'PICK6' THEN
    IF v_race.race_number > 6 THEN
      RAISE EXCEPTION 'Pick 6 is only available from races 1 to 6';
    END IF;
    SELECT * INTO v_race FROM public.races WHERE race_number = 6;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Pick 6 needs race 6 on the card';
    END IF;
  END IF;

  IF NOT v_race.betting_open OR v_race.status IN ('closed', 'settled') THEN
    RAISE EXCEPTION 'Betting is closed for this race';
  END IF;

  IF p_bet_type = 'WTA' AND v_race.race_number > 7 THEN
    RAISE EXCEPTION 'WTA is only available on races 1 to 7';
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
        IF (v_legs->v_i->>'race')::int <> v_i + 1 THEN
          RAISE EXCEPTION 'Pick 6 must cover races 1 to 6 in order';
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

  INSERT INTO public.bets (user_id, race_id, bet_type, selections, amount)
  VALUES (auth.uid(), v_race.id, p_bet_type, p_selections, p_amount)
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

  FOR v_bet IN
    SELECT * FROM public.bets
    WHERE race_id = p_race_id AND status = 'PENDING' AND bet_type = v_type
  LOOP
    v_match := false;

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
