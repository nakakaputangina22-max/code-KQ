/*
# WTA and Pick 6: multi-horse tickets, per-combination pricing, pool settlement with carryover

1. Ticket rules
- WTA is a 7-leg sequence. Pick 6 is a 6-leg sequence. Each leg covers consecutive races from the ticket's start race.
- A bettor can pick one or more horses in each leg (key horses, backups, or boxing).
- Base price is P2.00 per combination. The ticket cost is the product of the number of horses picked in each leg, times P2.00.
- The server calculates the cost and rejects a stake that does not match it.

2. Settlement (WTA and Pick 6)
- The admin enters, for each leg, the finishing order of horses (1st place first, then 2nd, 3rd, and so on).
- A ticket wins when it includes the winning horse in every leg.
- WTA fallback: for each leg the winner is the first horse in that leg's finishing order that at least one pending ticket picked. If no ticket picked any of the listed horses for a leg, that leg has no winner and the pool carries over.
- Pick 6 uses only the 1st-place horse in each leg. No fallback.
- The pool equals the money staked on that start plus any amount carried over from the previous start of the same bet type.
- Winning tickets share the pool in proportion to their stake. Amounts are rounded down to the centavo.
- If no ticket covers all legs, the whole pool carries over to the next start of the same bet type.
- Earlier starts of the same bet type must be settled first, so carryover is never skipped.

3. Modified tables
- bets: minimum stake lowered from P5.00 to P2.00 so WTA and Pick 6 tickets can be priced per combination. Other bet types still require P5.00 minimum and multiples of P5.00 in the betting function.
- race_results: new columns pool_total (money available to the pool), carry_in (carried in from the previous start), and carried_over (money rolled to the next start). Existing rows default to 0.

4. Modified functions
- place_bet: WTA and Pick 6 tickets take horses per leg (selections as a list of horses), check every horse is running and not scratched, reject duplicate horses, and price the ticket. Other bet types are unchanged.
- settle_race: WTA and Pick 6 settlements are passed to the new pool settlement function. Other bet types are unchanged.
- settle_pool_race (new, internal): performs pool settlement.
- pool_ticket_matches (new, internal): checks whether a ticket covers the winning horse in every leg.

5. Security
- settle_pool_race and pool_ticket_matches are only called from inside the database. Public roles cannot run them directly.
- Access to race_results and bets is unchanged.
- The admin-only check stays in settle_race.
*/

ALTER TABLE public.bets DROP CONSTRAINT IF EXISTS bets_amount_check;
ALTER TABLE public.bets ADD CONSTRAINT bets_amount_check CHECK (amount >= 2);

ALTER TABLE public.race_results ADD COLUMN IF NOT EXISTS pool_total numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE public.race_results ADD COLUMN IF NOT EXISTS carry_in numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE public.race_results ADD COLUMN IF NOT EXISTS carried_over numeric(14,2) NOT NULL DEFAULT 0;
ALTER TABLE public.race_results DROP CONSTRAINT IF EXISTS race_results_pool_amounts_check;
ALTER TABLE public.race_results ADD CONSTRAINT race_results_pool_amounts_check
  CHECK (pool_total >= 0 AND carry_in >= 0 AND carried_over >= 0);

CREATE OR REPLACE FUNCTION public.pool_ticket_matches(p_selections jsonb, p_winners text[])
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
SELECT NOT EXISTS (
  SELECT 1
  FROM generate_subscripts(p_winners, 1) AS i
  WHERE NOT ((p_selections->'legs'->(i - 1)->'horses') ? p_winners[i])
);
$function$;

REVOKE ALL ON FUNCTION public.pool_ticket_matches(jsonb, text[]) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.settle_pool_race(p_race_id uuid, p_type text, p_winners jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
v_race public.races%ROWTYPE;
v_count int;
v_pool public.bet_pools%ROWTYPE;
v_prev_start int;
v_carry_in numeric(14,2) := 0;
v_pot numeric(14,2);
v_total_staked numeric(14,2) := 0;
v_winning_stake numeric(14,2) := 0;
v_dividend numeric(14,2) := 0;
v_fin jsonb;
v_horse text;
v_chosen text;
v_eff text[] := '{}';
v_all boolean := true;
v_out_legs jsonb := '[]'::jsonb;
v_bet public.bets%ROWTYPE;
v_payout numeric(14,2);
v_won int := 0;
v_lost int := 0;
v_total_payout numeric(14,2) := 0;
v_carried numeric(14,2) := 0;
v_i int;
v_j int;
BEGIN
SELECT * INTO v_race FROM public.races WHERE id = p_race_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Race not found';
END IF;
v_count := CASE WHEN p_type = 'WTA' THEN 7 ELSE 6 END;

SELECT * INTO v_pool FROM public.bet_pools
WHERE bet_type = p_type AND start_race = v_race.race_number - v_count + 1;
IF NOT FOUND THEN
RAISE EXCEPTION 'No % starts on race %, so there is nothing to settle here', p_type, v_race.race_number;
END IF;

IF EXISTS (
SELECT 1 FROM public.bet_pools p
WHERE p.bet_type = p_type
AND p.start_race < v_pool.start_race
AND NOT EXISTS (
SELECT 1 FROM public.race_results rr
JOIN public.races r ON r.id = rr.race_id
WHERE rr.bet_type = p_type AND r.race_number = p.start_race + v_count - 1
)
) THEN
RAISE EXCEPTION 'Settle the earlier % start first, because unpaid money carries forward from it', p_type;
END IF;

v_prev_start := (SELECT max(p.start_race) FROM public.bet_pools p
WHERE p.bet_type = p_type AND p.start_race < v_pool.start_race);
IF v_prev_start IS NOT NULL THEN
SELECT rr.carried_over INTO v_carry_in
FROM public.race_results rr
JOIN public.races r ON r.id = rr.race_id
WHERE rr.bet_type = p_type AND r.race_number = v_prev_start + v_count - 1;
v_carry_in := coalesce(v_carry_in, 0);
END IF;

SELECT coalesce(sum(amount), 0) INTO v_total_staked FROM public.bets WHERE pool_id = v_pool.id;
v_pot := v_carry_in + v_total_staked;

FOR v_i IN 0..v_count - 1 LOOP
v_fin := p_winners->'legs'->v_i->'horses';
IF (p_winners->'legs'->v_i->>'race')::int IS DISTINCT FROM v_pool.start_race + v_i THEN
RAISE EXCEPTION 'Winning legs must cover races % to % in order', v_pool.start_race, v_pool.start_race + v_count - 1;
END IF;
IF v_fin IS NULL OR jsonb_typeof(v_fin) <> 'array' OR jsonb_array_length(v_fin) = 0 THEN
RAISE EXCEPTION 'Enter the finishing order for race %', v_pool.start_race + v_i;
END IF;

v_chosen := NULL;
FOR v_j IN 0..(CASE WHEN p_type = 'PICK6' THEN 0 ELSE jsonb_array_length(v_fin) - 1 END) LOOP
v_horse := v_fin->>v_j;
IF EXISTS (
SELECT 1 FROM public.bets b
WHERE b.pool_id = v_pool.id
AND b.status = 'PENDING'
AND (b.selections->'legs'->v_i->'horses') ? v_horse
) THEN
v_chosen := v_horse;
EXIT;
END IF;
END LOOP;

v_eff := array_append(v_eff, v_chosen);
IF v_chosen IS NULL THEN
v_all := false;
END IF;
v_out_legs := v_out_legs || jsonb_build_object(
'race', v_pool.start_race + v_i,
'horse', v_chosen,
'finishing', v_fin
);
END LOOP;

IF v_all THEN
SELECT coalesce(sum(b.amount), 0) INTO v_winning_stake
FROM public.bets b
WHERE b.pool_id = v_pool.id
AND b.status = 'PENDING'
AND public.pool_ticket_matches(b.selections, v_eff);
END IF;

IF v_winning_stake > 0 THEN
v_dividend := trunc(v_pot / v_winning_stake * 2, 2);
ELSE
v_carried := v_pot;
END IF;

FOR v_bet IN
SELECT * FROM public.bets
WHERE pool_id = v_pool.id AND status = 'PENDING'
ORDER BY created_at
LOOP
IF v_winning_stake > 0 AND public.pool_ticket_matches(v_bet.selections, v_eff) THEN
v_payout := trunc(v_pot * v_bet.amount / v_winning_stake, 2);
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
(race_id, bet_type, winners, dividend, total_staked, winning_bets, total_payout,
pool_total, carry_in, carried_over)
VALUES (p_race_id, p_type, jsonb_build_object('type', p_type, 'legs', v_out_legs),
v_dividend, v_total_staked, v_won, v_total_payout,
v_pot, v_carry_in, v_carried);

UPDATE public.races
SET status = 'settled', betting_open = false, updated_at = now()
WHERE id = p_race_id;

RETURN jsonb_build_object(
'won', v_won,
'lost', v_lost,
'total_payout', v_total_payout,
'pool_total', v_pot,
'carry_in', v_carry_in,
'carried_over', v_carried,
'dividend', v_dividend
);
END;
$function$;

REVOKE ALL ON FUNCTION public.settle_pool_race(uuid, text, jsonb) FROM PUBLIC, anon, authenticated;

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

IF v_type IN ('WTA', 'PICK6') THEN
RETURN public.settle_pool_race(p_race_id, v_type, p_winners);
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

CREATE OR REPLACE FUNCTION public.place_bet(p_race_id uuid, p_bet_type text, p_selections jsonb, p_amount numeric, p_pool_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
v_race public.races%ROWTYPE;
v_pool public.bet_pools%ROWTYPE;
v_pool_id uuid := NULL;
v_balance numeric(14,2);
v_bet public.bets%ROWTYPE;
v_legs jsonb;
v_leg jsonb;
v_horses jsonb;
v_horse text;
v_leg_race int;
v_leg_race_id uuid;
v_leg_open boolean;
v_leg_status text;
v_i int;
v_j int;
v_expected_legs int;
v_pool_legs int := 0;
v_combos bigint := 1;
v_cost numeric(14,2);
BEGIN
IF p_bet_type NOT IN ('FC', 'DD', 'XD', 'DD1', 'WTA', 'PICK6') THEN
RAISE EXCEPTION 'Invalid bet type';
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
v_pool_legs := CASE WHEN p_bet_type = 'WTA' THEN 7 ELSE 6 END;

SELECT * INTO v_race FROM public.races WHERE race_number = v_pool.start_race + v_pool_legs - 1;
IF NOT FOUND THEN
RAISE EXCEPTION '% starting at race % needs races % to % on the card',
p_bet_type, v_pool.start_race, v_pool.start_race, v_pool.start_race + v_pool_legs - 1;
END IF;

v_legs := p_selections->'legs';
IF v_legs IS NULL OR jsonb_typeof(v_legs) <> 'array' OR jsonb_array_length(v_legs) <> v_pool_legs THEN
RAISE EXCEPTION '% needs a pick for each of its % races', p_bet_type, v_pool_legs;
END IF;

FOR v_i IN 0..v_pool_legs - 1 LOOP
v_leg := v_legs->v_i;
v_leg_race := (v_leg->>'race')::int;
IF v_leg_race IS DISTINCT FROM v_pool.start_race + v_i THEN
RAISE EXCEPTION '% must cover races % to % in order', p_bet_type, v_pool.start_race, v_pool.start_race + v_pool_legs - 1;
END IF;

v_horses := v_leg->'horses';
IF v_horses IS NULL OR jsonb_typeof(v_horses) <> 'array' OR jsonb_array_length(v_horses) = 0 THEN
RAISE EXCEPTION 'Pick at least one horse in race %', v_leg_race;
END IF;
IF (SELECT count(DISTINCT h) FROM jsonb_array_elements_text(v_horses) AS h) <> jsonb_array_length(v_horses) THEN
RAISE EXCEPTION 'Race % lists a horse more than once', v_leg_race;
END IF;

SELECT id, betting_open, status INTO v_leg_race_id, v_leg_open, v_leg_status
FROM public.races WHERE race_number = v_leg_race;
IF NOT FOUND THEN
RAISE EXCEPTION 'Race % is not on the card', v_leg_race;
END IF;
IF NOT v_leg_open OR v_leg_status IN ('closed', 'settled') THEN
RAISE EXCEPTION 'Betting is closed for race %', v_leg_race;
END IF;

FOR v_j IN 0..jsonb_array_length(v_horses) - 1 LOOP
v_horse := v_horses->>v_j;
IF NOT EXISTS (
SELECT 1 FROM public.horses
WHERE race_id = v_leg_race_id AND horse_number = v_horse AND NOT scratched
) THEN
RAISE EXCEPTION 'Horse % is not running in race %', v_horse, v_leg_race;
END IF;
END LOOP;

v_combos := v_combos * jsonb_array_length(v_horses);
END LOOP;

v_cost := v_combos * 2;
IF p_amount IS DISTINCT FROM v_cost THEN
RAISE EXCEPTION 'This ticket costs P% (% combinations at P2.00 each)', v_cost, v_combos;
END IF;
ELSE
IF p_amount < 5 THEN
RAISE EXCEPTION 'Minimum bet is 5.00';
END IF;
IF mod(p_amount, 5) <> 0 THEN
RAISE EXCEPTION 'Bet must be in increments of 5.00';
END IF;

SELECT * INTO v_race FROM public.races WHERE id = p_race_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Race not found';
END IF;

IF NOT v_race.betting_open OR v_race.status IN ('closed', 'settled') THEN
RAISE EXCEPTION 'Betting is closed for this race';
END IF;

IF p_bet_type <> 'FC' THEN
v_legs := p_selections->'legs';
v_expected_legs := CASE WHEN p_bet_type = 'DD1' THEN 3 ELSE 2 END;
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
VALUES (auth.uid(), 'BET', p_amount, 'SETTLED', v_bet.id, 'Bet placed: ' || v_bet.ticket_code, now());

RETURN jsonb_build_object(
'bet_id', v_bet.id,
'ticket_code', v_bet.ticket_code,
'amount', v_bet.amount,
'bet_type', v_bet.bet_type,
'status', v_bet.status
);
END;
$function$;
