import { useEffect, useMemo, useState } from 'react';
import { useRaces } from '@/lib/useRaces';
import { supabase, type BetType, type Race, type RaceResult } from '@/lib/supabase';
import { Spinner, StatusBadge, EmptyState } from '@/components/ui';
import { betTypeCode, betTypeLabel, describeSelections, isPoolBetType } from '@/lib/betting';
import { Trophy } from 'lucide-react';

const CORE_TYPES: BetType[] = ['FC', 'DD', 'XD', 'DD1'];
const OPTIONAL_TYPES: BetType[] = ['WTA', 'PICK6'];

export function RaceResults({ raceId }: { raceId?: string }) {
  const { races, loading: racesLoading } = useRaces();
  const [results, setResults] = useState<RaceResult[]>([]);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    let active = true;
    supabase.from('race_results').select('*').then(({ data, error }) => {
      if (!active) return;
      setFailed(Boolean(error));
      setResults(error ? [] : ((data as RaceResult[]) ?? []));
      setLoading(false);
    });
    return () => { active = false; };
  }, [races]);

  const visible = useMemo(
    () => [...races]
      .filter((race) => !raceId || race.id === raceId)
      .sort((a, b) => a.race_number - b.race_number),
    [races, raceId],
  );

  if (racesLoading || loading) {
    return <div className="card p-6 flex justify-center"><Spinner className="text-brand-500" /></div>;
  }
  if (failed) {
    return <div className="card p-4 text-sm text-danger-700">Race results could not be loaded. Please refresh the page.</div>;
  }
  if (visible.length === 0) {
    return (
      <div className="card">
        <EmptyState icon={Trophy} title="No races yet" hint="Race results will appear here once races are set up and settled." />
      </div>
    );
  }

  return (
    <div className="space-y-3">
      {visible.map((race) => (
        <RaceResultCard key={race.id} race={race} results={results.filter((r) => r.race_id === race.id)} />
      ))}
    </div>
  );
}

function RaceResultCard({ race, results }: { race: Race; results: RaceResult[] }) {
  const byType = new Map(results.map((r) => [r.bet_type, r]));
  const rowTypes = [...CORE_TYPES, ...OPTIONAL_TYPES.filter((t) => byType.has(t))];

  return (
    <div className="card overflow-hidden">
      <div className="flex items-center justify-between px-4 py-3 border-b border-ink-800">
        <p className="text-sm font-bold text-white">Race {race.race_number}</p>
        <StatusBadge status={race.status} />
      </div>
      <div className="divide-y divide-ink-800">
        {rowTypes.map((type) => (
          <ResultRow key={type} type={type} result={byType.get(type)} />
        ))}
      </div>
    </div>
  );
}

function ResultRow({ type, result }: { type: BetType; result?: RaceResult }) {
  return (
    <div className="px-4 py-3 flex items-start gap-3">
      <span className="chip bg-ink-800 text-ink-300 font-mono text-[10px] shrink-0">{betTypeCode(type)}</span>
      <div className="min-w-0 flex-1">
        <p className="text-xs text-ink-500">{betTypeLabel(type)}</p>
        {result ? (
          <>
            <p className="text-sm text-white mt-0.5">{describeSelections(type, result.winners)}</p>
            {isPoolBetType(type) ? (
              <>
                <p className="text-[11px] text-ink-500 mt-0.5">
                  Pool ₱{Number(result.pool_total).toFixed(2)} · Carried in ₱{Number(result.carry_in).toFixed(2)} · {result.winning_bets} winning {result.winning_bets === 1 ? 'ticket' : 'tickets'} · ₱{Number(result.total_payout).toFixed(2)} paid out
                </p>
                <p className="text-[11px] text-ink-500 mt-0.5">
                  {Number(result.carried_over) > 0
                    ? `₱${Number(result.carried_over).toFixed(2)} carried over to the next ${betTypeLabel(type)} start`
                    : 'Fully paid out, nothing carried over'}
                </p>
              </>
            ) : (
              <p className="text-[11px] text-ink-500 mt-0.5">
                ₱{Number(result.dividend).toFixed(2)} per ₱5 · {result.winning_bets} winning {result.winning_bets === 1 ? 'ticket' : 'tickets'} · ₱{Number(result.total_payout).toFixed(2)} paid out
              </p>
            )}
          </>
        ) : (
          <p className="text-xs text-ink-500 mt-0.5">Not settled yet</p>
        )}
      </div>
    </div>
  );
}
