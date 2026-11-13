// 语音通话's light (ui/speech/call/call_visuals.dart): a glowing drop of water
// lit from the upper left. Its edge ripples with the voice (uLevel), colour
// flows inside it, a rim of light circles it while she thinks (uThink), and it
// greys over when muted. Premultiplied output over the call's dark background.
#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform float uTime;
uniform float uLevel;
uniform float uThink;
uniform float uMuted;
uniform float uAppear;
uniform vec3 uColorA;
uniform vec3 uColorB;
uniform vec3 uColorC;

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
  for (int i = 0; i < 4; i++) {
    v += a * noise(p);
    p = p * 2.03 + vec2(17.1, 9.2);
    a *= 0.5;
  }
  return v;
}

void main() {
  vec2 fc = FlutterFragCoord().xy;
  float side = min(uSize.x, uSize.y);
  vec2 uv = (fc - 0.5 * uSize) / (0.5 * side);
  float t = uTime;
  float len = length(uv);
  float ang = atan(uv.y, uv.x);

  // Size: breathing, swelling with the voice, growing in as the call starts.
  float appear = clamp(uAppear, 0.0, 1.0);
  float R = 0.5 * (0.75 + 0.25 * appear) * (1.0 + 0.022 * sin(t * 1.25) + uLevel * 0.12 - uThink * 0.04);

  // The edge: noise around the circle (seamless), louder voice, rougher water.
  vec2 ring = vec2(cos(ang), sin(ang));
  float wob = fbm(ring * 1.5 + vec2(t * 0.35, -t * 0.27)) - 0.5;
  float wob2 = fbm(ring * 2.6 - vec2(t * 0.8, t * 0.55)) - 0.5;
  float amp = 0.028 + uLevel * 0.11;
  float r = R * (1.0 + amp * (wob * 1.7 + wob2 * uLevel * 0.8));
  float d = len - r;
  float px = 2.5 / side;
  float inside = 1.0 - smoothstep(-px, px, d);

  // A sphere's normal under the drop.
  float q = clamp(len / max(r, 1e-3), 0.0, 1.0);
  float z = sqrt(max(1.0 - q * q, 0.0));
  vec3 n = normalize(vec3(uv / max(r, 1e-3), z + 1e-3));

  // Colour flowing inside: two layers of noise folded into each other.
  vec2 flow = uv * 1.6 + vec2(sin(t * 0.31), cos(t * 0.23)) * 0.5;
  float swirl = t * (0.12 + uThink * 0.5);
  mat2 rot = mat2(cos(swirl), -sin(swirl), sin(swirl), cos(swirl));
  float f1 = fbm(rot * flow + vec2(t * 0.14, t * 0.09));
  float f2 = fbm(flow * 1.7 - vec2(t * 0.11, -t * 0.17) + f1 * 1.6);
  vec3 col = mix(uColorB, uColorA, smoothstep(0.3, 0.7, f2));
  col = mix(col, uColorC, smoothstep(0.45, 0.85, f1) * 0.8);
  // Streaks in the liquid.
  col += uColorA * pow(abs(sin(f1 * 9.0 + f2 * 4.0 + t * 0.8)), 10.0) * 0.18;

  // Light from the upper left (screen y grows downward): a gentle volume, never dark.
  vec3 L = normalize(vec3(-0.45, -0.6, 0.66));
  float diff = clamp(dot(n, L), 0.0, 1.0);
  col *= 0.78 + 0.32 * diff;

  // Glass: a darker band just inside the rim, then the rim itself lit with a
  // thin film's shifting colour, brighter with the voice.
  float band = smoothstep(0.62, 0.9, q) * (1.0 - smoothstep(0.93, 1.0, q));
  col *= 1.0 - band * 0.28;
  vec3 film = mix(uColorA, uColorC, 0.5 + 0.5 * sin(ang * 2.0 + t * 0.9));
  float fres = pow(1.0 - z, 2.6);
  col += fres * mix(film, vec3(1.0), 0.35) * (0.7 + uLevel * 0.45);

  // A soft window up-left, a small glint where light leaves down-right.
  vec3 H = normalize(L + vec3(0.0, 0.0, 1.0));
  float nh = clamp(dot(n, H), 0.0, 1.0);
  col += pow(nh, 12.0) * 0.12 + pow(nh, 140.0) * 0.5;
  vec3 L2 = normalize(vec3(0.5, 0.55, 0.65));
  col += pow(clamp(dot(n, L2), 0.0, 1.0), 60.0) * 0.18 * mix(uColorA, vec3(1.0), 0.5);

  // Its heart: brighter as the voice rises.
  col += uColorA * exp(-len * len * 6.0 / (R * R)) * (0.1 + uLevel * 0.45);

  // Thinking: a bright arc running round the rim.
  float sweep = pow(0.5 + 0.5 * cos(ang - t * 2.8), 22.0) + 0.6 * pow(0.5 + 0.5 * cos(ang + 3.14159 - t * 2.8), 40.0);
  col += sweep * fres * 2.2 * uThink;

  // The glow outside it, gone before the edge of the canvas.
  float out_ = max(d, 0.0);
  float fade = 1.0 - smoothstep(0.62, 0.98, len);
  float glow = exp(-out_ * (7.0 - uLevel * 3.0)) * (0.3 + uLevel * 0.55 + uThink * 0.12) * fade;
  float halo = exp(-out_ * 2.6) * 0.1 * fade;
  vec3 glowCol = mix(uColorB, uColorA, 0.55) * (glow + halo);
  glowCol += sweep * uThink * exp(-out_ * 14.0) * 0.6;

  // Muted: the colour drains out.
  float lum = dot(col, vec3(0.299, 0.587, 0.114));
  col = mix(col, vec3(lum) * 0.75, uMuted * 0.8);
  glowCol = mix(glowCol, vec3(dot(glowCol, vec3(0.3333))) * 0.5, uMuted * 0.8);

  float alphaOut = clamp(glow + halo, 0.0, 1.0) * 0.9;
  vec3 rgb = col * inside + glowCol * (1.0 - inside);
  float a = inside + (1.0 - inside) * alphaOut;
  fragColor = vec4(rgb * appear, a * appear);
}
