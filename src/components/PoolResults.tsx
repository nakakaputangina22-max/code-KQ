import { useEffect, useState } from 'react';
import { supabase, type BetPool, type Race, type RaceResult, type Horse } from '@/lib/supabase';
import { useRaces } from '@/lib/useRaces';
import { Spinner, EmptyState } from '@/components/ui';
import { poolEndRace, poolLegCount, betTypeLabel, betTypeCode, isPoolBetType, type PoolBetType } from '@/lib/betting';
import { Trophy, Layers, TrendingUp, Repeat, Users, ChevronDown, ChevronUp } from 'lucide-react';

interface PoolResultData {
  pool: BetPool;
  result: RaceResult | null;
  legs: { race: Race; horses: Horse[]; winnerHorse: Horse | null }[];
}

export function PoolResults() {
  const { races, horsesByRace, pools, loading } = useRaces();
  const [results, setResults] = useState<RaceResult[]>([]);
  const [resultLoading, setResultLoading] = useState(true);
  const [expanded, setExpanded] = useState<string | null>(null);

  useEffect(() => {
    let active = true;
    supabase.from('race_results').select('*').in('bet_type', ['WTA', 'PICK6']).order('settled_at', { ascending: false })
      .then(({ data }) => {
        if (!active) return;
        setResults((data as RaceResult[]) ?? []);
        setResultLoading(false);
      });
    return () => { active = false; };
  }, []);

  const poolTypes: PoolBetType[] = ['WTA', 'PICK6'];

  const sections = poolTypes.map((type) => {
    const typePools = pools.filter((p) => p.bet_type === type).sort((a, b) => a.start_race - b.start_race);
    const data: PoolResultData[] = typePools.map((pool) => {
      const endRaceNum = poolEndRace(type, pool.start_race);
      const endRace = races.find((r) => r.race_number === endRaceNum);
      const result = endRace ? results.find((r) => r.race_id === endRace.id && r.bet_type === type) ?? null : null;
      const count = poolLegCount(type);
      const legs = Array.from({ length: count }, (_, i) => {
        const raceNum = pool.start_race + i;
        const race = races.find((r) => r.race_number === raceNum);
        const horses = race ? (horsesByRace[race.id] ?? []) : [];
        let winnerHorse: Horse | null = null;
        if (result && race) {
          const legData = (result.winners as any)?.legs?.[i];
          const winnerNums: string[] = legData ? (Array.isArray(legData.horses) ? legData.horses : [legData.horse]) : [];
          winnerHorse = horses.find((h) => winnerNums.includes(String(h.horse_number))) ?? null;
        }
        return { race: race as Race, horses, winnerHorse };
      }).filter((l) => l.race);
      return { pool, result, legs };
    });
    return { type, data };
  });

  if (loading || resultLoading) {
    return <div className="card p-6 flex justify-center"><Spinner className="text-brand-500" /></div>;
  }

  return (
    <div className="space-y-6">
      {sections.map((section) => (
        <div key={section.type}>
          <div className="flex items-center gap-2 mb-3 px-1">
            <Layers className="w-4 h-4 text-brand-400" />
            <h2 className="text-sm font-bold text-ink-200 uppercase tracking-wide">{betTypeLabel(section.type)} Results</h2>
            <span className="chip bg-brand-500/15 text-brand-300 font-mono text-[10px]">{betTypeCode(section.type)}</span>
          </div>

          {section.data.length === 0 ? (
            <div className="card">
              <EmptyState icon={Trophy} title={`No ${betTypeLabel(section.type)} pools yet`} hint="Results will appear here once a pool is settled." />
            </div>
          ) : (
            <div className="space-y-3">
              {section.data.map((item) => {
                const key = `${section.type}-${item.pool.id}`;
                const isOpen = expanded === key;
                const hasResult = item.result !== null;
                const carriedOver = item.result ? Number(item.result.carried_over) > 0 : false;
                return (
                  <div
                    key={key}
                    className={`card overflow-hidden animate-slide-up ${hasResult ? 'animate-winner-glow' : ''}`}
                  >
                    <button
                      onClick={() => setExpanded(isOpen ? null : key)}
                      className="w-full flex items-center justify-between px-4 py-3"
                    >
                      <div className="flex items-center gap-3 min-w-0">
                        <div className={`w-10 h-10 rounded-xl flex items-center justify-center shrink-0 ${hasResult ? 'bg-brand-500/15 text-brand-400' : 'bg-ink-800 text-ink-500'}`}>
                          <Trophy className="w-5 h-5" />
                        </div>
                        <div className="min-w-0 text-left">
                          <p className="text-sm font-bold text-white">
                            Starts Race {item.pool.start_race}
                          </p>
                          <p className="text-xs text-ink-500">
                            {poolLegCount(section.type)} legs · settles on race {poolEndRace(section.type, item.pool.start_race)}
                          </p>
                        </div>
                      </div>
                      <div className="flex items-center gap-2 shrink-0">
                        {hasResult ? (
                          <span className="chip bg-success-100 text-success-700 text-[10px]">SETTLED</span>
                        ) : (
                          <span className="chip bg-warning-100 text-warning-600 text-[10px]">PENDING</span>
                        )}
                        {isOpen ? <ChevronUp className="w-4 h-4 text-ink-400" /> : <ChevronDown className="w-4 h-4 text-ink-400" />}
                      </div>
                    </button>

                    {isOpen && (
                      <div className="px-4 pb-4 space-y-3 animate-fade-in">
                        {/* Leg-by-leg breakdown */}
                        <div className="space-y-2">
                          <p className="text-[11px] font-bold text-ink-400 uppercase tracking-wide">Leg Results</p>
                          {item.legs.map((leg, idx) => (
                            <div
                              key={idx}
                              className="flex items-center gap-3 rounded-lg bg-ink-950/60 border border-ink-800 px-3 py-2 animate-leg-reveal"
                              style={{ animationDelay: `${idx * 60}ms` }}
                            >
                              <span className="w-6 h-6 rounded-md bg-brand-500/15 text-brand-300 text-[10px] font-bold flex items-center justify-center shrink-0">
                                {idx + 1}
                              </span>
                              <span className="text-xs text-ink-500 shrink-0">R{leg.race?.race_number}</span>
                              <div className="min-w-0 flex-1">
                                {leg.winnerHorse ? (
                                  <p className="text-sm text-white truncate">
                                    <span className="font-mono font-bold text-brand-300">#{leg.winnerHorse.horse_number}</span>
                                    {' '}{leg.winnerHorse.horse_name || `Horse ${leg.winnerHorse.horse_number}`}
                                  </p>
                                ) : hasResult ? (
                                  <p className="text-sm text-ink-500">Winner determined by fallback</p>
                                ) : (
                                  <p className="text-sm text-ink-600">Not settled yet</p>
                                )}
                              </div>
                              {leg.winnerHorse && (
                                <Trophy className="w-3.5 h-3.5 text-amber-400 shrink-0" />
                              )}
                            </div>
                          ))}
                        </div>

                        {/* Pool stats */}
                        {hasResult && item.result && (
                          <div className="grid grid-cols-2 gap-2 pt-1">
                            <PoolStat icon={TrendingUp} label="Pool Total" value={`₱${Number(item.result.pool_total).toFixed(2)}`} tone="brand" />
                            <PoolStat icon={Repeat} label="Carried In" value={`₱${Number(item.result.carry_in).toFixed(2)}`} tone="accent" />
                            <PoolStat icon={Users} label="Winning Tickets" value={String(item.result.winning_bets)} tone="success" />
                            <PoolStat icon={Trophy} label="Total Paid Out" value={`₱${Number(item.result.total_payout).toFixed(2)}`} tone="success" />
                          </div>
                        )}

                        {/* Carryover banner */}
                        {carriedOver && item.result && (
                          <div className="rounded-xl border border-accent-500/30 bg-accent-500/10 px-4 py-3 text-center animate-bounce-in">
                            <p className="text-sm font-bold animate-carryover">
                              ₱{Number(item.result.carried_over).toFixed(2)} carried over to the next {betTypeLabel(section.type)} start
                            </p>
                          </div>
                        )}

                        {hasResult && item.result && item.result.winning_bets > 0 && (
                          <div className="rounded-xl border border-success-500/20 bg-success-500/5 px-4 py-2.5 text-center">
                            <p className="text-xs text-success-600">
                              {item.result.winning_bets} winning {item.result.winning_bets === 1 ? 'ticket' : 'tickets'} ·
                              {' '}₱{Number(item.result.total_payout).toFixed(2)} total payout
                            </p>
                          </div>
                        )}
                      </div>
                    )}
                  </div>
                );
              })}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

function PoolStat({ icon: Icon, label, value, tone }: { icon: any; label: string; value: string; tone: 'brand' | 'accent' | 'success' }) {
  const color = tone === 'brand' ? 'text-brand-400' : tone === 'accent' ? 'text-accent-400' : 'text-success-400';
  return (
    <div className="rounded-lg bg-ink-950/60 border border-ink-800 px-3 py-2">
      <div className="flex items-center gap-1.5">
        <Icon className={`w-3.5 h-3.5 ${color}`} />
        <span className="text-[10px] text-ink-500 uppercase tracking-wide font-semibold">{label}</span>
      </div>
      <p className={`text-sm font-bold font-mono mt-1 ${color}`}>{value}</p>
    </div>
  );
}
