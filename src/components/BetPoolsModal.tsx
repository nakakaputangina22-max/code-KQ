import { useState } from 'react';
import { Modal } from '@/components/Modal';
import { supabase, type BetPool, type Race } from '@/lib/supabase';
import { useToast } from '@/lib/toast';
import { formatRaceNumbers, poolEndRace } from '@/lib/betting';
import { Plus, Trash2, Loader2 } from 'lucide-react';

type PoolType = BetPool['bet_type'];

const SECTIONS: { type: PoolType; title: string; hint: string }[] = [
  {
    type: 'WTA',
    title: 'WTA starting races',
    hint: 'Each WTA covers seven races in a row from its start race and settles on the seventh.',
  },
  {
    type: 'PICK6',
    title: 'PICK 6 starting races',
    hint: 'Each PICK 6 covers six races in a row from its start race and settles on the sixth.',
  },
];

interface BetPoolsModalProps {
  open: boolean;
  onClose: () => void;
  races: Race[];
  pools: BetPool[];
  onChanged: () => Promise<void>;
}

export function BetPoolsModal({ open, onClose, races, pools, onChanged }: BetPoolsModalProps) {
  return (
    <Modal open={open} onClose={onClose} title="WTA & PICK 6 Starting Races" size="lg">
      <div className="space-y-6">
        {SECTIONS.map((section) => (
          <PoolSection
            key={section.type}
            type={section.type}
            title={section.title}
            hint={section.hint}
            races={races}
            pools={pools}
            onChanged={onChanged}
          />
        ))}
      </div>
    </Modal>
  );
}

function PoolSection({
  type, title, hint, races, pools, onChanged,
}: {
  type: PoolType;
  title: string;
  hint: string;
  races: Race[];
  pools: BetPool[];
  onChanged: () => Promise<void>;
}) {
  const { notify } = useToast();
  const [input, setInput] = useState('');
  const [busy, setBusy] = useState(false);
  const typeLabel = poolTypeLabel(type);

  const rows = pools
    .filter((p) => p.bet_type === type)
    .sort((a, b) => a.start_race - b.start_race);
  const lastRace = races.reduce((max, r) => Math.max(max, r.race_number), 0);

  function coverage(pool: BetPool): string {
    const end = poolEndRace(type, pool.start_race);
    return `Races ${formatRaceNumbers(rangeOf(pool.start_race, end))}, settles on race ${end}`;
  }

  async function addStart() {
    const start = Number(input);
    const problem = poolStartProblem(type, start, races, pools);
    if (problem) { notify(problem, 'error'); return; }
    setBusy(true);
    const { data, error } = await supabase
      .from('bet_pools')
      .insert({ bet_type: type, start_race: start })
      .select('id');
    setBusy(false);
    if (error) { notify(error.message, 'error'); return; }
    if (!data || data.length === 0) {
      notify('The starting race was not saved. Make sure you are signed in as an administrator.', 'error');
      return;
    }
    setInput('');
    notify(`${typeLabel} now starts on race ${start}`, 'success');
    await onChanged();
  }

  async function removeStart(pool: BetPool) {
    if (!confirm(`Remove the ${typeLabel} starting on race ${pool.start_race}? Bets already placed on it stay in place.`)) return;
    setBusy(true);
    const { data, error } = await supabase.from('bet_pools').delete().eq('id', pool.id).select('id');
    setBusy(false);
    if (error) { notify(error.message, 'error'); return; }
    if (!data || data.length === 0) {
      notify('That starting race could not be removed. Make sure you are signed in as an administrator.', 'error');
      return;
    }
    notify('Starting race removed', 'success');
    await onChanged();
  }

  return (
    <section className="space-y-3">
      <div>
        <h3 className="text-sm font-bold text-white">{title}</h3>
        <p className="text-xs text-ink-500 mt-1">{hint}</p>
      </div>

      {rows.length === 0 ? (
        <p className="text-xs text-ink-500 rounded-xl border border-dashed border-ink-800 px-4 py-3">
          No starting races yet. Players cannot place {typeLabel} bets until you add one.
        </p>
      ) : (
        <ul className="divide-y divide-ink-800 rounded-xl border border-ink-800 bg-ink-950">
          {rows.map((pool) => (
            <li key={pool.id} className="flex items-center gap-3 px-4 py-2.5">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-semibold text-white">Starts on race {pool.start_race}</p>
                <p className="text-xs text-ink-500">{coverage(pool)}</p>
              </div>
              <button
                onClick={() => removeStart(pool)}
                disabled={busy}
                aria-label={`Remove start race ${pool.start_race}`}
                className="btn-ghost p-2 text-danger-500"
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </li>
          ))}
        </ul>
      )}

      <div className="flex items-end gap-2">
        <div className="flex-1">
          <label className="label" htmlFor={`pool-start-${type}`}>Starting race number</label>
          <input
            id={`pool-start-${type}`}
            type="number"
            min={1}
            max={lastRace || undefined}
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={lastRace ? `1 to ${lastRace}` : 'Race number'}
            className="input"
          />
        </div>
        <button onClick={addStart} disabled={busy || input.trim() === ''} className="btn-accent">
          {busy ? <Loader2 className="w-4 h-4 animate-spin" /> : <Plus className="w-4 h-4" />}
          Add start
        </button>
      </div>
    </section>
  );
}

export function poolTypeLabel(type: PoolType): string {
  return type === 'PICK6' ? 'PICK 6' : 'WTA';
}

export function poolStartProblem(type: PoolType, start: number, races: Race[], pools: BetPool[]): string | null {
  const raceNumbers = new Set(races.map((r) => r.race_number));
  const label = poolTypeLabel(type);
  if (!Number.isInteger(start) || start < 1) return 'Enter a race number from 1 up.';
  if (!raceNumbers.has(start)) return `Race ${start} is not on the card yet.`;
  if (pools.some((p) => p.bet_type === type && p.start_race === start)) return `A ${label} already starts on race ${start}.`;
  const end = poolEndRace(type, start);
  if (!rangeOf(start, end).every((n) => raceNumbers.has(n))) {
    return `A ${label} from race ${start} needs races ${start} to ${end} on the card.`;
  }
  return null;
}

function rangeOf(start: number, end: number): number[] {
  return Array.from({ length: Math.max(0, end - start + 1) }, (_, i) => start + i);
}
