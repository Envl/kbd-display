import { themes } from './engine.js';

export class GameAudio {
  constructor() {
    this.cache = new Map();
    this.cues = new Map();
    this.voices = new Set();
    this.music = true;
    this.sound = true;
    this.version = 0;
    this.offset = 0;
  }
  unlock() {
    if (!this.ctx) {
      this.ctx = new AudioContext();
      this.master = this.ctx.createGain();
      this.master.connect(this.ctx.destination);
    }
    if (this.ctx.state === 'suspended' || this.ctx.state === 'interrupted') this.ctx.resume().catch(() => {});
  }
  load(name) {
    if (!this.cache.has(name)) {
      const request = fetch('./music/' + name + '.m4a')
        .then((r) => {
          if (!r.ok) throw Error('Missing music ' + name);
          return r.arrayBuffer();
        })
        .then((data) => this.ctx.decodeAudioData(data))
        .catch((err) => {
          this.cache.delete(name);
          throw err;
        });
      this.cache.set(name, request);
    }
    return this.cache.get(name);
  }
  async sync(game) {
    const active = this.ctx && this.music && this.sound && game.phase === 'playing';
    const selection = active ? game.theme : null;
    if (this.selection === selection) return;
    this.selection = selection;
    const version = ++this.version;
    if (this.sources) {
      this.offset = Math.max(0, this.ctx.currentTime - this.started);
      for (const [source, gain] of this.sources) {
        source.stop();
        source.disconnect();
        gain.disconnect();
      }
      this.sources = null;
    }
    if (game.phase === 'over' || game.phase === 'title') this.offset = 0;
    if (!active) return;
    try {
      const buffers = await Promise.all(themes[selection].stems.map((s) => this.load(s)));
      if (version !== this.version) return;
      const when = this.ctx.currentTime + 0.035,
        offset = this.offset % buffers[0].duration;
      this.started = when - offset;
      this.lastHeat = -1;
      this.sources = buffers.map((buffer, index) => {
        const source = this.ctx.createBufferSource(),
          gain = this.ctx.createGain();
        source.buffer = buffer;
        source.loop = true;
        gain.gain.value = index ? 0.1 : 0.56;
        source.connect(gain);
        gain.connect(this.master);
        source.start(when, offset);
        return [source, gain];
      });
    } catch (err) {
      console.warn('Music unavailable', err);
    }
  }
  energy(value) {
    if (this.sources && this.lastHeat !== value) {
      this.sources[1][1].gain.setTargetAtTime(0.1 + 0.71 * value, this.ctx.currentTime, 0.1);
      this.lastHeat = value;
    }
  }
  effect(event, theme, blade) {
    if (!this.ctx || !this.sound) return;
    const id = event === 'swipe' ? 'swipe' + blade : event + theme;
    if (!this.cues.has(id)) this.cues.set(id, this.makeCue(event, theme, blade));
    if (event !== 'bomb' && this.voices.size >= 12) {
      const oldest = this.voices.values().next().value;
      this.voices.delete(oldest);
      oldest.stop();
    }
    const source = this.ctx.createBufferSource();
    source.buffer = this.cues.get(id);
    source.connect(this.master);
    // Reserve a voice so rapid swipes cannot cut the explosion tail short.
    if (event === 'bomb') {
      this.bombVoice?.stop();
      this.bombVoice = source;
    } else this.voices.add(source);
    source.onended = () => {
      source.disconnect();
      if (this.bombVoice === source) this.bombVoice = null;
      this.voices.delete(source);
    };
    source.start();
  }
  makeCue(event, theme, blade) {
    const sr = 24000,
      duration = { swipe: 0.1, hit: 0.18, combo: 0.36, bomb: 0.56, miss: 0.18, equip: 0.16 }[event];
    const buffer = this.ctx.createBuffer(1, Math.ceil(sr * duration), sr),
      data = buffer.getChannelData(0);
    let rumble = 0, prev = 0,
      phase = 0;
    for (let i = 0; i < data.length; i++) {
      const t = i / sr,
        noise = Math.random() * 2 - 1,
        hi = noise - prev,
        tau = 2 * Math.PI;
      prev = noise;
      let v = 0;
      if (event === 'swipe')
        v = (hi * 0.14 + 0.08 * Math.sin(tau * (1800 + blade * 80 - 9000 * t) * t)) * Math.exp(-32 * t);
      else if (event === 'combo' || event === 'equip') {
        const note =
          event === 'equip'
            ? 660 + blade * 80
            : [440, 587.33, 698.46, 880][Math.min(3, Math.floor(t / 0.055))];
        phase += (tau * note) / sr;
        v =
          (Math.sin(phase) + 0.22 * Math.sin(phase * (theme === 'vegetables' ? 3.98 : 3))) *
          0.25 *
          Math.exp(-7 * t);
      } else if (event === 'bomb') {
        // A short crack and midrange harmonics carry the boom on phone speakers.
        phase += tau * (62 + 134 * Math.exp(-17 * t)) / sr;
        rumble += 0.18 * (noise - rumble);
        const body = Math.sin(phase) + 0.42 * Math.sin(phase * 3) + 0.22 * Math.sin(phase * 5);
        v = 0.46 * body * Math.exp(-7 * t) + 0.52 * hi * Math.exp(-52 * t)
          + 0.75 * rumble * Math.exp(-8 * t);
        v = Math.tanh(v);
      } else if (event === 'miss') v = 0.29 * Math.sin(tau * (145 - 350 * t) * t) * Math.exp(-19 * t);
      else if (theme === 'gadgets') {
        phase += (tau * 610 * 2 ** (-Math.min(4, Math.floor(t / 0.023)) / 4)) / sr;
        v = (Math.sin(phase) + Math.sin(phase * 3) / 3) * 0.38 * Math.exp(-27 * t);
      } else if (theme === 'vegetables') {
        const snap =
          Math.exp(-110 * t) +
          0.7 * Math.exp(-140 * Math.abs(t - 0.026)) +
          0.4 * Math.exp(-120 * Math.abs(t - 0.051));
        v = 0.26 * hi * snap + 0.39 * Math.sin(tau * 249 * t) * Math.exp(-43 * t);
      } else
        v =
          (0.42 * Math.sin(tau * (190 + 240 * Math.exp(-50 * t)) * t) + 0.24 * noise) *
          Math.exp(-33 * t);
      data[i] = v * Math.min(1, t * 700, (duration - t) * 250);
    }
    return buffer;
  }
}
