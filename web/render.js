import { blades, blastDuration } from './engine.js';
import { atlas, bladeDurations } from './blade-atlas.js';
import { makeJuice } from './juice.js';

const sheets = {};
const bladeSheets = [];
async function loadImage(path) {
  const image = new Image();
  image.src = './art/' + path;
  await image.decode();
  return image;
}
export async function loadArt() {
  await Promise.all([
    ...['Orchard', 'PowerFruit', 'Garden', 'Gadgets'].map(async (name) => {
      sheets[name] = await loadImage(name + '.png');
    }),
    ...bladeDurations.map(async (_, id) => {
      bladeSheets[id] = await loadImage('blades/' + id + '.webp');
    }),
  ]);
}
function tile(theme, kind, face) {
  if (kind === 10) return [sheets.PowerFruit, 1, 1];
  if (theme === 'fruit') {
    if (kind < 6) return [sheets.Orchard, kind, face ? 1 : 0];
    if (kind === 9) return [sheets.PowerFruit, 0, 1];
    return [sheets.PowerFruit, face ? 2 : kind - 6, face ? 1 : 0];
  }
  const ix = (face ? [4, 5, 6, 7, 10, 11, 12, 13, 14, 15] : [0, 1, 2, 3, 8, 9, 12, 13, 14, 15])[kind];
  return [theme === 'gadgets' ? sheets.Gadgets : sheets.Garden, ix % 4, Math.floor(ix / 4)];
}
function art(ctx, theme, kind, face, r, depth = 1) {
  const [image, x, y] = tile(theme, kind, face);
  ctx.drawImage(image, x * 256, y * 256, 256, 256, -r, -r * depth, 2 * r, 2 * r * depth);
}
function sizeCanvas(canvas, w, h, dpr) {
  const width = Math.max(1, Math.round(w * dpr)),
    height = Math.max(1, Math.round(h * dpr));
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
}
export function drawHero(canvas, theme) {
  const { width: w, height: h } = canvas.getBoundingClientRect();
  if (!w || !h || !sheets.Gadgets) return;
  const dpr = Math.min(devicePixelRatio, 2),
    unit = Math.min(w, h * 1.2);
  sizeCanvas(canvas, w, h, dpr);
  const c = canvas.getContext('2d');
  c.setTransform(dpr, 0, 0, dpr, 0, 0);
  c.clearRect(0, 0, w, h);
  const pieces = [
    [2, 0.2, 0.22, 0.092, -0.5, true],
    [1, 0.8, 0.32, 0.143, 0.32, false],
    [0, 0.5, 0.43, 0.266, -0.46, true],
    [3, 0.27, 0.65, 0.145, -0.38, false],
    [4, 0.73, 0.74, 0.104, 0.58, true],
  ];
  for (const [kind, x, y, scale, turn, face] of pieces) {
    c.save();
    c.translate(w * x, h * y);
    c.rotate(turn);
    c.shadowColor = '#12070299';
    c.shadowBlur = unit * 0.035;
    c.shadowOffsetY = unit * 0.025;
    art(c, theme, kind, face, unit * scale, face ? 0.9 : 1);
    c.restore();
  }
  const colors = theme === 'gadgets' ? ['#88d9ff', '#ffcc63'] : ['#e55429', '#ff9b3b'];
  for (let i = 0; i < 25; i++) {
    const t = i / 24,
      rad = unit * (0.003 + (0.006 * ((i * 7) % 13)) / 13);
    const x = (0.1 + t * 0.77) * w,
      y = (0.74 - t * 0.5 + 0.092 * Math.sin(i * 17.3)) * h;
    c.fillStyle = colors[i % 2];
    c.beginPath();
    c.ellipse(x, y, rad * 1.8, rad, -0.4, 0, Math.PI * 2);
    c.fill();
  }
}

export class Renderer {
  constructor(canvas, juice) {
    this.canvas = canvas;
    this.juice = juice;
    this.c = canvas.getContext('2d');
    this.gpu = makeJuice(juice);
    juice.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      this.gpu = null;
    });
    juice.addEventListener('webglcontextrestored', () => {
      this.gpu = makeJuice(juice);
    });
    this.reduced = matchMedia('(prefers-reduced-motion: reduce)');
  }
  resize(w, h) {
    this.w = w;
    this.h = h;
    this.ratio = Math.min(devicePixelRatio || 1, 2);
    for (const canvas of [this.canvas, this.juice]) sizeCanvas(canvas, w, h, this.ratio);
  }
  draw(game) {
    const { c, w, h } = this,
      unit = Math.min(w, h);
    if (!w || !h) return;
    this.gpu?.(game, w, h);
    c.setTransform(this.ratio, 0, 0, this.ratio, 0, 0);
    c.clearRect(0, 0, w, h);
    if (!this.gpu)
      for (const s of game.stains) {
        c.save();
        c.translate(s.x * w, s.y * h);
        c.rotate(s.angle);
        c.globalAlpha = 0.48 * Math.min(1, 4.5 - game.time + s.born);
        c.fillStyle = s.color;
        c.beginPath();
        for (let i = 0; i <= 52; i++) {
          const a = (i * Math.PI) / 26,
            r = s.r * unit * (0.57 + 0.1 * Math.sin(a * 7 + s.seed) + 0.15 * Math.cos(a * 11));
          if (!i) c.moveTo(r * 1.5, 0);
          else c.lineTo(r * Math.cos(a) * 1.5, r * Math.sin(a));
        }
        c.fill();
        c.restore();
      }
    if (!this.reduced.matches && game.heat > 0.4 && game.labels.length) {
      const since = game.time - game.labels.at(-1).born;
      c.translate(Math.sin(since * 63) * Math.exp(-since * 20) * game.heat * 4, 0);
    }
    for (const f of game.halves) {
      const r = f.r * unit * 1.12;
      c.save();
      c.translate(f.x * w, f.y * h);
      c.rotate(f.rot + f.cut);
      c.save();
      c.beginPath();
      c.rect(-1.6 * r, f.side > 0 ? 0 : -1.6 * r, 3.2 * r, 1.6 * r);
      c.clip();
      c.rotate(-f.cut);
      art(c, f.theme, f.kind, false, r);
      c.restore();
      const tilt =
        0.12 +
        (1 - Math.exp(-(game.time - f.born) * 15)) *
          (0.36 + 0.2 * Math.sin((game.time - f.born) * Math.abs(f.spin)));
      c.scale(f.side, f.side);
      art(
        c,
        f.theme,
        f.kind,
        true,
        r * (f.theme === 'fruit' && f.kind >= 6 && f.kind <= 8 ? 0.44 : 0.9),
        tilt,
      );
      c.restore();
    }
    for (const f of game.fruits) {
      c.save();
      c.translate(f.x * w, f.y * h);
      c.rotate(f.rot);
      const r = f.r * unit * 1.12;
      art(c, game.theme, f.kind, false, r);
      if (f.kind === 10) {
        c.fillStyle = '#ffe689';
        c.beginPath();
        c.arc(r * 0.28, -r * 1.06, 2 + 1.2 * Math.sin(game.time * 48), 0, 2 * Math.PI);
        c.fill();
      }
      c.restore();
    }
    for (const d of game.drops) {
      if (this.gpu && d.theme !== 'gadgets') continue;
      c.save();
      c.globalAlpha = Math.min(1, (d.life - game.time + d.born) * 5);
      c.fillStyle = d.color;
      c.translate(d.x * w, d.y * h);
      c.rotate(Math.atan2(d.vy * h, d.vx * w));
      const r = d.r * unit;
      if (d.theme === 'gadgets') c.fillRect(-r * 1.5, -r * 0.3, r * 3, r * 0.6);
      else {
        c.beginPath();
        c.ellipse(0, 0, r * 1.6, r * 0.65, 0, 0, Math.PI * 2);
        c.fill();
      }
      c.restore();
    }
    for (const trail of game.trails) this.trail(trail, game.time);
    if (game.tip && game.held.length) {
      c.strokeStyle = blades[game.blade][1];
      c.lineWidth = 2;
      c.beginPath();
      c.arc(game.tip.x * w, game.tip.y * h, 10, 0, Math.PI * 2);
      c.stroke();
    }
    c.textAlign = 'center';
    c.font = '800 22px system-ui';
    c.lineJoin = 'round';
    for (const label of game.labels) {
      const age = game.time - label.born,
        x = label.x * w,
        y = label.y * h - 15 - age * 36;
      c.globalAlpha = Math.min(1, (0.85 - age) * 4);
      c.lineWidth = 4;
      c.strokeStyle = '#2b170e';
      c.strokeText(label.text, x, y);
      c.fillStyle = label.color;
      c.fillText(label.text, x, y);
    }
    c.globalAlpha = 1;
    if (game.blast) this.drawBlast(game.blast, game.time);
    else if (this.canvas.parentElement.style.translate) this.canvas.parentElement.style.translate = '';
  }
  drawBlast(blast, now) {
    const { c, w, h } = this;
    const t = Math.min(1, (now - blast.born) / blastDuration);
    const unit = Math.min(w, h);
    const kick = this.reduced.matches ? 0 : Math.min(11, unit * 0.026) * (1 - t) ** 3;
    this.canvas.parentElement.style.translate = kick
      ? Math.cos(t * 43) * kick + 'px ' + Math.sin(t * 56 + 1) * kick * 0.72 + 'px'
      : '';
    c.save();
    c.fillStyle = 'rgba(255,220,170,' + Math.max(0, 1 - t * 5) * (this.reduced.matches ? 0.08 : 0.38) + ')';
    c.fillRect(0, 0, w, h);
    c.translate(blast.x * w, blast.y * h);
    const spread = unit * (0.035 + 0.23 * (1 - (1 - t) ** 2));
    c.globalAlpha = (1 - t) ** 2;
    c.lineWidth = 1 + 4 * (1 - t);
    c.strokeStyle = '#ffdb87';
    c.beginPath();
    c.arc(0, 0, spread, 0, 2 * Math.PI);
    c.stroke();
    c.lineCap = 'round';
    for (let i = 0; i < 24; i++) {
      const a = blast.spin + i * 2.4;
      const distance = spread * (0.5 + (i % 7) * 0.12);
      const dx = Math.cos(a), dy = Math.sin(a);
      const tail = distance - unit * (0.01 + (i % 4) * 0.009) * (1 - t);
      const fall = unit * 0.08 * t * t;
      c.lineWidth = 1 + (i % 3) * (1 - t);
      c.strokeStyle = ['#fff3cb', '#ffae3d', '#ff6425'][i % 3];
      c.beginPath();
      c.moveTo(tail * dx, tail * dy + fall);
      c.lineTo(distance * dx, distance * dy + fall);
      c.stroke();
    }
    c.restore();
  }
  trail(s, now) {
    const elapsed = now - s.born, duration = bladeDurations[s.blade];
    if (elapsed < 0 || elapsed >= duration) return;
    const ax = s.a.x * this.w, ay = s.a.y * this.h;
    const dx = s.b.x * this.w - ax, dy = s.b.y * this.h - ay;
    const length = Math.hypot(dx, dy);
    if (length < 0.5) return;
    const frame = Math.min(atlas.frames - 1, Math.floor(elapsed / duration * atlas.frames));
    const breadth = Math.min(1, length / 225);
    const c = this.c;
    c.save();
    c.translate(ax, ay);
    c.rotate(Math.atan2(dy, dx));
    c.scale(length / atlas.span, s.seed < 5 ? breadth : -breadth);
    c.drawImage(bladeSheets[s.blade],
      (frame % atlas.columns) * atlas.cellWidth, Math.floor(frame / atlas.columns) * atlas.cellHeight,
      atlas.cellWidth, atlas.cellHeight, atlas.x, atlas.y, atlas.width, atlas.height);
    c.restore();
  }
}
