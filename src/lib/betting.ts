import type { Bet, BetPool, BetType, Race, Horse } from '@/lib/supabase';

/**
 * Coupled-entry helpers.
 * In Philippine horse racing, a coupled entry is two horses running as one
 * betting unit (e.g. #1 and #1A). When a user selects one, the partner is
 * auto-selected. The convention is: "1" pairs with "1A", "2" with "2A", etc.
 * A horse with a letter suffix (e.g. "1A") pairs with its base number ("1").
 */

/** Extracts the base number (e.g. "1A" → "1", "3" → "3"). */
export function horseBaseNumber(horseNumber: string): string {
  const match = String(horseNumber).trim().match(/^(\d+)/);
  return match ? match[1] : String(horseNumber).trim();
}

/** True if this horse has a letter suffix (e.g. "1A"). */
export function isCoupledEntry(horseNumber: string): boolean {
  return /[A-Za-z]/.test(String(horseNumber).trim());
}

/**
 * Given a horse number and the full horse list for a race, returns the
 * partner number for a coupled entry (e.g. "1" → "1A" if "1A" exists in the
 * race). Returns null if there is no coupled partner.
 */
export function getCoupledPartner(
  horseNumber: string,
  horses: Horse[],
): string | null {
  const num = String(horseNumber).trim();
  if (isCoupledEntry(num)) {
    // This IS the letter-suffixed horse — partner is the base number.
    const base = horseBaseNumber(num);
    return horses.some((h) => String(h.horse_number).trim() === base) ? base : null;
  }
  // This is a plain number — partner is "<base>A" if that exists.
  const partner = `${num}A`;
  return horses.some((h) => String(h.horse_number).trim() === partner) ? partner : null;
}

/**
 * Bet availability engine.
 *
 *   FC, DD, XD, DD+1 — race-based: each needs the races it covers to exist on the card.
 *   WTA   — a pool set by the admin. It starts on its start race and covers seven
 *           consecutive races. Bets are placed from the start race and settle on the
 *           last of the seven races.
 *   PICK6 — a pool set by the admin. It starts on its start race and covers six
 *           consecutive races. Bets are placed from the start race and settle on the
 *           last of the six races.
 */

export interface BetTypeInfo {
  type: BetType;
  code: string;
  label: string;
  short: string;
  description: string;
}

export const BET_TYPES: BetTypeInfo[] = [
  {
    type: 'FC',
    code: 'FC',
    label: 'Forecast',
    short: 'FC',
    description: 'Pick the 1st and 2nd place horses in exact order for a single race.',
  },
  {
    type: 'DD',
    code: 'DD',
    label: 'Daily Double',
    short: 'DD',
    description: 'Pick the winner of 2 consecutive designated races.',
  },
  {
    type: 'XD',
    code: 'XD',
    label: 'Extra Double',
    short: 'XD',
    description: 'Pick the winner of 2 specific non-consecutive designated races.',
  },
  {
    type: 'DD1',
    code: 'DD+1',
    label: 'Daily Double + 1',
    short: 'DD+1',
    description: 'Pick the winner of 2 consecutive races PLUS 1 extra designated race.',
  },
  {
    type: 'WTA',
    code: 'WTA',
    label: 'Winner-Take-All',
    short: 'WTA',
    description: 'Pick the winning horse in each of seven consecutive races, starting from an open WTA start race.',
  },
  {
    type: 'PICK6',
    code: 'PICK 6',
    label: 'Pick 6',
    short: 'PICK 6',
    description: 'Pick the winning horse in each of six consecutive races, starting from an open Pick 6 start race.',
  },
];

export const WTA_LEG_COUNT = 7;
export const PICK6_LEG_COUNT = 6;

/** Races needed beyond the current race for each race-based bet type. */
const LEGS_AFTER: Record<'FC' | 'DD' | 'XD' | 'DD1', number> = {
  FC: 0,   // single race
  DD: 1,   // current + next
  XD: 2,   // current + the race two slots ahead
  DD1: 2,  // current + next + one extra
};

export type PoolBetType = 'WTA' | 'PICK6';

export function isPoolBetType(type: BetType): type is PoolBetType {
  return type === 'WTA' || type === 'PICK6';
}

/** How many consecutive races a WTA or Pick 6 covers, starting from its start race. */
export function poolLegCount(type: PoolBetType): number {
  return type === 'WTA' ? WTA_LEG_COUNT : PICK6_LEG_COUNT;
}

/** The last race a WTA or Pick 6 starting on this race covers. Bets settle on it. */
export function poolEndRace(type: PoolBetType, startRace: number): number {
  return startRace + poolLegCount(type) - 1;
}

/** The pool a WTA or PICK 6 bet started on this race belongs to, or null when none applies. */
export function findBetPool(type: PoolBetType, raceNumber: number, pools: BetPool[]): BetPool | null {
  return pools.find((p) => p.bet_type === type && p.start_race === raceNumber) ?? null;
}

function raceNumberSet(races: Race[]): Set<number> {
  return new Set(races.map((race) => race.race_number));
}

function isBetTypeOffered(type: BetType, raceNumber: number, numbers: Set<number>, pools: BetPool[]): boolean {
  if (isPoolBetType(type)) {
    if (findBetPool(type, raceNumber, pools) === null) return false;
    return Array.from({ length: poolLegCount(type) }, (_, index) => numbers.has(raceNumber + index)).every(Boolean);
  }
  const needed = LEGS_AFTER[type];
  return Array.from({ length: needed + 1 }, (_, index) => numbers.has(raceNumber + index)).every(Boolean);
}

/** Bet types a player can place with this race as the starting race. */
export function availableBetTypes(raceNumber: number, races: Race[], pools: BetPool[]): BetType[] {
  const numbers = raceNumberSet(races);
  return BET_TYPES.map((info) => info.type).filter((type) => isBetTypeOffered(type, raceNumber, numbers, pools));
}

/**
 * Bet types an admin can settle from this race. WTA and Pick 6 settle on their last
 * race, so they are offered when a pool starts that many races earlier.
 */
export function settlementBetTypes(raceNumber: number, races: Race[], pools: BetPool[]): BetType[] {
  const numbers = raceNumberSet(races);
  return BET_TYPES.map((info) => info.type).filter((type) =>
    isPoolBetType(type)
      ? isBetTypeOffered(type, raceNumber - poolLegCount(type) + 1, numbers, pools)
      : isBetTypeOffered(type, raceNumber, numbers, pools),
  );
}

/** Race numbers on the card where a bet type can be started, in order. */
export function eligibleRaceNumbers(type: BetType, races: Race[], pools: BetPool[]): number[] {
  return races
    .map((race) => race.race_number)
    .filter((raceNumber) => availableBetTypes(raceNumber, races, pools).includes(type))
    .sort((a, b) => a - b);
}

/** Compact race list, e.g. "1–7" for a run of consecutive races or "1, 3, 5" otherwise. */
export function formatRaceNumbers(numbers: number[]): string {
  if (numbers.length === 0) return '';
  const consecutive = numbers.every((n, i) => n === numbers[0] + i);
  if (consecutive && numbers.length > 1) return `${numbers[0]}–${numbers[numbers.length - 1]}`;
  return numbers.join(', ');
}

/**
 * For combination bet types (DD, XD, DD1, WTA, PICK6), returns the leg races the user
 * must pick winners for. For FC, returns just the current race (twice, for
 * 1st and 2nd place picks in that same race).
 */
export function getBetLegs(
  type: BetType,
  currentRace: Race,
  allRaces: Race[],
): Race[] {
  if (type === 'FC') {
    return [currentRace, currentRace];
  }
  const sorted = [...allRaces].sort((a, b) => a.race_number - b.race_number);
  if (isPoolBetType(type)) {
    const count = poolLegCount(type);
    const legs = sorted.filter((race) =>
      race.race_number >= currentRace.race_number && race.race_number < currentRace.race_number + count,
    );
    return legs.length === count ? legs : [];
  }
  const idx = sorted.findIndex((r) => r.id === currentRace.id);
  if (idx === -1) return [];

  const required = type === 'DD'
    ? [0, 1]
    : type === 'XD'
      ? [0, 2]
      : [0, 1, 2];
  for (const offset of required) {
    const race = sorted[idx + offset];
    if (!race || race.race_number !== currentRace.race_number + offset) return [];
  }
  return required.map((offset) => sorted[idx + offset]) as Race[];
}

export interface BetTypeTotals {
  staked: number;
  won: number;
  winningBets: number;
  pendingBets: number;
}

/** Totals per bet type, so each type (WTA and PICK 6 included) is tracked on its own. */
export function winningsByBetType(bets: Bet[]): Record<BetType, BetTypeTotals> {
  const totals = Object.fromEntries(
    BET_TYPES.map((info) => [info.type, { staked: 0, won: 0, winningBets: 0, pendingBets: 0 }]),
  ) as Record<BetType, BetTypeTotals>;
  for (const bet of bets) {
    const entry = totals[bet.bet_type];
    if (!entry) continue;
    entry.staked += Number(bet.amount);
    if (bet.status === 'WON') {
      entry.won += Number(bet.payout_amount);
      entry.winningBets += 1;
    }
    if (bet.status === 'PENDING') entry.pendingBets += 1;
  }
  return totals;
}

export function betTypeLabel(type: BetType): string {
  return BET_TYPES.find((b) => b.type === type)?.label ?? type;
}

export function betTypeCode(type: BetType): string {
  return BET_TYPES.find((b) => b.type === type)?.code ?? type;
}

/** Price of one WTA or Pick 6 combination. */
export const POOL_UNIT_PRICE = 2;

export interface PoolLegSelection {
  race: number;
  horses: string[];
}

/** Number of combinations in a WTA or Pick 6 ticket: the product of horses picked per leg. */
export function poolCombinationCount(legs: PoolLegSelection[]): number {
  if (legs.length === 0) return 0;
  return legs.reduce((total, leg) => total * leg.horses.length, 1);
}

/** Cost of a WTA or Pick 6 ticket: combinations × ₱2. */
export function poolTicketCost(legs: PoolLegSelection[]): number {
  return poolCombinationCount(legs) * POOL_UNIT_PRICE;
}

/** Builds a human-readable summary of a bet's selections. */
export function describeSelections(betType: BetType, selections: any): string {
  if (!selections) return '';
  if (betType === 'FC') {
    return `1st: #${selections.first} / 2nd: #${selections.second}`;
  }
  const legs: any[] = selections.legs ?? [];
  return legs
    .map((l) => {
      const horses: string[] = Array.isArray(l.horses) ? l.horses : [l.horse];
      return `R${l.race} → ${horses.map((h) => `#${h}`).join(' / ')}`;
    })
    .join('  ·  ');
}
