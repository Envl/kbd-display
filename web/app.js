import { Game, keys, themes, blades } from './engine.js';
import { SwipeOverlay } from './swipe.js';
import { GameAudio } from './audio.js';
import { ScoreFeedback } from './score-fx.js';
import { Renderer, loadArt, drawHero } from './render.js';

const $ = (s) => document.querySelector(s),
  arena = $('#arena'),
  cover = $('#cover'),
  intro = $('#headline');
const renderer = new Renderer($('#action'), $('#juice')),
  audio = new GameAudio();
const touchLayout = matchMedia('(pointer: coarse) and (hover: none)').matches;
document.body.toggleAttribute('data-touch', touchLayout);
const field = $('#field');
const swipes = new SwipeOverlay($('#swipe'));
const feedback = new ScoreFeedback($('#score'), $('#score-fx'), field, $('#boost'));
const game = new Game((event, detail) => {
  if (event === 'state') {
    if (game.phase === 'playing' && game.time === 0) audio.offset = 0;
    feedback.reset();
    syncScreen();
    audio.sync(game);
  } else if (event === 'score') {
    recordScore();
    if (game.phase === 'playing') feedback.pulse(detail);
  } else if (event !== 'swipe' || performance.now() - lastWhoosh > 28) {
    audio.effect(event, game.theme, game.blade);
    if (event === 'swipe') lastWhoosh = performance.now();
  }
});
let lastWhoosh = -Infinity,
  ready = false,
  frame = 0,
  previous = 0;
const read = (key, fallback) => {
  try {
    return localStorage.getItem('kbd-ninja.' + key) ?? fallback;
  } catch {
    return fallback;
  }
};
function save(key, value) {
  try {
    localStorage.setItem('kbd-ninja.' + key, String(value));
  } catch {}
}
function setText(node, text) {
  if (node.textContent !== text) node.textContent = text;
}
const storedTheme = read('theme', 'fruit');
game.theme = Object.hasOwn(themes, storedTheme) ? storedTheme : 'fruit';
game.blade = Math.max(0, Math.min(blades.length - 1, parseInt(read('blade', '0'), 10) || 0));
const modes = ['classic', 'zen', 'arcade'];
const defaultMode = touchLayout ? 'arcade' : 'classic';
const storedMode = read('mode', defaultMode);
game.mode = modes.includes(storedMode) ? storedMode : defaultMode;
game.reset();
audio.music = read('music', 'true') === 'true';
audio.sound = read('sound', 'true') === 'true';
const grids = ['subtle', 'bright', 'hidden'];
let grid = grids.includes(read('grid', 'subtle')) ? read('grid', 'subtle') : 'subtle';
const best = Object.fromEntries(modes.map((m) => [m, Number(read('best.' + m, 0)) || 0]));
const keyNodes = new Map();
for (const [code, key] of keys) {
  const el = document.createElement('i');
  el.textContent = key.label;
  el.style.left = key.x * 100 + '%';
  el.style.top = key.y * 100 + '%';
  if (code === 'Space') el.classList.add('space');
  $('#keys').append(el);
  keyNodes.set(code, el);
}
let heldSignature = null;
function syncKeys() {
  const signature = game.held.join(' ');
  if (signature === heldSignature) return;
  heldSignature = signature;
  for (const [code, el] of keyNodes) el.classList.toggle('held', game.held.includes(code));
}
function focusArena() {
  arena.focus({ preventScroll: true });
}
function unlock() {
  audio.unlock();
  audio.master.gain.value = audio.sound ? 1 : 0;
}
function recordScore() {
  if (game.score > best[game.mode]) {
    best[game.mode] = game.score;
    save('best.' + game.mode, game.score);
  }
  updateStats();
}
const scoreNode = $('#score'),
  bestNode = $('#best'),
  statusNode = $('#status');
function updateStats() {
  setText(scoreNode, String(game.score).padStart(3, '0'));
  setText(bestNode, String(best[game.mode]).padStart(3, '0'));
  const seconds = Math.ceil(game.remaining);
  let status =
    game.mode === 'classic'
      ? '♥'.repeat(game.lives) + '♡'.repeat(3 - game.lives)
      : Math.floor(seconds / 60) + ':' + String(seconds % 60).padStart(2, '0');
  if (game.phase === 'playing') {
    const power =
      game.time < game.freeze
        ? 'Freeze'
        : game.time < game.frenzy
          ? 'Frenzy'
          : game.time < game.double
            ? 'Double'
            : '';
    if (power) status = power + ' · ' + status;
  }
  setText(statusNode, status);
}
function updateAudioButtons() {
  $('#music').setAttribute('aria-pressed', String(audio.music));
  $('#sound').setAttribute('aria-pressed', String(audio.sound));
}
function updateGrid() {
  $('#keys').dataset.grid = grid;
  $('#grid b').textContent = grid[0].toUpperCase() + grid.slice(1);
}
function syncScreen() {
  const phase = game.phase,
    title = phase === 'title',
    over = phase === 'over',
    paused = phase === 'paused';
  document.body.dataset.phase = phase;
  cover.hidden = phase === 'playing' || phase === 'exploding';
  $('#pause').hidden = phase !== 'playing';
  if (title) {
    intro.replaceChildren(
      document.createTextNode(themes[game.theme].name),
      document.createElement('br'),
      Object.assign(document.createElement('em'), { textContent: 'Ninja' }),
    );
  } else if (paused) intro.textContent = 'Paused';
  else if (over) intro.innerHTML = 'Game<br><em>over</em>';
  $('#instructions').textContent = title
    ? touchLayout ? 'Swipe across the arena to slice.' : 'Hold a marked key. Tap another to slice.'
    : paused
      ? 'Your round is paused.'
      : game.sliced + ' sliced · Best combo ' + game.bestCombo;
  $('#result').hidden = !title;
  $('#result').textContent = {
    classic: '3 lives · Avoid bombs',
    zen: '90 seconds · No bombs',
    arcade: '60 seconds · Power-ups',
  }[game.mode];
  $('#start strong').textContent = paused ? 'Resume' : over ? 'Play again' : 'Start game';
  $('#start').disabled = !ready;
  for (const button of $('#modes').children)
    button.setAttribute('aria-pressed', String(button.dataset.mode === game.mode));
  syncKeys();
  updateStats();
  swipes.clear();
  if (ready && !cover.hidden) drawHero($('#hero'), game.theme);
  schedule();
}
function begin() {
  if (!ready || game.phase === 'exploding') return;
  unlock();
  focusArena();
  if (game.phase === 'paused') game.resume();
  else if (game.phase !== 'playing') game.start();
}
function selectBlade(index, play = true) {
  game.blade = index;
  save('blade', index);
  $('#blade-name').textContent = blades[index][0];
  document.body.style.setProperty('--blade', blades[index][1]);
  for (const [i, b] of [...$('#blades').children].entries())
    b.setAttribute('aria-pressed', String(i === index));
  if (play) {
    unlock();
    audio.effect('equip', game.theme, index);
    focusArena();
  }
}
blades.forEach(([name, color], i) => {
  const button = document.createElement('button');
  const shortcut = (i + 1) % 10;
  button.title = name + ' (' + shortcut + ')';
  button.setAttribute('aria-label', name);
  button.style.setProperty('--tone', color);
  button.innerHTML = '<small>' + shortcut + '</small><i class="swatch"></i>';
  button.onclick = () => selectBlade(i);
  $('#blades').append(button);
});
$('#theme').value = game.theme;
$('#theme').onchange = (e) => {
  game.theme = e.target.value;
  save('theme', game.theme);
  unlock();
  audio.sync(game);
  syncScreen();
  focusArena();
};
$('#modes').onclick = (e) => {
  const mode = e.target.closest('button')?.dataset.mode;
  if (!mode || mode === game.mode) return;
  const active = game.phase === 'playing' || game.phase === 'paused';
  unlock();
  game.mode = mode;
  save('mode', mode);
  if (active) game.start();
  else {
    game.reset();
    game.phase = 'title';
    syncScreen();
  }
  focusArena();
};
$('#start').onclick = begin;
$('#pause').onclick = () => {
  game.pause();
  focusArena();
};
$('#music').onclick = () => {
  unlock();
  audio.music = !audio.music;
  save('music', audio.music);
  audio.sync(game);
  updateAudioButtons();
  focusArena();
};
$('#sound').onclick = () => {
  unlock();
  audio.sound = !audio.sound;
  save('sound', audio.sound);
  audio.master.gain.value = audio.sound ? 1 : 0;
  audio.sync(game);
  updateAudioButtons();
  focusArena();
};
$('#fullscreen').onclick = async () => {
  try {
    if (document.fullscreenElement) await document.exitFullscreen();
    else await document.documentElement.requestFullscreen();
  } catch {}
  focusArena();
};
$('#grid').onclick = () => {
  grid = grids[(grids.indexOf(grid) + 1) % grids.length];
  save('grid', grid);
  updateGrid();
  focusArena();
};

window.addEventListener('keydown', (e) => {
  if (e.metaKey || e.ctrlKey || e.altKey || e.target.tagName === 'SELECT') return;
  if (e.target.closest('button') && (e.code === 'Space' || e.code === 'Enter')) return;
  const code = e.code;
  if (code === 'Escape') {
    e.preventDefault();
    if (!e.repeat) {
      if (game.phase === 'playing') game.pause();
      else if (game.phase === 'paused') begin();
    }
    return;
  }
  if (/^Digit[0-9]$/.test(code) || code === 'BracketLeft' || code === 'BracketRight') {
    e.preventDefault();
    if (!e.repeat)
      selectBlade(
        code.startsWith('Digit')
          ? (Number(code.at(-1)) + 9) % 10
          : (game.blade + (code === 'BracketLeft' ? blades.length - 1 : 1)) % blades.length,
      );
    return;
  }
  if (!keys.has(code)) return;
  if (
    (code === 'Tab' || code === 'Enter') &&
    (game.phase !== 'playing' || document.activeElement !== arena)
  )
    return;
  e.preventDefault();
  if (e.repeat || !ready) return;
  if (code === 'Space' && game.phase !== 'playing') begin();
  game.down(code);
  syncKeys();
});
window.addEventListener('keyup', (e) => {
  if (keys.has(e.code)) {
    game.up(e.code);
    syncKeys();
  }
});
function leave() {
  game.pause();
  game.held.length = 0;
  syncKeys();
  swipes.clear();
}
window.addEventListener('blur', leave);
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    leave();
    cancelAnimationFrame(frame);
    frame = 0;
    previous = 0;
  } else schedule();
});
function sampleTime(e) {
  return e.timeStamp > 1e12 ? e.timeStamp - performance.timeOrigin : e.timeStamp;
}
arena.addEventListener('pointerdown', (e) => {
  if (!ready || e.button !== 0 || e.target.closest('button')) return;
  if (game.phase !== 'playing') {
    if (e.pointerType !== 'touch') return;
    begin();
    if (game.phase !== 'playing') return;
  }
  focusArena();
  const bounds = arena.getBoundingClientRect();
  swipes.begin(e.pointerId, game.blade, e.clientX - bounds.left, e.clientY - bounds.top, sampleTime(e));
  arena.setPointerCapture(e.pointerId);
});
function traceStroke(e) {
  const stroke = swipes.active.get(e.pointerId);
  if (!stroke || game.phase !== 'playing') return;
  const surface = arena.getBoundingClientRect(), world = field.getBoundingClientRect();
  function gamePoint(x, y) {
    return { x: (surface.left + x - world.left) / world.width, y: (surface.top + y - world.top) / world.height };
  }
  function advance(sample) {
    if (game.phase !== 'playing') return;
    const x = sample.clientX - surface.left, y = sample.clientY - surface.top;
    const last = stroke.move(x, y, sampleTime(sample));
    if (last) game.sliceSegment(gamePoint(last.x, last.y), gamePoint(x, y));
  }
  for (const sample of e.getCoalescedEvents?.() ?? []) advance(sample);
  advance(e);
}
arena.addEventListener('pointermove', traceStroke);
arena.addEventListener('pointerup', (e) => {
  if (e.pointerType === 'touch' && audio.ctx && audio.ctx.state !== 'running') unlock();
  if (!swipes.active.has(e.pointerId)) return;
  traceStroke(e);
  swipes.end(e.pointerId);
});
function cancelStroke(e) {
  swipes.active.delete(e.pointerId);
}
arena.addEventListener('pointercancel', cancelStroke);
arena.addEventListener('lostpointercapture', cancelStroke);
function schedule() {
  if (!document.hidden && !frame) frame = requestAnimationFrame(tick);
}
function tick(now) {
  frame = 0;
  if (!ready) {
    previous = now;
    return;
  }
  if (game.phase === 'playing' || game.phase === 'exploding') {
    game.step(previous ? (now - previous) / 1000 : 0);
    audio.energy(Math.round(game.heat * 16) / 16);
  }
  previous = now;
  renderer.draw(game);
  swipes.draw(now, renderer.w, renderer.h, renderer.ratio);
  feedback.draw(now);
  updateStats();
  if (game.phase === 'playing' || game.phase === 'exploding') schedule();
  else previous = 0;
}
new ResizeObserver(() => {
  const { width, height } = arena.getBoundingClientRect();
  renderer.resize(width, height);
  game.aspect = width / height;
  if (!cover.hidden) drawHero($('#hero'), game.theme);
  schedule();
}).observe(arena);
selectBlade(game.blade, false);
updateGrid();
updateAudioButtons();
syncScreen();
loadArt()
  .then(() => {
    ready = true;
    syncScreen();
  })
  .catch((err) => {
    $('#instructions').textContent = 'Artwork could not load. Reload to try again.';
    console.error(err);
  });
