// Instanced WebGL2 port of the native Juice.metal stain and droplet pass.
const vertex = `#version 300 es
layout(location=0) in vec4 rect;
layout(location=1) in vec4 ink;
layout(location=2) in vec4 motion;
layout(location=3) in float kind;
uniform vec2 viewport;
out vec2 uv; flat out vec4 tint; flat out vec4 params; flat out float type;
void main(){
  uv=vec2((gl_VertexID&1)==0?-1.:1.,(gl_VertexID&2)==0?-1.:1.);
  float c=cos(motion.x),s=sin(motion.x);
  vec2 p=rect.xy+mat2(c,s,-s,c)*(uv*rect.zw);
  gl_Position=vec4(p/viewport*vec2(2.,-2.)+vec2(-1.,1.),0.,1.);
  tint=ink;params=motion;type=kind;
}`;
const fragment = `#version 300 es
precision highp float;
in vec2 uv; flat in vec4 tint; flat in vec4 params; flat in float type; out vec4 outputColor;
void main(){vec2 p = uv;
    float life = tint.a, age = params.z, seed = params.y, heat = params.w;
    vec3 ink = tint.rgb;
    float alpha;
    if (type < 0.5) {
        // A deposited puddle spreads quickly. Narrow fingers break into satellite beads.
        float spread = .48 + .52 * smoothstep(0., .14, age);
        p /= spread;
        float angle = atan(p.y,p.x);
        float radius = length(p);
        float ripple = sin(angle*3.+seed)*.053 + sin(angle*7.-seed)*.034 + sin(angle*11.+seed)*.018;
        float jet = pow(max(0., cos(angle*9.+seed+.85*sin(angle*3.+seed))), 9.);
        float contour = .43 + ripple + jet*(.12+.12*heat);
        float sd = radius - contour;
        float sector = floor((angle+3.14159)*2.55);
        float beads = .72 + .13*sin(sector*29.4+seed);
        float beadAngle = (sector+.5)/2.55-3.14159 + .043*sin(sector*6.3+seed);
        float bead = length(p-beads*vec2(cos(beadAngle),sin(beadAngle))) - (.022+.027*jet);
        sd = min(sd,bead);
        float aa = max(fwidth(sd),.003);
        float wet = exp(-age*1.2);
        alpha = (1.-smoothstep(-aa,aa,sd)) * smoothstep(0.,.65,life) * (.44+.32*wet);
        float edge = smoothstep(-.065,0.,sd);
        // A shallow fluid rim catches a moving specular line as the skin settles.
        float lightSide = max(0.,dot(normalize(p+vec2(.0001)), normalize(vec2(-.65,-.9))));
        float vein = .5+.5*sin(radius*34.-age*15.+3.*sin(angle*3.+seed));
        float rimLight = wet*lightSide*(edge*.46 + pow(vein,10.)*.16);
        ink *= .70+.30*(1.-edge)+.14*sin(p.x*11.+p.y*8.+seed);
        ink += vec3(.8,.72,.6)*rimLight;
        // Thin fans lift from the stain, stretch along the cut, then tear into mist.
        float flight = clamp(age/.24,0.,1.);
        float crown = .38+.57*flight + .065*sin(angle*6.+seed);
        float fan = pow(abs(cos(angle+.24*sin(angle*3.+seed))),3.);
        float sheet = (1.-smoothstep(.013,.06,abs(radius-crown))) * fan
                    * smoothstep(.0,.14,flight)*(1.-smoothstep(.28,1.,flight))*(.48+.45*heat);
        ink = mix(ink, min(vec3(1.),tint.rgb*1.3+.32), sheet);
        alpha = max(alpha,sheet);
        // Short pressure wave at the contact point, gone before the stain settles.
        float ring = (1.-smoothstep(.014,.045,abs(radius-(age*4.2+.12)))) * exp(-age*16.) * (.18+.36*heat);
        ink = mix(ink, vec3(1.,.95,.76), ring);
        alpha = max(alpha,ring);
    } else {
        // Velocity stretches the quad. A rounded head and pointed tail keep the spray directional.
        p.y /= .69+.24*p.x;
        float d = length(p);
        float aa = max(fwidth(d),.015);
        alpha = (1.-smoothstep(.88-aa,.88+aa,d))*smoothstep(0.,.30,life);
        float glint = exp(-19.*dot(p-vec2(.28,-.28),p-vec2(.28,-.28)));
        ink = ink*(.63+.42*(1.-d)) + glint*vec3(.90,.82,.64);
    }
    outputColor = vec4(clamp(ink,0.,1.)*alpha,alpha);
}`;
export function makeJuice(canvas) {
  const gl = canvas.getContext('webgl2', { alpha: true, antialias: false, depth: false });
  if (!gl) return null;
  const program = gl.createProgram();
  for (const [type, text] of [
    [gl.VERTEX_SHADER, vertex],
    [gl.FRAGMENT_SHADER, fragment],
  ]) {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, text);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      console.warn(gl.getShaderInfoLog(shader));
      return null;
    }
    gl.attachShader(program, shader);
  }
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) return null;
  gl.useProgram(program);
  const viewport = gl.getUniformLocation(program, 'viewport');
  const data = new Float32Array((36 + 112) * 13),
    buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, data.byteLength, gl.DYNAMIC_DRAW);
  for (let index = 0; index < 4; index++) {
    gl.enableVertexAttribArray(index);
    gl.vertexAttribPointer(index, index === 3 ? 1 : 4, gl.FLOAT, false, 52, index * 16);
    gl.vertexAttribDivisor(index, 1);
  }
  gl.enable(gl.BLEND);
  gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
  return (game, w, h) => {
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.clear(gl.COLOR_BUFFER_BIT);
    let count = 0;
    function add(obj, rx, ry, angle, life, type) {
      const rgb = parseInt(obj.color.slice(1), 16),
        i = count++ * 13;
      data.set(
        [
          obj.x * w,
          obj.y * h,
          rx,
          ry,
          ((rgb >> 16) & 255) / 255,
          ((rgb >> 8) & 255) / 255,
          (rgb & 255) / 255,
          life,
          angle,
          obj.seed || 0,
          game.time - obj.born,
          obj.heat || 0,
          type,
        ],
        i,
      );
    }
    const unit = Math.min(w, h);
    for (const f of game.stains)
      add(f, f.r * unit * 1.48, f.r * unit, f.angle, 1 - (game.time - f.born) / 4.5, 0);
    for (const f of game.drops)
      if (f.theme !== 'gadgets')
        add(
          f,
          f.r * unit * 1.7,
          f.r * unit * 0.62,
          Math.atan2(f.vy * h, f.vx * w),
          1 - (game.time - f.born) / f.life,
          1,
        );
    if (count) {
      gl.uniform2f(viewport, w, h);
      gl.bufferSubData(gl.ARRAY_BUFFER, 0, data, 0, count * 13);
      gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, count);
    }
  };
}
