/*
# WTA becomes a seven-race ticket; Pick 6 stays six races

1. Rules
- A WTA ticket covers seven consecutive races starting from its start race.
  The player picks one winning horse for each of the seven races.
- A Pick 6 ticket covers six consecutive races starting from its start race.
  The player picks one winning horse for each of the six races.
- Both ticket types are recorded on the last race they cover and settle there.
- Every race in the window must be on the card and open for betting.

2. Modified Tables
- `bet_pools`: the start race limit of 1 to 8 is replaced with "1 or higher",
  so starts later on a longer card are allowed. Whether the card has enough
  races is checked when a start is saved and when a bet is placed.

3. Modified Functions
- `place_bet`: WTA now expects seven legs in race order, the same way Pick 6
  expects six. The old single-race WTA window rule is removed.

4. Data
- No WTA or Pick 6 bets exist yet, so no existing ticket changes shape.

5. Security
- No access changes. Policies and grants are unchanged.
*/

ALTER TABLE public.bet_pools DROP CONSTRAINT IF EXISTS bet_pools_start_race_check;
ALTER TABLE public.bet_pools ADD CONSTRAINT bet_pools_start_race_check CHECK (start_race >= 1);

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
v_tx_id uuid;
v_legs jsonb;
v_leg_race int;
v_leg_open boolean;
v_leg_status text;
v_i int;
v_expected_legs int;
v_pool_legs int := 0;
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
v_pool_legs := CASE WHEN p_bet_type = 'WTA' THEN 7 ELSE 6 END;
SELECT * INTO v_race FROM public.races WHERE race_number = v_pool.start_race + v_pool_legs - 1;
IF NOT FOUND THEN
RAISE EXCEPTION '% starting at race % needs races % to % on the card',
p_bet_type, v_pool.start_race, v_pool.start_race, v_pool.start_race + v_pool_legs - 1;
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
WHEN 'WTA' THEN 7
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
IF p_bet_type IN ('WTA', 'PICK6') THEN
FOR v_i IN 0..v_pool_legs - 1 LOOP
IF (v_legs->v_i->>'race')::int <> v_pool.start_race + v_i THEN
RAISE EXCEPTION '% must cover races % to % in order', p_bet_type, v_pool.start_race, v_pool.start_race + v_pool_legs - 1;
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
