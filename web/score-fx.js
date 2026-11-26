// Only the small score overlay is shaded. Upload a glyph mask on score changes,
// then reuse it while the highlight crosses the digits.
const vertex = `#version 300 es
out vec2 uv;
void main() {
  vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);
  uv=vec2(p.x,1.-p.y);
  gl_Position=vec4(p*2.-1.,0.,1.);
}`;
const fragment = `#version 300 es
precision mediump float;
in vec2 uv;
uniform sampler2D glyph;
uniform vec2 texel;
uniform float age;
uniform float strength;
out vec4 color;
void main() {
  float mask=texture(glyph,uv).a;
  float fade=1.-smoothstep(.18,.72,age);
  vec2 d=texel*(1.+3.*strength);
  float rim=max(max(texture(glyph,uv+vec2(d.x,0.)).a,texture(glyph,uv-vec2(d.x,0.)).a),
                max(texture(glyph,uv+vec2(0.,d.y)).a,texture(glyph,uv-vec2(0.,d.y)).a));
  float band=exp(-14.*abs(uv.x+.20*uv.y-(age*2.4-.12)));
  float a=clamp((mask*(.50+.5*band)+max(0.,rim-mask)*.75)*fade,0.,1.);
  vec3 light=mix(vec3(1.,.35,.07),vec3(1.,.94,.63),clamp(band+mask*.35,0.,1.));
  color=vec4(light*a,a);
}`;

function scoreShader(canvas) {
  const gl = canvas.getContext('webgl2', { alpha: true, depth: false, antialias: false });
  if (!gl) return null;
  const program = gl.createProgram();
  for (const [type, code] of [
    [gl.VERTEX_SHADER, vertex],
    [gl.FRAGMENT_SHADER, fragment],
  ]) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, code);
    gl.compileShader(shader);
    gl.attachShader(program, shader);
    gl.deleteShader(shader);
  }
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);
  gl.bindTexture(gl.TEXTURE_2D, gl.createTexture());
  for (const [key, value] of [
    [gl.TEXTURE_MIN_FILTER, gl.LINEAR],
    [gl.TEXTURE_MAG_FILTER, gl.LINEAR],
    [gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE],
    [gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE],
  ])
    gl.texParameteri(gl.TEXTURE_2D, key, value);
  const texel = gl.getUniformLocation(program, 'texel'),
    age = gl.getUniformLocation(program, 'age'),
    strength = gl.getUniformLocation(program, 'strength');
  return {
    upload(mask, heat) {
      gl.viewport(0, 0, mask.width, mask.height);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, mask);
      gl.uniform2f(texel, 1 / mask.width, 1 / mask.height);
      gl.uniform1f(strength, heat);
    },
    draw(elapsed) {
      gl.uniform1f(age, elapsed);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    },
  };
}

export class ScoreFeedback {
  constructor(score, canvas, field, bonus) {
    Object.assign(this, { score, canvas, field, bonus });
    this.mask = document.createElement('canvas');
    this.reduced = matchMedia('(prefers-reduced-motion: reduce)');
    this.shader = scoreShader(canvas);
    canvas.addEventListener('webglcontextlost', (e) => {
      e.preventDefault();
      this.shader = null;
    });
    canvas.addEventListener('webglcontextrestored', () => {
      this.shader = scoreShader(canvas);
    });
  }
  reset() {
    this.started = null;
    this.canvas.hidden = true;
    this.bonus.hidden = true;
    this.zoom?.cancel();
    this.pop?.cancel();
  }
  pulse({ gain, combo, boost, impact }) {
    if (gain <= 0) return;
    const power = Math.min(1, 0.16 + Math.min(gain, 24) / 50 + Math.min(combo, 8) / 16);
    this.started = performance.now();
    this.bonus.textContent = boost ? '+' + boost + ' combo boost' : '+' + gain;
    this.bonus.hidden = false;
    if (this.reduced.matches) return;
    this.pop?.cancel();
    this.pop = this.score.parentElement.animate(
      [
        { transform: 'scale(1)' },
        { transform: 'scale(' + (1.14 + 0.34 * power) + ')', offset: 0.2 },
        { transform: 'scale(.98)', offset: 0.66 },
        { transform: 'scale(1)' },
      ],
      { duration: 380, easing: 'ease-out' },
    );
    if (combo >= 3) {
      this.zoom?.cancel();
      const zoom = 1 + Math.min(0.16, 0.045 + combo * 0.012);
      this.field.style.transformOrigin = impact.x * 100 + '% ' + impact.y * 100 + '%';
      this.zoom = this.field.animate(
        [
          { transform: 'scale(1)' },
          { transform: 'scale(' + zoom + ')', offset: 0.2 },
          { transform: 'scale(1.012)', offset: 0.75 },
          { transform: 'scale(1)' },
        ],
        { duration: 420, easing: 'ease-out' },
      );
    }
    if (!this.shader) return;
    const node = this.score,
      style = getComputedStyle(node),
      pad = 9,
      ratio = Math.min(2, devicePixelRatio || 1);
    const width = node.offsetWidth + 2 * pad,
      height = node.offsetHeight + 2 * pad;
    for (const c of [this.canvas, this.mask]) {
      c.width = Math.ceil(width * ratio);
      c.height = Math.ceil(height * ratio);
    }
    this.canvas.style.width = width + 'px';
    this.canvas.style.height = height + 'px';
    this.canvas.hidden = false;
    const ctx = this.mask.getContext('2d');
    ctx.scale(ratio, ratio);
    ctx.font = style.fontWeight + ' ' + style.fontSize + ' ' + style.fontFamily;
    if ('letterSpacing' in ctx) ctx.letterSpacing = style.letterSpacing;
    ctx.textBaseline = 'middle';
    ctx.fillStyle = 'white';
    ctx.fillText(node.textContent, pad, height / 2);
    this.shader.upload(this.mask, power);
  }
  draw(now) {
    if (this.started == null) return;
    const elapsed = (now - this.started) / 1000;
    if (elapsed >= 0.95) {
      this.reset();
      return;
    }
    if (!this.canvas.hidden) {
      if (elapsed > 0.72) this.canvas.hidden = true;
      else this.shader?.draw(elapsed);
    }
  }
}
