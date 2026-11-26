import { bladeDurations } from './blade-atlas.js';

// Coordinates are normalized to the playable surface, including its physical QWERTY stagger.
export const keys = new Map();
for (const [row, letters] of ['QWERTYUIOP', 'ASDFGHJKL;', 'ZXCVBNM,./'].entries()) {
  const punctuation = { ';': 'Semicolon', ',': 'Comma', '.': 'Period', '/': 'Slash' };
  [...letters].forEach((label, col) =>
    keys.set(punctuation[label] || 'Key' + label, {
      label,
      x: 0.085 + [0, 0.024, 0.062][row] + col * 0.0855,
      y: [0.26, 0.5, 0.74][row],
    }),
  );
}
// The outer anchors follow their keyboard rows. Space owns the thumb row.
for (const [code, label, x, y] of [
  ['Tab', '⇥', 0.032, 0.26],
  ['Backslash', '\\', 0.951, 0.26],
  ['CapsLock', '⇪', 0.043, 0.5],
  ['Enter', '↵', 0.955, 0.5],
  ['ShiftLeft', '⇧', 0.058, 0.74],
  ['ShiftRight', '⇧', 0.966, 0.74],
])
  keys.set(code, { label, x, y });
keys.set('Space', { label: 'Space', x: 0.5, y: 0.905 });
export const blades = [
  ['Plasma Katana', '#43e3ff', '#aa57ff'],
  ['Inferno Dragon', '#ff711f', '#ffdb44'],
  ['Frostbite', '#94eaff', '#4196ff'],
  ['Sakura Wind', '#ff80af', '#ffd7ea'],
  ['Thunder God', '#a0caff', '#f1f5ff'],
  ['Void Rift', '#ac51ff', '#ff4da4'],
  ['Rainbow Prism', '#fc5ed0', '#50f4de'],
  ['Shadow Ink', '#e2ba60', '#373337'],
  ['Foil Glow', '#48dada', '#ffdf45'],
  ['Plasma Braid', '#43e3ff', '#aa57ff'],
];
export const themes = {
  fruit: {
    name: 'Fruit',
    stems: ['MoonGarden', 'FestivalDrums'],
    colors: ['#f4484d', '#ffa826', '#9ccc39', '#ff5368', '#ffe15b', '#ff4d91'],
  },
  vegetables: {
    name: 'Veggie',
    stems: ['PeaPatch', 'GardenShakers'],
    colors: ['#91ca39', '#ff9025', '#c166dc', '#ff423e', '#58b65f', '#f57b9d'],
  },
  gadgets: {
    name: 'Gadget',
    stems: ['PocketArcade', 'ClockPulses'],
    colors: ['#32e5db', '#ff913c', '#bf7cff', '#ff5fb7', '#ffcb40', '#55eabb'],
  },
};
const radii = [0.069, 0.055, 0.05, 0.047, 0.049, 0.061, 0.06, 0.06, 0.06, 0.057, 0.047];
const random = (min, max) => min + Math.random() * (max - min);
export const blastDuration = 0.56;
const bombGap = () => 8 + Math.floor(Math.random() * 7);
const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
function boundedPush(list, item, limit) {
  list.push(item);
  if (list.length > limit) list.splice(0, list.length - limit);
}
export function hits(a, b, obj, aspect) {
  const dx = (b.x - a.x) * aspect,
    dy = b.y - a.y,
    ox = (obj.x - a.x) * aspect,
    oy = obj.y - a.y;
  const t = clamp((ox * dx + oy * dy) / (dx * dx + dy * dy || 1), 0, 1);
  return Math.hypot(ox - t * dx, oy - t * dy) <= obj.r * Math.min(1, aspect) * 1.12;
}
export class Game {
  constructor(notify = () => {}) {
    this.notify = notify;
    this.aspect = 1.6;
    this.theme = 'fruit';
    this.blade = 0;
    this.mode = 'classic';
    this.reset();
    this.phase = 'title';
  }
  reset() {
    this.time = 0;
    this.score = 0;
    this.lives = 3;
    this.remaining = this.mode === 'zen' ? 90 : 60;
    this.fruits = [];
    this.halves = [];
    this.drops = [];
    this.stains = [];
    this.trails = [];
    this.labels = [];
    this.held = [];
    this.tip = null;
    this.sliced = 0;
    this.bestCombo = 0;
    this.combo = 0;
    this.comboUntil = -1;
    this.heat = 0;
    this.blast = null;
    this.wave = 0;
    this.nextWave = 0.35;
    this.bombWave = bombGap();
    this.frenzy = 0;
    this.freeze = 0;
    this.double = 0;
    this.extraAt = 0;
  }
  start() {
    this.reset();
    this.phase = 'playing';
    this.notify('state');
  }
  pause() {
    if (this.phase === 'playing') {
      this.phase = 'paused';
      this.held = [];
      this.notify('state');
    }
  }
  resume() {
    if (this.phase === 'paused') {
      this.phase = 'playing';
      this.notify('state');
    }
  }
  end() {
    this.phase = this.blast ? 'exploding' : 'over';
    this.held = [];
    this.notify('state');
  }
  down(code) {
    const pos = keys.get(code);
    if (!pos || this.phase !== 'playing' || this.held.includes(code)) return;
    const anchor = keys.get(this.held.at(-1));
    this.held.push(code);
    this.tip = pos;
    if (anchor) this.cut(anchor, pos);
  }
  up(code) {
    const index = this.held.indexOf(code);
    if (index < 0) return;
    this.held.splice(index, 1);
    this.tip = keys.get(this.held.at(-1)) || this.tip;
  }
  label(text, pos, color = '#ffdb7d') {
    boundedPush(
      this.labels,
      { text, x: clamp(pos.x, 0.12, 0.88), y: clamp(pos.y, 0.1, 0.91), color, born: this.time },
      12,
    );
  }
  spawn(kind, edge = false) {
    const x = edge ? (Math.random() < 0.5 ? 0.02 : 0.98) : random(0.14, 0.86);
    const y = edge ? random(0.68, 0.9) : 1.06,
      apex = random(0.16, 0.52);
    const dest = edge ? random(0.36, 0.65) : clamp(x + random(-0.19, 0.19), 0.16, 0.84);
    const vy = -Math.sqrt(1.84 * Math.max(0.22, y - apex));
    this.fruits.push({
      kind,
      x,
      y,
      vx: (dest - x) / (-vy / 0.92),
      vy,
      rot: random(0, 6.28),
      spin: random(-2.2, 2.2),
      r: radii[kind],
    });
  }
  spawnWave() {
    const difficulty = Math.min(1, ++this.wave / 22);
    const count = Math.min(6, 1 + Math.floor(difficulty * 3.5) + Math.floor(random(0, 2.6)));
    for (let i = 0; i < count; i++) {
      const roll = Math.random();
      this.spawn(
        this.mode === 'arcade' && roll < 0.15
          ? 6 + Math.floor(random(0, 3))
          : roll > 0.955
            ? 9
            : Math.floor(random(0, 6)),
      );
    }
    if (this.mode !== 'zen' && this.wave >= this.bombWave) {
      this.spawn(10);
      this.bombWave = this.wave + bombGap();
    }
    this.nextWave = this.time + Math.max(0.95, (2.25 - difficulty * 0.95) * random(0.85, 1.15));
  }
  cut(a, b) {
    boundedPush(this.trails, { a, b, blade: this.blade, born: this.time, seed: Math.random() * 10 }, 10);
    this.sliceSegment(a, b);
  }
  sliceSegment(a, b) {
    const before = this.score;
    let boost = 0;
    const angle = Math.atan2(b.y - a.y, (b.x - a.x) * this.aspect);
    this.notify('swipe');
    const struck = this.fruits.filter((f) => hits(a, b, f, this.aspect));
    if (!struck.length) return;
    this.fruits = this.fruits.filter((f) => !struck.includes(f));
    const targets = struck.filter((f) => f.kind !== 10);
    const bomb = struck.find((f) => f.kind === 10);
    const multiplier = this.double > this.time ? 2 : 1;
    if (targets.length) {
      this.heat = Math.min(
        1,
        this.heat + 0.14 * targets.length + (this.time <= this.comboUntil ? 0.12 : 0),
      );
      for (const f of targets) {
        this.sliced++;
        const special = f.kind >= 6;
        const critical = !special && Math.random() < 0.08;
        const points = ((f.kind === 9 ? 10 : special ? 3 : 1) + (critical ? 10 : 0)) * multiplier;
        this.score += points;
        if (critical || f.kind === 9) this.label((critical ? 'Critical' : 'Golden') + ' +' + points, f);
        if (f.kind === 6) {
          this.frenzy = this.time + 5.5;
          this.label('Frenzy', f);
        }
        if (f.kind === 7) {
          this.freeze = this.time + 5.5;
          this.label('Freeze', f, '#a1eaff');
        }
        if (f.kind === 8) {
          this.double = this.time + 6.5;
          this.label('Double points', f);
        }
        this.split(f, angle);
      }
      const prev = this.time <= this.comboUntil ? this.combo : 0;
      this.combo = prev + targets.length;
      this.comboUntil = this.time + 0.28;
      if (this.combo >= 3) {
        this.bestCombo = Math.max(this.bestCombo, this.combo);
        this.score += (prev < 3 ? this.combo : targets.length) * multiplier;
        this.labels = this.labels.filter((v) => !v.text.endsWith(' combo'));
        const milestones = [3, 5, 8].filter((n) => prev < n && this.combo >= n);
        boost = milestones.reduce((sum, n) => sum + n * multiplier, 0);
        this.score += boost;
        this.label(this.combo + ' slice combo', targets.at(-1));
        if (boost) this.notify('combo');
      }
      this.notify('hit');
    }
    if (bomb) {
      this.blast = { x: bomb.x, y: bomb.y, born: this.time, spin: random(0, Math.PI * 2) };
      this.notify('bomb');
      if (this.mode === 'arcade') {
        this.score = Math.max(0, this.score - 10);
        this.label('−10', bomb, '#ff8c55');
      } else this.end();
    }
    this.notify('score', {
      gain: this.score - before,
      combo: targets.length ? this.combo : 0,
      boost,
      impact: targets.at(-1) || b,
    });
  }
  split(f, angle) {
    const theme = this.theme,
      color = themes[theme].colors[f.kind] || ['#ffab47', '#9aeaff', '#cb8dff', '#ffe67a'][f.kind - 6];
    for (const side of [-1, 1])
      boundedPush(
        this.halves,
        {
          ...f,
          side,
          theme,
          cut: angle - f.rot,
          born: this.time,
          vx: f.vx * 0.65 - (side * Math.sin(angle) * 0.22) / this.aspect,
          vy: f.vy * 0.65 + side * Math.cos(angle) * 0.22 - 0.08,
          spin: side * random(2, 5),
        },
        64,
      );
    if (theme !== 'gadgets')
      boundedPush(
        this.stains,
        {
          x: f.x,
          y: f.y,
          r: f.r * (1.4 + this.heat * 0.6),
          angle,
          color,
          heat: this.heat,
          seed: random(0, 80),
          born: this.time,
        },
        36,
      );
    for (let i = 0; i < 8 + Math.floor(this.heat * 12); i++) {
      const direction = angle + (i % 4 === 0 ? Math.PI : 0) + random(-0.85, 0.85),
        speed = random(0.25, 0.9);
      boundedPush(
        this.drops,
        {
          x: f.x,
          y: f.y,
          vx: (Math.cos(direction) * speed) / this.aspect,
          vy: Math.sin(direction) * speed - 0.16,
          color,
          theme,
          angle: direction,
          r: random(0.003, 0.009),
          life: random(0.3, 0.8),
          born: this.time,
        },
        112,
      );
    }
  }
  step(dt) {
    if (this.phase !== 'playing' && this.phase !== 'exploding') return;
    dt = clamp(dt, 0, 0.05);
    this.time += dt;
    if (this.blast && this.time - this.blast.born >= blastDuration) this.blast = null;
    if (this.phase === 'exploding') {
      if (!this.blast) this.end();
      return;
    }
    const sim = dt * (this.time < this.freeze ? 0.45 : 1);
    if (this.mode !== 'classic' && (this.remaining -= sim) <= 0) {
      this.remaining = 0;
      this.end();
      return;
    }
    this.heat = Math.max(0, this.heat - dt * 0.3);
    if (this.time >= this.nextWave) this.spawnWave();
    if (this.time < this.frenzy && this.time >= this.extraAt) {
      this.spawn(Math.floor(random(0, 6)), true);
      this.extraAt = this.time + 0.18;
    }
    for (const list of [this.fruits, this.halves, this.drops])
      for (const f of list) {
        const d = list === this.drops ? dt : sim;
        f.vy += 0.92 * d;
        f.x += f.vx * d;
        f.y += f.vy * d;
        if ('spin' in f) f.rot += f.spin * d;
      }
    const missed = this.fruits.filter((f) => f.y > 1.15 && f.kind !== 10);
    this.fruits = this.fruits.filter((f) => f.y <= 1.15);
    this.halves = this.halves.filter((f) => f.y < 1.25);
    this.drops = this.drops.filter((f) => this.time - f.born < f.life);
    this.stains = this.stains.filter((f) => this.time - f.born < 4.5);
    this.trails = this.trails.filter((f) => this.time - f.born < bladeDurations[f.blade]);
    this.labels = this.labels.filter((f) => this.time - f.born < 0.85);
    if (missed.length && this.mode === 'classic') {
      this.lives = Math.max(0, this.lives - missed.length);
      this.notify('miss');
      if (!this.lives) this.end();
    }
  }
}
