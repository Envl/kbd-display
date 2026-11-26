import test from 'node:test';
import assert from 'node:assert/strict';
import { SwipeStroke } from '../swipe.js';
import { Game, keys, hits, blastDuration } from '../engine.js';

test('one held key anchors repeated taps, including Space', () => {
  const g = new Game();
  g.start();
  g.down('Space');
  for (const key of ['KeyA', 'KeyA', 'KeyP']) {
    g.down(key);
    g.down(key);
    g.up(key);
    assert.equal(g.trails.at(-1).a, keys.get('Space'));
    assert.equal(g.trails.at(-1).b, keys.get(key));
    assert.equal(g.tip, keys.get('Space'));
  }
  assert.equal(g.trails.length, 3);
  g.down('KeyA');
  g.up('Space');
  g.down('KeyB');
  assert.equal(g.trails.at(-1).a, keys.get('KeyA'));
  g.pause();
  assert.equal(g.held.length, 0);
  const time = g.time;
  g.step(0.04);
  assert.equal(g.time, time);
});
test('bomb spacing across modes', () => {
  for (const mode of ['classic', 'arcade', 'zen']) {
    const g = new Game();
    g.mode = mode;
    g.start();
    let last = 0;
    for (let wave = 1; wave <= 55; wave++) {
      g.fruits = [];
      g.spawnWave();
      if (g.fruits.some((f) => f.kind === 10)) {
        assert.notEqual(mode, 'zen');
        assert.ok(wave - last >= 8 && wave - last <= 14);
        last = wave;
      }
      if (mode !== 'zen') assert.ok(wave - last < 14);
    }
  }
});
test('rapid cuts preserve score, physical intersections and bounded effects', () => {
  const g = new Game();
  g.mode = 'zen';
  g.start();
  const a = { x: 0.1, y: 0.5 },
    b = { x: 0.9, y: 0.5 };
  assert.ok(!hits(a, b, { x: 0.5, y: 0.6, r: 0.03 }, 2));
  for (let i = 0; i < 120; i++) {
    g.spawn(9);
    Object.assign(g.fruits[0], { x: 0.5, y: 0.5 });
    g.cut(a, b);
    assert.ok(g.drops.length <= 112);
    assert.ok(g.trails.length <= 10);
    assert.ok(g.stains.length <= 36);
  }
  assert.equal(g.sliced, 120);
  assert.equal(g.score, 1336);
  g.theme = 'gadgets';
  g.spawn(7);
  Object.assign(g.fruits[0], { x: 0.4, y: 0.5 });
  g.cut(a, b);
  assert.ok(g.freeze > 0);
  assert.equal(g.drops.at(-1).theme, 'gadgets');
});
test('Classic and Arcade penalties and timed rounds', () => {
  const g = new Game();
  g.start();
  g.spawn(10);
  const f = g.fruits[0];
  g.sliceSegment(f, f);
  assert.equal(g.phase, 'exploding');
  assert.equal(g.blast.x, f.x);
  const wave = g.wave;
  g.down('KeyQ');
  assert.equal(g.held.length, 0);
  while (g.time < blastDuration) g.step(0.02);
  assert.equal(g.wave, wave);
  assert.equal(g.blast, null);
  assert.equal(g.phase, 'over');
  g.mode = 'arcade';
  g.start();
  g.score = 18;
  g.spawn(10);
  const bomb = g.fruits[0];
  g.cut(bomb, bomb);
  assert.equal(g.phase, 'playing');
  assert.equal(g.score, 8);
  assert.equal(g.blast.y, bomb.y);
  g.remaining = 0.01;
  g.step(0.02);
  assert.equal(g.phase, 'exploding');
  while (g.blast) g.step(0.02);
  assert.equal(g.phase, 'over');
});

test('extended keys support both directions and Space is the only thumb-row anchor', () => {
  const g = new Game();
  g.start();
  for (const code of ['Tab', 'CapsLock', 'ShiftLeft', 'ShiftRight', 'Enter', 'Backslash']) {
    g.down(code);
    g.down('Space');
    assert.equal(g.trails.at(-1).a, keys.get(code));
    g.up(code);
    g.down(code);
    assert.equal(g.trails.at(-1).b, keys.get(code));
    g.up(code);
    g.up('Space');
  }
  assert.deepEqual(
    [...keys].filter(([, key]) => key.y > 0.8).map(([code]) => code),
    ['Space'],
  );
});
test('a fast swipe crosses multiple fruit in a portrait arena', () => {
  const game = new Game();
  game.aspect = 390 / 640;
  game.start();
  for (const x of [0.2, 0.5, 0.8]) {
    game.spawn(0);
    Object.assign(game.fruits.at(-1), { x, y: 0.5 });
  }
  game.cut({ x: 0.05, y: 0.5 }, { x: 0.95, y: 0.5 });
  assert.equal(game.sliced, 3);
  assert.ok(game.score >= 3);
});

test('a curved swipe renders and slices along each segment, including a reversal', () => {
  const game = new Game();
  game.start();
  for (const [x, y] of [[0.5, 0.3], [0.5, 0.5]]) {
    game.spawn(0);
    Object.assign(game.fruits.at(-1), { x, y });
  }
  const stroke = new SwipeStroke(2, 30, 30, 0);
  const route = [[70, 30], [70, 70], [70, 35]];
  for (const [i, [x, y]] of route.entries()) {
    const a = stroke.move(x, y, (i + 1) * 10);
    game.sliceSegment({ x: a.x / 100, y: a.y / 100 }, { x: x / 100, y: y / 100 });
  }
  assert.deepEqual(stroke.visible(30).map(p => [p.x, p.y]), [[30, 30], ...route]);
  assert.equal(game.sliced, 1);
  assert.equal(game.fruits[0].y, 0.5);
  assert.equal(game.trails.length, 0);
});

test('swipe history clips long flicks and drops old samples while the head stays exact', () => {
  const stroke = new SwipeStroke(5, 0, 0, 0);
  stroke.move(400, 0, 100);
  assert.deepEqual(stroke.visible(100).map(p => Math.round(p.x)), [220, 400]);
  assert.deepEqual(stroke.visible(250), []);
  stroke.move(405, 0, 400);
  assert.deepEqual(stroke.visible(400).map(p => p.x), [400, 405]);
  for (let i = 1; i < 400; i++) stroke.move(405 + i, i, 400 + i);
  assert.ok(stroke.points.length <= 96);
  assert.equal(stroke.visible(800).at(-1).x, 804);
});

test('all ten blades share the short recovery window', () => {
  for (let blade = 0; blade < 10; blade++) {
    const game = new Game();
    game.start();
    game.blade = blade;
    game.cut(keys.get('KeyA'), keys.get('KeyL'));
    for (let i = 0; i < 9; i++) game.step(1 / 30);
    assert.equal(game.trails.length, 1);
    game.step(1 / 30);
    assert.equal(game.trails.length, 0);
  }
});
