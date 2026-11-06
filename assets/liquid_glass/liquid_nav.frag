#version 460 core
// Liquid glass backdrop for the floating navigation bar.
//
// Rendered as an `ImageFilter.shader` filter: the engine binds the first
// vec2 uniform to the size of the filter input and the first sampler2D to the
// filter input itself, so this shader only displaces what the layer below has
// already painted. Nothing is cached per frame.
#include <flutter/runtime_effect.glsl>

// Set by the engine: size of the bound texture, in pixels.
uniform vec2 u_size;

// Rect of the capsule inside the filter input, in the same space as
// FlutterFragCoord(): (x, y, width, height), pixels.
uniform vec4 u_rect;

// Corner radius of the capsule, pixels.
uniform float u_radius;

// Width of the refractive rim, pixels.
uniform float u_band;

// Peak outward displacement at the rim, pixels.
uniform float u_refract;

// Interior magnification. 0 keeps the centre untouched, which is what the
// reference does: the middle shows the page detail and only the rim bends it.
uniform float u_zoom;

// 1.0 paints the region outside the capsule red, so the lab screen can prove
// that u_rect lands in the coordinate space FlutterFragCoord() uses.
uniform float u_debug;

uniform sampler2D u_texture;

out vec4 fragColor;

float roundedBox(vec2 p, vec2 halfSize, float radius) {
  vec2 q = abs(p) - halfSize + vec2(radius);
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 halfSize = u_rect.zw * 0.5;
  vec2 center = u_rect.xy + halfSize;
  vec2 p = frag - center;
  float radius = min(u_radius, min(halfSize.x, halfSize.y));

  float d = roundedBox(p, halfSize, radius); // < 0 inside the capsule

  // Normal of the distance field, pointing outwards. Central differences keep
  // it correct on the straight edges and around the caps.
  const float e = 0.75;
  float dx = roundedBox(p + vec2(e, 0.0), halfSize, radius) -
      roundedBox(p - vec2(e, 0.0), halfSize, radius);
  float dy = roundedBox(p + vec2(0.0, e), halfSize, radius) -
      roundedBox(p - vec2(0.0, e), halfSize, radius);
  vec2 n = vec2(dx, dy);
  n /= max(length(n), 1e-4);

  // 0 on the rim, 1 once we are u_band inside.
  float inner = clamp(-d / max(u_band, 0.001), 0.0, 1.0);
  float rim = 1.0 - inner;
  rim *= rim;

  // The rim pulls the world just outside the capsule inwards, which is what
  // makes the top and bottom edges look stretched in the reference. The middle
  // only gets a very slight magnification so it stays readable.
  vec2 samplePos = center + p * (1.0 - u_zoom * inner) + n * (u_refract * rim);

  vec2 uv = samplePos / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  // GLES samples the input texture bottom-up.
  uv.y = 1.0 - uv.y;
#endif
  uv = clamp(uv, vec2(0.0), vec2(1.0));

  vec4 sampled = texture(u_texture, uv);
  // The backdrop snapshot is premultiplied: near the capsule edge a blur can
  // leave alpha < 1, and taking .rgb as-is would darken the rim into a grey
  // ring. Restore the un-premultiplied colour; the material stays opaque.
  vec3 sampledRgb = sampled.a > 0.0
      ? sampled.rgb / sampled.a
      : sampled.rgb;

  if (u_debug > 0.5 && d > 0.0) {
    fragColor = vec4(1.0, 0.0, 0.0, 1.0);
    return;
  }

  // The filtered backdrop replaces the backdrop, so this has to stay opaque:
  // the tint and the highlight are painted by the widget above it.
  fragColor = vec4(clamp(sampledRgb, 0.0, 1.0), 1.0);
}
