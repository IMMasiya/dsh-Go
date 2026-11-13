// 语音通话's default background (ui/speech/call/call_visuals.dart): deep water
// at night. Light falls in from above in slow rays, a band of aurora drifts at
// the light's height, caustics shimmer near the surface. uEnergy brightens it
// while someone speaks; uTint and uGlow follow the light's colours.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uEnergy;
uniform float uCenter;
uniform vec3 uTint;
uniform vec3 uGlow;

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
  float v = 0.0;
  float a = 0.5;
  for (int i = 0; i < 3; i++) {
    v += a * noise(p);
    p = p * 2.07 + vec2(11.3, 5.7);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  vec2 uv = fc / uSize;
  float aspect = uSize.x / uSize.y;
  vec2 p = vec2((uv.x - 0.5) * aspect, uv.y);
  float t = uTime;

  // Deep blue above, almost black below.
  vec3 col = mix(vec3(0.030, 0.066, 0.150), vec3(0.006, 0.010, 0.028), smoothstep(-0.1, 1.0, uv.y));

  // Rays falling from above the screen.
  vec2 dp = p - vec2(0.0, -0.35);
  float an = atan(dp.x, dp.y);
  float rays = 0.5 + 0.5 * sin(an * 21.0 + t * 0.45 + sin(an * 6.0 - t * 0.3) * 1.6);
  rays *= 0.5 + 0.5 * sin(an * 8.0 - t * 0.27 + 1.3);
  rays *= smoothstep(1.05, 0.05, uv.y);
  col += mix(uTint, vec3(0.75, 0.9, 1.0), 0.35) * rays * (0.045 + uEnergy * 0.05);

  // Aurora at the light's height.
  float band = fbm(vec2(p.x * 1.6 + t * 0.045, p.y * 2.6 - t * 0.07));
  float aur = exp(-pow((uv.y - uCenter - 0.07 * (band - 0.5)) * 3.0, 2.0));
  col += mix(uTint, uGlow, band) * aur * (0.085 + uEnergy * 0.16);

  // Caustics near the surface.
  vec2 cp = p * 5.5 + vec2(0.0, t * 0.22);
  float c = abs(sin(cp.x + sin(cp.y * 1.3 + t * 0.6)) * sin(cp.y * 0.9 + sin(cp.x * 1.1 - t * 0.45)));
  col += uGlow * pow(1.0 - c, 9.0) * 0.06 * smoothstep(0.5, 0.0, uv.y);

  // Vignette, then a little dither against banding.
  float v = smoothstep(1.3, 0.3, length((uv - vec2(0.5, uCenter)) * vec2(aspect * 1.05, 1.0)));
  col *= mix(0.5, 1.0, v);
  col += (hash(fc + fract(t * 7.0)) - 0.5) / 255.0;
  fragColor = vec4(col, 1.0);
}
