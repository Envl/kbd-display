import AppKit

/// Board coordinates are y-down. Each repeat emits its own short-lived plume.
enum FlamePlume {
    static func draw(in context: CGContext, key: CGRect, sparks: [BeamSpark], heat: Double, time: Double,
                     frame: CGImage?, hotFrame: CGImage? = nil, settings: EffectConfiguration) {
        guard time >= 0, time < 1 else { return }
        if settings.style != .classic {
            drawPlasma(in: context, key: key, sparks: sparks, heat: heat, time: time,
                       coldFrame: frame, hotFrame: hotFrame, settings: settings)
            return
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: key.midX, y: key.midY - 5)
        let start = settings[.startingFraction]
        let scale = settings[.peakScale] * (start + (1 - start) * heat)
        context.scaleBy(x: scale, y: scale)
        context.setAlpha(0.65 + 0.35 * heat)
        context.setLineCap(.round)

        if let frame {
            // Flip the texture from bitmap rows into the board's y-down coordinates.
            // Each tap gets a different lean and scale; both displays use the same burst.
            let variation = sparks.first?.lane ?? 0
            context.saveGState()
            context.scaleBy(x: variation < 0 ? -1 : 1, y: -1)
            let width = 300 + 52 * abs(variation)
            let height = 340 + 52 * (sparks.first?.reach ?? 0.5)
            context.draw(frame, in: CGRect(x: -width / 2, y: -0.11 * height, width: width, height: height))
            context.restoreGState()
        } else {
            drawWisps(in: context, sparks: sparks, time: time, colors: settings.colorParams)
        }
        // A bright, early spray and a later cloud of fine ash share the updraft.
        guard settings[.particles] else { return }
        drawParticles(in: context, sparks: sparks, heat: heat, time: time, settings: settings, plasma: false)
    }

    private static func drawPlasma(in context: CGContext, key: CGRect, sparks: [BeamSpark], heat: Double, time: Double,
                                   coldFrame: CGImage?, hotFrame: CGImage?, settings: EffectConfiguration) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.plusLighter)
        context.translateBy(x: key.midX, y: key.midY - 5)
        let start = settings[.startingFraction]
        let scale = settings[.peakScale] * (start + (1 - start) * heat)
        context.scaleBy(x: scale, y: scale)
        context.setLineCap(.round)

        let variation = sparks.first?.lane ?? 0
        let width = 315 + 56 * abs(variation)
        let height = 355 + 58 * (sparks.first?.reach ?? 0.5)
        let rect = CGRect(x: -width / 2, y: -0.12 * height, width: width, height: height)
        let colors = settings.colorParams

        // Base plasma hearth glow that shifts from ember crimson to electric blue-violet with heat.
        let envelope = sin(min(1, time * 4.5) * .pi * 0.5) * max(0, 1 - pow(time, 2.2))
        let baseColor = colors.apply(to: NSColor(srgbRed: 1.0 - 0.62 * heat,
                                                 green: 0.28 + 0.48 * heat,
                                                 blue: 0.12 + 0.88 * heat,
                                                 alpha: (0.28 + 0.34 * heat) * envelope))
        context.saveGState()
        context.setFillColor(baseColor.cgColor)
        context.setShadow(offset: .zero, blur: 24, color: baseColor.cgColor)
        context.fillEllipse(in: CGRect(x: -width * 0.26, y: -38, width: width * 0.52, height: 64))
        context.restoreGState()

        if let coldFrame {
            context.saveGState()
            context.scaleBy(x: variation < 0 ? -1 : 1, y: -1)
            context.setAlpha((0.72 + 0.28 * heat) * (1.0 - 0.38 * heat * heat))
            context.draw(coldFrame, in: rect)
            if let hotFrame, heat > 0.04 {
                context.setAlpha(min(1.0, pow(heat, 0.92) * 1.15))
                context.draw(hotFrame, in: rect.insetBy(dx: -width * 0.03 * heat, dy: -height * 0.04 * heat))
            }
            context.restoreGState()
        } else {
            drawWisps(in: context, sparks: sparks, time: time, heat: heat, plasma: true, colors: colors)
        }

        guard settings[.particles] else { return }
        drawParticles(in: context, sparks: sparks, heat: heat, time: time, settings: settings, plasma: true)
    }

    static func drawParticles(in context: CGContext, sparks: [BeamSpark], heat: Double, time: Double,
                              settings: EffectConfiguration, plasma: Bool) {
        guard !sparks.isEmpty else { return }
        let particleSize = settings[.particleSize]
        let colors = settings.colorParams
        let count = max(1, Int((Double(sparks.count) * (0.12 + 0.88 * heat)).rounded()))
        for pass in 0..<2 {
            for index in 0..<count {
                let spark = sparks[index * sparks.count / count]
                let fine = pass == 1
                let birth = spark.birth * 0.85 + (fine ? 0.15 : 0)
                let life = (time - birth) / (0.48 + 0.26 * spark.reach)
                guard life > 0, life < 1 else { continue }
                func position(_ t: Double) -> CGPoint {
                    let phase = spark.reach * 5 + Double(pass) * 2.3
                    let lane = fine ? -spark.lane : spark.lane
                    let drift = (sin(t * 7 + phase) - sin(phase)) * t * (16 + spark.width)
                    let vortex = plasma ? cos(t * 11.5 + phase) * t * (10 + 14 * heat) : 0
                    return CGPoint(x: lane * (90 + (fine ? 185 : 135) * t) + drift + vortex,
                                   y: -18 - (fine ? 40 : 0) - (175 + 180 * spark.reach) * t)
                }
                let opacity = min(1, life * 13) * (1 - life) * min(1, (1 - time) * 9)
                let p0 = position(max(0, life - (fine ? 0.016 : 0.048)))
                let p1 = position(life)
                let baseWidth = particleSize * spark.width * (fine ? 0.52 : 1.08) * (1 - 0.60 * life)

                if plasma {
                    let blueCore = max(0, (heat - 0.35) / 0.65) * (1 - min(1, life * 1.4))
                    let r = 1.0 - 0.55 * blueCore
                    let g = min(1, 0.42 + 0.50 * spark.reach + 0.35 * blueCore)
                    let b = min(1, 0.18 + 0.36 * spark.reach + 0.82 * blueCore)
                    let glowColor = colors.apply(to: NSColor(srgbRed: r, green: g, blue: b, alpha: opacity * 0.42))
                    context.setStrokeColor(glowColor.cgColor)
                    context.setLineWidth(baseWidth * 2.2)
                    context.move(to: p0)
                    context.addLine(to: p1)
                    context.strokePath()

                    let coreColor = colors.apply(to: NSColor(srgbRed: min(1, r + 0.25), green: min(1, g + 0.22), blue: b, alpha: opacity))
                    context.setStrokeColor(coreColor.cgColor)
                    context.setLineWidth(baseWidth * 0.9)
                    context.move(to: p0)
                    context.addLine(to: p1)
                    context.strokePath()

                    if !fine {
                        let headRadius = max(1.3, baseWidth * 0.72)
                        let headColor = colors.apply(to: NSColor(srgbRed: 1, green: 0.98, blue: 1, alpha: opacity * 0.95))
                        context.setFillColor(headColor.cgColor)
                        context.fillEllipse(in: CGRect(x: p1.x - headRadius, y: p1.y - headRadius,
                                                       width: headRadius * 2, height: headRadius * 2))
                    }
                } else {
                    let color = colors.apply(to: NSColor(srgbRed: 1, green: 0.46 + 0.49 * spark.reach,
                                                         blue: 0.18 + 0.32 * spark.reach, alpha: opacity))
                    context.setStrokeColor(color.cgColor)
                    context.setLineWidth(baseWidth)
                    context.move(to: p0)
                    context.addLine(to: p1)
                    context.strokePath()
                }
            }
        }
    }

    private static func drawWisps(in context: CGContext, sparks: [BeamSpark], time: Double,
                                  heat: Double = 0, plasma: Bool = false, colors: EffectColorParams = EffectColorParams()) {
        context.saveGState()
        defer { context.restoreGState() }
        // Offset the wisps in space and time so successive taps can overlap naturally.
        for (index, spark) in sparks.prefix(10).enumerated() {
            let delay = Double(index) * 0.018
            let life = (time - delay) / 0.70
            guard life >= 0, life < 1 else { continue }
            let phase = spark.reach * 2 * .pi
            let height = (110 + spark.reach * 120) * min(1, 0.20 + life * 5) * (1 - 0.34 * life)
            let width = (16 + spark.width * 1.6) * (1 - life)
            let baseX = spark.lane * 124 + sin(phase + life * 5) * 8 * life
            let baseY = -102 * life * life
            let bend = sin(phase - life * 7) * (7 + 11 * life)
            let tip = CGPoint(x: baseX + bend, y: baseY - height)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: baseX, y: baseY))
            path.addCurve(to: tip,
                          control1: CGPoint(x: baseX - width * 1.5, y: baseY - height * 0.18),
                          control2: CGPoint(x: tip.x - bend * 2.2, y: tip.y + height * 0.28))
            path.addCurve(to: CGPoint(x: baseX, y: baseY),
                          control1: CGPoint(x: tip.x + width * 0.3, y: tip.y + height * 0.32),
                          control2: CGPoint(x: baseX + width * 1.4, y: baseY - height * 0.14))
            path.closeSubpath()
            let opacity = 0.80 * (1 - life) * min(1, 0.45 + life * 6)
            let blueShift = plasma ? max(0, (heat - 0.3) / 0.7) * (1 - life * 0.7) : 0
            let color = colors.apply(to: NSColor(srgbRed: 1 - 0.45 * blueShift,
                                                 green: 0.36 + 0.46 * spark.reach + 0.25 * blueShift,
                                                 blue: 0.14 + 0.86 * blueShift, alpha: opacity))
            context.setShadow(offset: .zero, blur: plasma ? 12 : 7, color: color.withAlphaComponent(opacity * 0.55).cgColor)
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    // A rising noise field shears the flame into separate tongues. A second, slower
    // field shapes the broad body, so the fine detail travels with the rising gas.
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    float hashCell(float2 p) {
        float3 q = fract(float3(p.xyx) * float3(0.1031,0.1030,0.0973));
        q += dot(q, q.yzx + 33.33);
        return fract((q.x + q.y) * q.z);
    }

    float2 hash2(float2 p) {
        float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
        q += dot(q, q.yzx + 33.33);
        return fract((q.xx + q.yz) * q.zy);
    }

    float noise(float2 p) {
        float2 i = floor(p), f = fract(p);
        f = f*f*(3.0-2.0*f);
        return mix(mix(hashCell(i),hashCell(i+float2(1,0)),f.x),
                   mix(hashCell(i+float2(0,1)),hashCell(i+1.0),f.x),f.y);
    }

    float turbulence(float2 p) {
        return 0.56*noise(p) + 0.29*noise(p*2.13+8.4) + 0.15*noise(p*4.31+17.1);
    }

    // Cellular Voronoi distance used to pinch rising flame tongues into detached fire licks.
    float voronoi(float2 p) {
        float2 n = floor(p), f = fract(p);
        float md = 8.0;
        for (int j = -1; j <= 1; j++) {
            for (int i = -1; i <= 1; i++) {
                float2 g = float2(float(i), float(j));
                float2 o = hash2(n + g);
                float2 r = g + o - f;
                md = min(md, dot(r, r));
            }
        }
        return sqrt(md);
    }

    float2 curlWarp(float2 p, float t) {
        float e = 0.15;
        float n1 = turbulence(p + float2(0.0, e));
        float n2 = turbulence(p - float2(0.0, e));
        float n3 = turbulence(p + float2(e, 0.0));
        float n4 = turbulence(p - float2(e, 0.0));
        return float2(n1 - n2, -(n3 - n4)) / (2.0 * e);
    }

    float3 gradeFlameColor(float3 rgb, constant float4 *colorParams) {
        float hueShift = colorParams[0].w + (colorParams[2].x - 0.61018468);
        float chroma = colorParams[1].w;
        float intensity = colorParams[2].w;
        float3 c = rgb;
        if (abs(hueShift) > 1e-5) {
            float angle = hueShift * 2.0 * M_PI_F;
            float cosA = cos(angle), sinA = sin(angle);
            float3 k = float3(0.57735027);
            c = c * cosA + cross(k, c) * sinA + k * dot(k, c) * (1.0 - cosA);
        }
        if (abs(chroma - 1.0) > 1e-5) {
            float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
            c = mix(float3(luma), c, chroma);
        }
        return max(float3(0.0), c * intensity);
    }

    kernel void flame(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                      constant float4 *colorParams [[buffer(3)]],
                      uint3 id [[thread_position_in_grid]]) {
        float2 uv = (float2(id.xy)+0.5)/float(size.x);
        float t = float(id.z)/float(size.y-1);
        float x = 2.0*uv.x-1.0;
        float h = 1.0-uv.y;
        float growth = 0.31 + 0.69*(1.0-pow(1.0-saturate(t/0.32),3.0));
        float lift = 0.11+0.32*t*t;
        float y = (h-lift)/growth;
        float rise = y*3.8-t*5.7;
        float roll = turbulence(float2(x*2.7+9.0,rise*0.70));
        float sway = (roll-0.5)*(0.22+0.44*saturate(y)) + 0.065*sin(y*9.0-t*7.0);
        float2 flow = float2((x-sway)*4.7+13.0,rise);
        float folds = turbulence(flow + float2(1.35*roll,0));
        float wisps = turbulence(flow*float2(2.8,0.86) + 1.5*folds);
        float width = 0.55 - 0.29*saturate(y);
        float side = (x-sway)/width;
        float fuel = 1.0-side*side - y*1.47 + (folds-0.5)*1.35 + (wisps-0.5)*0.65;
        float base = smoothstep(-0.085,0.055,y - 0.11*side*side + 0.12*(folds-0.5));
        float shell = smoothstep(-0.12,0.29,fuel)*base;
        float hot = smoothstep(0.14,1.05,fuel+0.19*(wisps-0.5));
        float filament = smoothstep(0.5,0.78,wisps)*smoothstep(0.0,0.35,fuel);
        float3 tint = mix(float3(0.85,0.12,0.22),float3(1.0,0.45,0.055),smoothstep(-0.10,0.45,fuel));
        tint = mix(tint,float3(1.0,0.89,0.39),hot);
        tint = mix(tint,float3(1.0,0.99,0.82),saturate(hot*hot*0.78+filament*0.40));
        float halo = 0.45*exp(-3.0*side*side-4.5*(y-0.19)*(y-0.19))*smoothstep(-0.13,0.04,y);
        float fade = (0.53+0.47*smoothstep(0.0,0.07,t))*(1.0-smoothstep(0.48,1.0,t));
        fade *= smoothstep(0.0,0.06,min(uv.x,1.0-uv.x))*smoothstep(0.0,0.09,uv.y);
        float body = shell*0.94;
        float intensity = colorParams[2].w;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float a = saturate((body + halo*(1.0-body))*fade*alphaGain);
        float3 rgb = gradeFlameColor(tint*body + float3(1.0,0.24,0.10)*halo*(1.0-body), colorParams)*fade;
        pixels[(id.z*size.x+id.y)*size.x+id.x] = uchar4(float4(clamp(rgb,0.0,a),a)*255.0+0.5);
    }

    float4 evaluatePlasmaFlame(uint3 id, uint2 size, bool overheat, constant float4 *colorParams) {
        float2 uv = (float2(id.xy)+0.5)/float(size.x);
        float t = float(id.z)/float(size.y-1);
        float x = 2.0*uv.x-1.0;
        float h = 1.0-uv.y;
        float growth = 0.30 + 0.70*(1.0-pow(1.0-saturate(t/0.29),3.0));
        float lift = 0.10+0.34*t*t;
        float y = (h-lift)/growth;
        float rise = y*4.1-t*6.4;
        float2 curl = curlWarp(float2(x*2.4+5.2, rise*0.65), t);
        float roll = turbulence(float2(x*2.9+9.0, rise*0.75) + curl*0.35);
        float sway = (roll-0.5)*(0.24+0.48*saturate(y)) + 0.075*sin(y*10.5-t*8.2) + curl.x*0.09;
        float2 flow = float2((x-sway)*4.9+13.0, rise) + curl*0.55;
        float folds = turbulence(flow + float2(1.45*roll, 0.0));
        float wisps = turbulence(flow*float2(3.1, 0.92) + 1.65*folds);
        float cell = voronoi(flow*float2(0.85, 0.58) + float2(0.0, -t*2.4));
        float erosion = pow(saturate(cell), 1.65) * (0.32 + 1.18*saturate(y));
        float width = (overheat ? 0.58 : 0.54) - 0.28*saturate(y);
        float side = (x-sway)/width;
        float fuel = 1.05 - side*side - y*1.38 + (folds-0.5)*1.42 + (wisps-0.5)*0.74 - erosion;
        float base = smoothstep(-0.09, 0.05, y - 0.10*side*side + 0.13*(folds-0.5));
        float shell = smoothstep(-0.14, 0.26, fuel)*base;
        float hot = smoothstep(0.12, 0.98, fuel + 0.24*(wisps-0.5));
        float ridge = pow(1.0 - abs(2.0*wisps - 1.0), 3.0) * smoothstep(-0.05, 0.35, fuel);

        float3 tint;
        float3 haloColor;
        if (overheat) {
            // Ionized violet-crimson outer sheath -> solar gold -> blue-violet & white-hot plasma jet at base.
            float baseJet = exp(-3.4*side*side - 5.2*max(0.0f, y - 0.08)*max(0.0f, y - 0.08)) * smoothstep(-0.06, 0.08, y);
            tint = mix(float3(0.62, 0.10, 0.88), float3(1.0, 0.38, 0.12), smoothstep(-0.12, 0.38, fuel));
            tint = mix(tint, float3(1.0, 0.88, 0.36), hot);
            tint = mix(tint, float3(0.20, 0.78, 1.0), saturate(baseJet * 1.15 + ridge * 0.48));
            tint = mix(tint, float3(0.96, 0.99, 1.0), saturate(hot*hot*0.72 + baseJet*0.85 + ridge*0.42));
            haloColor = mix(float3(0.85, 0.22, 0.95), float3(0.18, 0.72, 1.0), saturate(1.0 - y * 1.4));
        } else {
            tint = mix(float3(0.88, 0.08, 0.18), float3(1.0, 0.42, 0.04), smoothstep(-0.12, 0.42, fuel));
            tint = mix(tint, float3(1.0, 0.86, 0.32), hot);
            tint = mix(tint, float3(1.0, 0.99, 0.86), saturate(hot*hot*0.82 + ridge*0.48));
            haloColor = float3(1.0, 0.26, 0.08);
        }

        float halo = 0.50*exp(-2.8*side*side-4.2*(y-0.19)*(y-0.19))*smoothstep(-0.13,0.04,y);
        float fade = (0.55+0.45*smoothstep(0.0,0.07,t))*(1.0-smoothstep(0.48,1.0,t));
        fade *= smoothstep(0.0,0.06,min(uv.x,1.0-uv.x))*smoothstep(0.0,0.09,uv.y);
        float body = shell*0.95;
        float intensity = colorParams[2].w;
        float alphaGain = abs(intensity - 1.0) < 1e-4 ? 1.0 : min(1.35, 0.35 + 0.65 * intensity);
        float a = saturate((body + halo*(1.0-body))*fade*alphaGain);
        float3 rgb = clamp(gradeFlameColor(tint*body + haloColor*halo*(1.0-body), colorParams)*fade, 0.0, a);
        return float4(rgb, a);
    }

    kernel void plasmaFlameCold(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                                constant float4 *colorParams [[buffer(3)]],
                                uint3 id [[thread_position_in_grid]]) {
        pixels[(id.z*size.x+id.y)*size.x+id.x] = uchar4(evaluatePlasmaFlame(id, size, false, colorParams)*255.0+0.5);
    }

    kernel void plasmaFlameHot(device uchar4 *pixels [[buffer(0)]], constant uint2 &size [[buffer(1)]],
                               constant float4 *colorParams [[buffer(3)]],
                               uint3 id [[thread_position_in_grid]]) {
        pixels[(id.z*size.x+id.y)*size.x+id.x] = uchar4(evaluatePlasmaFlame(id, size, true, colorParams)*255.0+0.5);
    }
    """
}
