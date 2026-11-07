/**
 * Animated live background with floating, color-shifting orbs.
 * Renders behind all content at z-0; pointer-events disabled so it never
 * blocks taps on mobile.
 */
export function AnimatedBackground() {
  return (
    <div className="fixed inset-0 -z-10 overflow-hidden pointer-events-none">
      {/* Base gradient that slowly shifts hue */}
      <div className="absolute inset-0 bg-ink-950 animate-hue-rotate" />

      {/* Floating orbs with different drift paths and colors */}
      <div className="absolute top-[8%] left-[10%] w-72 h-72 rounded-full bg-brand-500/12 blur-[80px] animate-orb-1" />
      <div className="absolute top-[55%] left-[60%] w-80 h-80 rounded-full bg-accent-500/10 blur-[90px] animate-orb-2" />
      <div className="absolute top-[75%] left-[15%] w-64 h-64 rounded-full bg-emerald-500/8 blur-[70px] animate-orb-3" />
      <div className="absolute top-[20%] left-[75%] w-72 h-72 rounded-full bg-rose-500/8 blur-[80px] animate-orb-1" style={{ animationDelay: '4s' }} />
      <div className="absolute top-[40%] left-[35%] w-56 h-56 rounded-full bg-amber-500/8 blur-[60px] animate-orb-2" style={{ animationDelay: '6s' }} />

      {/* Subtle moving grid overlay */}
      <div
        className="absolute inset-0 opacity-[0.025]"
        style={{
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.5) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.5) 1px, transparent 1px)',
          backgroundSize: '48px 48px',
        }}
      />
    </div>
  );
}
