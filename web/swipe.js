import { blades } from './engine.js';

const lifetime = 145; // milliseconds of finger history
const reach = 180; // CSS pixels at full swipe speed

export class SwipeStroke {
  constructor(blade, x, y, time) {
    this.blade = blade;
    this.points = [{ x, y, time, distance: 0 }];
  }

  move(x, y, time) {
    const last = this.points.at(-1);
    const step = Math.hypot(x - last.x, y - last.y);
    if (step < 0.25) return null;
    // A finger held still is a fresh starting point when it moves again.
    if (time - last.time > lifetime) {
      this.points = [last];
      last.time = time - 16;
    }
    this.points.push({ x, y, time: Math.max(last.time, time), distance: last.distance + step });
    if (this.points.length > 96) this.points.shift();
    return last;
  }

  // Clip inside the boundary segment so even a single long flick has a tapered tail.
  visible(now) {
    const head = this.points.at(-1);
    const since = now - lifetime, startDistance = head.distance - reach;
    if (head.time <= since) return [];
    let i = 0;
    while (i < this.points.length - 1 &&
      (this.points[i].time < since || this.points[i].distance < startDistance)) i++;
    const visible = this.points.slice(i);
    if (i) {
      const a = this.points[i - 1], b = visible[0];
      const u = Math.max(0, (startDistance - a.distance) / (b.distance - a.distance),
        a.time < since ? (since - a.time) / (b.time - a.time) : 0);
      if (u < 1) visible.unshift({
        x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u,
        distance: a.distance + (b.distance - a.distance) * u, time: a.time + (b.time - a.time) * u,
      });
    }
    return visible;
  }
}

// All materials use the sampled centerline. Width and edge color can vary without
// moving the cutting edge away from the finger at corners or reversals.
function paint(c, stroke, points, now) {
  const head = points.at(-1), tail = points[0];
  const fade = Math.max(points.length === 1 ? 0.5 : 0, Math.min(1, 1 - (now - head.time) / lifetime));
  const [, primary, accent] = blades[stroke.blade];
  const length = head.distance - tail.distance;
  const width = Math.min(5, 1.6 + length * 0.025);
  c.globalAlpha = fade;
  if (length > 0) {
    const ribbon = new Path2D();
    const spine = new Path2D(), detail = new Path2D();
    spine.moveTo(tail.x, tail.y);
    detail.moveTo(tail.x, tail.y);
    let r0 = 0;
    for (let i = 1; i < points.length; i++) {
      const a = points[i - 1], b = points[i];
      const dx = b.x - a.x, dy = b.y - a.y, d = Math.hypot(dx, dy);
      if (!d) continue;
      const nx = -dy / d, ny = dx / d;
      // Subdivide long event gaps only for shading. Every vertex stays on the input segment.
      const steps = Math.ceil(d / 8);
      let x0 = a.x, y0 = a.y;
      for (let j = 1; j <= steps; j++) {
        const x = a.x + dx * j / steps, y = a.y + dy * j / steps;
        const distance = a.distance + d * j / steps;
        const u = Math.min(1, (distance - tail.distance) / length);
        const r1 = width * Math.sqrt(u) * Math.min(1, 0.22 + (head.distance - distance) / 12);
        ribbon.moveTo(x0 + nx * r0, y0 + ny * r0);
        ribbon.lineTo(x + nx * r1, y + ny * r1);
        ribbon.lineTo(x - nx * r1, y - ny * r1);
        ribbon.lineTo(x0 - nx * r0, y0 - ny * r0);
        ribbon.closePath();
        ribbon.moveTo(x + r1, y);
        ribbon.arc(x, y, r1, 0, -2 * Math.PI, true);
        let lane = 0.55;
        switch (stroke.blade) {
          case 1: lane = Math.sin(distance / 5); break; // flame
          case 2: case 4: lane = Math.floor(distance / 8) % 2 ? 1 : -1; break; // facets and lightning
          case 3: case 9: lane = Math.sin(distance / 9); break; // silk and braid
        }
        detail.lineTo(x + nx * r1 * lane, y + ny * r1 * lane);
        x0 = x; y0 = y; r0 = r1;
      }
      spine.lineTo(b.x, b.y);
    }
    // A loop can put the head directly over its tail.
    const gradient = c.createLinearGradient(tail.x, tail.y,
      tail.x === head.x && tail.y === head.y ? head.x + 1 : head.x, head.y);
    gradient.addColorStop(0, accent);
    if (stroke.blade === 6 || stroke.blade === 8) {
      gradient.addColorStop(0.35, '#75f4ff');
      gradient.addColorStop(0.65, '#ffe99a');
    }
    gradient.addColorStop(1, primary);
    c.fillStyle = gradient;
    c.fill(ribbon);
    c.lineCap = 'round';
    c.lineJoin = 'round';
    c.strokeStyle = accent;
    c.lineWidth = 1;
    c.stroke(detail);
    c.lineWidth = Math.min(1.7, width * 0.5);
    c.strokeStyle = stroke.blade === 5 || stroke.blade === 7 ? '#281b30' : '#fff8eb';
    c.stroke(spine);
  }
  c.beginPath();
  c.arc(head.x, head.y, stroke.blade === 8 && length ? width : 1.6, 0, Math.PI * 2);
  c.fillStyle = '#fff8eb';
  c.fill();
}

export class SwipeOverlay {
  constructor(canvas) {
    this.canvas = canvas;
    this.active = new Map();
    this.released = [];
  }
  begin(id, blade, x, y, now) {
    this.active.set(id, new SwipeStroke(blade, x, y, now));
    this.canvas.hidden = false;
  }
  end(id) {
    const stroke = this.active.get(id);
    if (!stroke) return;
    this.released.push(stroke);
    if (this.released.length > 10) this.released.shift();
    this.active.delete(id);
  }
  clear() {
    this.active.clear();
    this.released.length = 0;
    this.canvas.hidden = true;
  }
  draw(now, width, height, ratio) {
    if (this.canvas.hidden || !width || !height) return;
    const w = Math.round(width * ratio), h = Math.round(height * ratio);
    if (this.canvas.width !== w || this.canvas.height !== h) {
      this.canvas.width = w;
      this.canvas.height = h;
    }
    const c = this.context ??= this.canvas.getContext('2d');
    c.setTransform(ratio, 0, 0, ratio, 0, 0);
    c.clearRect(0, 0, width, height);
    this.released = this.released.filter(stroke => now - stroke.points.at(-1).time < lifetime);
    for (const stroke of this.released) {
      const points = stroke.visible(now);
      if (points.length) paint(c, stroke, points, now);
    }
    for (const stroke of this.active.values()) {
      const points = stroke.visible(now);
      paint(c, stroke, points.length ? points : [stroke.points.at(-1)], now);
    }
    if (!this.active.size && !this.released.length) this.canvas.hidden = true;
  }
}
