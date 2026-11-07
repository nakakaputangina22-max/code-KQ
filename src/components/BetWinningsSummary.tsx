import type { Bet } from '@/lib/supabase';
import { BET_TYPES, betTypeCode, winningsByBetType } from '@/lib/betting';
import { Money } from '@/components/ui';

export function BetWinningsSummary({ bets }: { bets: Bet[] }) {
  const totals = winningsByBetType(bets);

  return (
    <section className="card p-4">
      <h2 className="text-sm font-bold text-white">Winnings by bet type</h2>
      <p className="text-xs text-ink-500 mt-0.5">Each bet type is counted separately.</p>
      <div className="mt-3 divide-y divide-ink-800">
        {BET_TYPES.map((info) => {
          const entry = totals[info.type];
          return (
            <div key={info.type} className="flex items-center gap-3 py-2.5">
              <span className="chip bg-ink-800 text-ink-300 font-mono text-[10px] shrink-0">{betTypeCode(info.type)}</span>
              <div className="min-w-0 flex-1">
                <p className="text-sm text-white">{info.label}</p>
                <p className="text-[11px] text-ink-500">
                  ₱{entry.staked.toFixed(2)} staked · {entry.winningBets} won · {entry.pendingBets} pending
                </p>
              </div>
              <Money value={entry.won} className="text-success-600 font-bold text-sm" />
            </div>
          );
        })}
      </div>
    </section>
  );
}
