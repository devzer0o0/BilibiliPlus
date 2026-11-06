#!/usr/bin/env python3
"""PiliPlus app icon: procedurally rendered polished-gold bilibili TV.

The shape is traced from the physical "100万粉丝" medal unboxed in
"B站100万粉丝奖牌开箱 & 评测｜大耳朵TV" (BV1afN7zeEJ7): a wide rounded
golden TV with two short antennas, a sunken screen frame, two short round
tilted eye bars and an omega mouth.  No feet, no knobs, no speaker grille.

Everything is generated from this file - there is no hidden bitmap source:
  * body       rounded-box SDF, 1.19 x 1.00 x 0.24, bevel 0.074
  * screen     inset rounded rect, recessed 0.030, with its own shallow dome
  * eyes       rounded golden bars (0.042 radius) tilted +/-14 deg, pitched 9 deg
  * mouth      omega ridge built from a mirrored cubic bezier
  * antennas   capsules leaning +/-23 deg

Shading is a small metallic GGX/IBL renderer: a procedural studio environment
(soft window, rim strip, warm floor bounce, cool fill) plus three direct
specular lights.  The front-face relief is shaded from an analytic height
field.  Output is linear -> ACES -> sRGB with a mild saturation grade.

Run:
  python3 tool/app_icon/render_icon.py --master ... --icon ... --transparent ...

Requires Pillow and numpy (see tool/app_icon/README.md).
"""
import argparse, json, math

import numpy as np
from PIL import Image, ImageCms

# ----------------------------------------------------------------------------
# scene constants
# ----------------------------------------------------------------------------
W_BODY, H_BODY, D_BODY = 1.19, 1.00, 0.24
BEVEL, R2D = 0.074, 0.086
FRONT = D_BODY / 2.0
BODY_FRAC = 0.770
CAM_Z, CAM_Y = 8.0, 0.075
FRAME_HALF = W_BODY / (2.0 * BODY_FRAC)
TAN_HALF = FRAME_HALF / (CAM_Z - FRONT)

SCREEN_HX, SCREEN_HY, SCREEN_R = 0.465, 0.370, 0.135
SCREEN_DEPTH, SCREEN_FILLET = 0.030, 0.010

EYE_R = 0.042
EYE_HALF = 0.1020          # half length of the straight segment
EYE_CX, EYE_CY = 0.228, 0.038
EYE_TILT = math.radians(14.0)
EYE_H, EYE_FILLET = 0.012, 0.017
EYE_Z = FRONT + 0.004
EYE_HALF_H, EYE_ROUND, EYE_PITCH = 0.030, 0.012, math.radians(-9.0)
DOME = 0.030

MOUTH_A, MOUTH_B = 0.185, 0.060
MOUTH_CX, MOUTH_CY = 0.195, -0.128
MOUTH_W, MOUTH_H = 0.0170, 0.0170      # ridge half-width, height

ANT_R = 0.037
ANT_LEN = 0.290
ANT_TILT = math.radians(23.0)
ANT_BASE = (0.285, 0.410, 0.015)

F0 = np.array([1.00, 0.670, 0.235], dtype=np.float32)   # polished gold
ROUGH_PANEL, ROUGH_BODY = 0.130, 0.175

# ----------------------------------------------------------------------------
# SDF
# ----------------------------------------------------------------------------
def sd_round_rect2(x, y, hx, hy, r):
    qx = np.abs(x) - hx + r
    qy = np.abs(y) - hy + r
    return (np.hypot(np.maximum(qx, 0.0), np.maximum(qy, 0.0))
            + np.minimum(np.maximum(qx, qy), 0.0) - r)


def sd_body(x, y, z):
    bx, by = W_BODY / 2 - BEVEL, H_BODY / 2 - BEVEL
    hz = D_BODY / 2 - BEVEL
    d2 = sd_round_rect2(x, y, bx, by, R2D)
    qz = np.abs(z) - hz
    return (np.hypot(np.maximum(d2, 0.0), np.maximum(qz, 0.0))
            + np.minimum(np.maximum(d2, qz), 0.0) - BEVEL)


def sd_capsule(p, a, b, r):
    ax, ay, az = a
    bx, by, bz = b
    pax, pay, paz = p[0] - ax, p[1] - ay, p[2] - az
    bax, bay, baz = bx - ax, by - ay, bz - az
    h = np.clip((pax * bax + pay * bay + paz * baz) / (bax * bax + bay * bay + baz * baz), 0.0, 1.0)
    dx, dy, dz = pax - bax * h, pay - bay * h, paz - baz * h
    return np.hypot(np.hypot(dx, dy), dz) - r


def ant_endpoints(sign):
    bx, by, bz = ANT_BASE
    bx *= sign
    ex = bx + sign * ANT_LEN * math.sin(ANT_TILT)
    ey = by + ANT_LEN * math.cos(ANT_TILT)
    ez = bz + 0.045
    return (bx, by, bz), (ex, ey, ez)


def sd_eye3d(x, y, z, sign):
    ang = EYE_TILT * (-sign)
    cx, cy = sign * EYE_CX, EYE_CY
    c, s = math.cos(ang), math.sin(ang)
    dx, dy = x - cx, y - cy
    u = c * dx + s * dy
    v = -s * dx + c * dy
    w = z - EYE_Z
    cp, sp = math.cos(EYE_PITCH), math.sin(EYE_PITCH)
    v, w = v * cp + w * sp, -v * sp + w * cp
    bx = EYE_HALF + EYE_R - EYE_ROUND
    by = EYE_R - EYE_ROUND
    bz = EYE_HALF_H - EYE_ROUND
    qx = np.abs(u) - bx
    qy = np.abs(v) - by
    qz = np.abs(w) - bz
    return (np.hypot(np.hypot(np.maximum(qx, 0.0), np.maximum(qy, 0.0)), np.maximum(qz, 0.0))
            + np.minimum(np.maximum(np.maximum(qx, qy), qz), 0.0) - EYE_ROUND)


def sdf_scene(x, y, z):
    d = sd_body(x, y, z)
    for sign in (-1.0, 1.0):
        d = np.minimum(d, sd_eye3d(x, y, z, sign))
    for sign in (-1.0, 1.0):
        a, b = ant_endpoints(sign)
        d = np.minimum(d, sd_capsule((x, y, z), a, b, ANT_R))
    return d


def sdf(x, y, z):
    return sdf_scene(x, y, z)


# ----------------------------------------------------------------------------
# front face relief: screen recess, eyes, mouth
# ----------------------------------------------------------------------------
def sd_eye(x, y, sign):
    ang = EYE_TILT * (-sign)          # left eye "/", right eye "\"
    c, s = math.cos(ang), math.sin(ang)
    dx = x - sign * EYE_CX
    dy = y - EYE_CY
    u = c * dx + s * dy
    v = -s * dx + c * dy
    hx = EYE_HALF + EYE_R
    return sd_round_rect2(u, v, hx, EYE_R, EYE_R)


_MOUTH_PTS = None


def mouth_points():
    """Omega ridge centreline: one smooth bowl mirrored about x=0."""
    global _MOUTH_PTS
    if _MOUTH_PTS is None:
        # cubic bezier, in mouth-local coordinates (y relative to MOUTH_CY)
        P = np.array([[-0.185, 0.060], [-0.190, -0.100], [-0.060, -0.100], [0.0, 0.0]], np.float32)
        t = np.linspace(0.0, 1.0, 17, dtype=np.float32)[:, None]
        u = 1.0 - t
        xy = (u ** 3) * P[0] + 3 * (u ** 2) * t * P[1] + 3 * u * (t ** 2) * P[2] + (t ** 3) * P[3]
        xy[:, 1] += MOUTH_CY
        right = np.stack([-xy[::-1, 0], xy[::-1, 1]], axis=1)[1:]
        _MOUTH_PTS = np.concatenate([xy, right], axis=0).astype(np.float32)
    return _MOUTH_PTS


def sd_mouth(x, y):
    pts = mouth_points()
    ax, ay = pts[:-1, 0], pts[:-1, 1]
    bx, by = pts[1:, 0], pts[1:, 1]
    d = np.full_like(x, 1e9, dtype=np.float32)
    for i in range(ax.shape[0]):
        pax, pay = x - ax[i], y - ay[i]
        dx, dy = bx[i] - ax[i], by[i] - ay[i]
        h = np.clip((pax * dx + pay * dy) / (dx * dx + dy * dy), 0.0, 1.0)
        ex, ey = pax - dx * h, pay - dy * h
        d = np.minimum(d, np.hypot(ex, ey))
    return d


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def height(x, y):
    # gently domed stamped face: makes the polished reflections sweep
    rr = (x / (W_BODY / 2)) ** 2 + (y / (H_BODY / 2)) ** 2
    h = DOME * (1.0 - np.clip(rr, 0.0, 1.0))
    d_screen = sd_round_rect2(x, y, SCREEN_HX, SCREEN_HY, SCREEN_R)
    h = h - SCREEN_DEPTH * smoothstep(0.0, -SCREEN_FILLET, d_screen)
    # the screen itself is a slightly domed mirror
    panel = smoothstep(0.0, -SCREEN_FILLET, d_screen)
    prr = (x / SCREEN_HX) ** 2 + (y / SCREEN_HY) ** 2
    h = h + 0.005 * panel * (1.0 - np.clip(prr, 0.0, 1.0))
    # narrow groove outlining the screen frame

    dm = sd_mouth(x, y)
    u = np.clip(dm / (MOUTH_W + 0.008), 0.0, 1.0)
    h = h + MOUTH_H * (1.0 - u * u) ** 1.5
    return h


# ----------------------------------------------------------------------------
# environment (studio)
# ----------------------------------------------------------------------------
ENV_W, ENV_H = 1536, 768


def build_env():
    u = (np.arange(ENV_W) + 0.5) / ENV_W
    v = (np.arange(ENV_H) + 0.5) / ENV_H
    lon = (u - 0.5) * 2 * np.pi
    lat = (0.5 - v) * np.pi
    cl = np.cos(lat)[:, None]
    dirs = np.stack([cl * np.sin(lon)[None, :],
                     np.sin(lat)[:, None] * np.ones((1, ENV_W)),
                     -cl * np.cos(lon)[None, :]], axis=-1).astype(np.float32)

    warm = np.array([1.0, 0.875, 0.700], np.float32)
    cool = np.array([0.82, 0.89, 1.0], np.float32)

    def local(c, roll=0.0):
        c = np.asarray(c, np.float32)
        c = c / np.linalg.norm(c)
        r = np.cross(np.array([0.0, 1.0, 0.0], np.float32), c)
        r = r / np.linalg.norm(r)
        up = np.cross(c, r)
        if roll:
            cr, sr = math.cos(roll), math.sin(roll)
            r, up = r * cr + up * sr, -r * sr + up * cr
        dc = dirs[..., 0] * c[0] + dirs[..., 1] * c[1] + dirs[..., 2] * c[2]
        du = dirs[..., 0] * r[0] + dirs[..., 1] * r[1] + dirs[..., 2] * r[2]
        dv = dirs[..., 0] * up[0] + dirs[..., 1] * up[1] + dirs[..., 2] * up[2]
        return dc, np.abs(du / np.maximum(dc, 0.02)), np.abs(dv / np.maximum(dc, 0.02))

    def panel(c, hx, hy, soft, rad, tint, grad=0.0):
        dc, a, b = local(c)
        m = (smoothstep(hx + soft, hx - soft, a)
             * smoothstep(hy + soft, hy - soft, b)
             * smoothstep(-0.25, 0.02, dc))
        g = 1.0 + grad * (1.0 - np.clip(b / hy, 0.0, 1.0))
        return (m * g * rad)[..., None] * tint

    room = (0.22 + 0.06 * np.clip(dirs[..., 1:2], -1.0, 1.0)) * warm[None, None, :]
    env = room.astype(np.float32)
    env += panel((-0.14, 0.04, 1.00), 1.00, 0.80, 0.18, 0.80, warm, grad=0.38)
    env += panel((-0.36, 0.32, 0.92), 0.40, 0.28, 0.12, 0.55, warm)
    env += panel((0.82, 0.02, 0.70), 0.55, 0.50, 0.22, 0.22, cool)
    env += panel((0.01, 0.95, 0.25), 1.20, 0.05, 0.03, 1.90, warm)
    env += panel((-0.10, -0.95, 0.40), 1.20, 0.30, 0.25, 0.30, warm)
    return env


def _box_blur(a, radius, axis):
    if radius < 1:
        return a
    pad = [(0, 0)] * a.ndim
    pad[axis] = (radius, radius)
    ap = np.pad(a, pad, mode='reflect' if axis == 0 else 'wrap')
    c = np.cumsum(ap, axis=axis, dtype=np.float32)
    c = np.concatenate([np.zeros_like(np.take(c, [0], axis=axis)), c], axis=axis)
    n = a.shape[axis]
    hi = np.take(c, np.arange(2 * radius + 1, 2 * radius + 1 + n), axis=axis)
    lo = np.take(c, np.arange(0, n), axis=axis)
    return (hi - lo) / (2 * radius + 1)


def prefilter(env):
    levels = [env]
    cur = env
    for sigma in (1.6, 3.2, 6.0, 10.0, 17.0, 28.0, 46.0):
        r = max(1, int(round(sigma * 0.9)))
        cur = _box_blur(cur, r, 0)
        cur = _box_blur(cur, r, 1)
        levels.append(cur)
    return levels


def sample_env(levels, dirs, level):
    lon = np.arctan2(dirs[:, 0], -dirs[:, 2])
    lat = np.arcsin(np.clip(dirs[:, 1], -1.0, 1.0))
    u = (lon / (2 * np.pi) + 0.5) % 1.0
    v = np.clip(0.5 - lat / np.pi, 0.0, 1.0)
    fx = u * ENV_W - 0.5
    fy = v * ENV_H - 0.5
    x0 = np.floor(fx).astype(np.int32)
    y0 = np.floor(fy).astype(np.int32)
    tx = (fx - x0)[:, None]
    ty = (fy - y0)[:, None]
    x0m, x1m = x0 % ENV_W, (x0 + 1) % ENV_W
    y0m = np.clip(y0, 0, ENV_H - 1)
    y1m = np.clip(y0 + 1, 0, ENV_H - 1)
    e = levels[level]
    c00 = e[y0m, x0m]
    c10 = e[y0m, x1m]
    c01 = e[y1m, x0m]
    c11 = e[y1m, x1m]
    return ((c00 * (1 - tx) + c10 * tx) * (1 - ty)
            + (c01 * (1 - tx) + c11 * tx) * ty)


# ----------------------------------------------------------------------------
# camera / march
# ----------------------------------------------------------------------------
def make_rays(size):
    p = (np.arange(size) + 0.5) / size
    u = p * 2 - 1
    v = 1 - p * 2
    uu, vv = np.meshgrid(u, v)
    uu = uu.ravel().astype(np.float32)
    vv = vv.ravel().astype(np.float32)
    # points on plane z=FRONT
    px = uu * FRAME_HALF
    py = CAM_Y + vv * FRAME_HALF
    d = np.stack([px, py - CAM_Y, np.full_like(px, FRONT - CAM_Z)], axis=1)
    d /= np.linalg.norm(d, axis=1, keepdims=True)
    return d.astype(np.float32)


def ray_box(d, lo, hi):
    o = np.array([0.0, CAM_Y, CAM_Z], np.float32)
    inv = 1.0 / d
    t0 = (lo - o) * inv
    t1 = (hi - o) * inv
    tmin = np.max(np.minimum(t0, t1), axis=1)
    tmax = np.min(np.maximum(t0, t1), axis=1)
    return tmin, tmax


def march(d, tmin, tmax):
    n = d.shape[0]
    hit = np.zeros(n, bool)
    pos = np.zeros((n, 3), np.float32)
    act = np.arange(n)
    t = np.maximum(tmin, 0.0).astype(np.float32)
    eps = 0.00035
    for _ in range(260):
        if act.size == 0:
            break
        da = d[act]
        p = np.array([0.0, CAM_Y, CAM_Z], np.float32)[None, :] + t[:, None] * da
        s = sdf(p[:, 0], p[:, 1], p[:, 2])
        nh = s < eps
        if nh.any():
            idx = act[nh]
            hit[idx] = True
            pos[idx] = p[nh]
        t = t + np.maximum(s, eps)
        keep = ~nh & (t < tmax[act])
        act = act[keep]
        t = t[keep]
    return hit, pos


def normals(p):
    k = np.array([[1, -1, -1], [-1, -1, 1], [-1, 1, -1], [1, 1, 1]], np.float32)
    n = np.zeros_like(p)
    for kk in k:
        n += kk[None, :] * sdf(p[:, 0] + kk[0] * 0.0007,
                               p[:, 1] + kk[1] * 0.0007,
                               p[:, 2] + kk[2] * 0.0007)[:, None]
    return n / np.linalg.norm(n, axis=1, keepdims=True)


def ambient_occlusion(p, n):
    occ = np.zeros(p.shape[0], np.float32)
    sca = 1.0
    for i in range(1, 6):
        h = 0.012 + 0.055 * i / 5.0
        d = sdf(p[:, 0] + n[:, 0] * h, p[:, 1] + n[:, 1] * h, p[:, 2] + n[:, 2] * h)
        occ += (h - d) * sca
        sca *= 0.75
    return np.clip(1.0 - 2.2 * occ, 0.0, 1.0)


# ----------------------------------------------------------------------------
# direct studio lights (small highlights on top of the soft env)
# ----------------------------------------------------------------------------
KEY_L = np.array([-0.42, 0.55, 0.72], np.float32)
FILL_L = np.array([0.72, -0.05, 0.69], np.float32)
RIM_L = np.array([0.02, 0.92, -0.39], np.float32)


def direct_spec(n, v, light_dir, intensity, tint, rough):
    l = light_dir / np.linalg.norm(light_dir)
    ndl = np.clip(n @ l, 0.0, 1.0)
    ndv = np.clip(np.sum(n * v, axis=1), 1e-4, 1.0)
    h = l[None, :] + v
    h /= np.linalg.norm(h, axis=1, keepdims=True)
    ndh = np.clip(np.sum(n * h, axis=1), 1e-4, 1.0)
    vdh = np.clip(np.sum(v * h, axis=1), 1e-4, 1.0)
    a = rough * rough
    a2 = a * a
    den = (ndh * ndh * (a2 - 1.0) + 1.0) ** 2
    D = a2 / (np.pi * den)
    G = 1.0 / (ndv + np.sqrt(a2 + (1 - a2) * ndv * ndv))
    F = F0[None, :] + (1 - F0[None, :]) * (1 - vdh[:, None]) ** 5
    spec = F * tint[None, :] * (D * G * ndl / (4.0 * ndv + 1e-4))[:, None] * intensity
    return spec


# ----------------------------------------------------------------------------
# shading
# ----------------------------------------------------------------------------
def shade(p, n, d, levels):
    v = -d
    ndv = np.clip(np.sum(n * v, axis=1), 1e-4, 1.0)
    face = sd_round_rect2(p[:, 0], p[:, 1], W_BODY / 2 - BEVEL, H_BODY / 2 - BEVEL, R2D)
    on_body = sd_body(p[:, 0], p[:, 1], p[:, 2]) < 0.0008
    w = smoothstep(0.02, 0.0, face) * on_body.astype(np.float32)
    hx = 0.0014
    h = height(p[:, 0], p[:, 1])
    hxp = height(p[:, 0] + hx, p[:, 1])
    hxm = height(p[:, 0] - hx, p[:, 1])
    hyp = height(p[:, 0], p[:, 1] + hx)
    hym = height(p[:, 0], p[:, 1] - hx)
    nh = np.stack([-(hxp - hxm) / (2 * hx), -(hyp - hym) / (2 * hx), np.ones_like(h)], axis=1)
    nh /= np.linalg.norm(nh, axis=1, keepdims=True)
    n = n * (1 - w[:, None]) + nh * w[:, None]
    n /= np.linalg.norm(n, axis=1, keepdims=True)

    is_eye = (~on_body) & (p[:, 2] > FRONT + 0.001)
    on_panel = (face < -0.004) & (w > 0.5)
    rough = np.where(on_panel, ROUGH_PANEL, ROUGH_BODY)
    rough = np.where(is_eye, 0.165, rough)
    lvl = np.clip((rough / 0.20 * 4.0).astype(np.int32), 0, len(levels) - 1)

    ndv = np.clip(np.sum(n * v, axis=1), 1e-4, 1.0)
    R = 2 * np.sum(n * v, axis=1)[:, None] * n - v
    R /= np.linalg.norm(R, axis=1, keepdims=True)
    env = np.zeros_like(R)
    for l in np.unique(lvl):
        m = lvl == l
        env[m] = sample_env(levels, R[m], int(l))
    ao = ambient_occlusion(p, n)
    # screen wall + relief contact ao
    dscr = sd_round_rect2(p[:, 0], p[:, 1], SCREEN_HX, SCREEN_HY, SCREEN_R)
    ao *= 1.0 - 0.34 * np.exp(-((dscr + 0.012) / 0.016) ** 2) * (dscr < 0) * w
    dm = sd_mouth(p[:, 0], p[:, 1]) - MOUTH_W
    ao *= 1.0 - 0.18 * np.exp(-((dm - 0.006) / 0.010) ** 2)
    de2 = np.minimum(sd_eye(p[:, 0], p[:, 1], -1.0), sd_eye(p[:, 0], p[:, 1], 1.0))
    ring = np.exp(-((de2 - 0.008) / 0.008) ** 2)
    cast_eye = 1.0 - 0.55 * ring
    de2s = np.minimum(sd_eye(p[:, 0] - 0.012, p[:, 1] + 0.012, -1.0),
                      sd_eye(p[:, 0] - 0.012, p[:, 1] + 0.012, 1.0))
    cast_eye *= 1.0 - 0.45 * smoothstep(0.000, -0.012, de2s)

    # directional contact shadow cast by the mouth ridge (key is upper-left)
    dm_s = (sd_mouth(p[:, 0] - 0.014, p[:, 1] + 0.014) - MOUTH_W * 1.2) * w
    cast = 1.0 - 0.30 * smoothstep(0.002, -0.008, dm_s)
    fres = F0[None, :] + (1 - F0[None, :]) * (1 - ndv[:, None]) ** 5
    col = fres * env * ao[:, None] * cast[:, None] * cast_eye[:, None]
    warm = np.array([1.0, 0.93, 0.84], np.float32)
    cool = np.array([0.86, 0.92, 1.0], np.float32)
    col += direct_spec(n, v, KEY_L, 2.2, warm, 0.16) * ao[:, None]
    col += direct_spec(n, v, FILL_L, 0.55, cool, 0.20) * ao[:, None]
    col += direct_spec(n, v, RIM_L, 0.9, warm, 0.18) * ao[:, None]
    col += F0[None, :] * 0.020 * env.mean(axis=1, keepdims=True) * ao[:, None]
    return col, n, h, w


# ----------------------------------------------------------------------------
# tonemap / output
# ----------------------------------------------------------------------------
def aces(x):
    a, b, c, d, e = 2.51, 0.03, 2.43, 0.59, 0.14
    return np.clip((x * (a * x + b)) / (x * (c * x + d) + e), 0.0, 1.0)


def to_srgb(x):
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.power(np.maximum(x, 0.0), 1 / 2.4) - 0.055)


def background(size):
    p = (np.arange(size) + 0.5) / size
    uu, vv = np.meshgrid(p, p)
    r = np.hypot((uu - 0.5) * 1.15, (vv - 0.46) * 1.05)
    t = np.clip(r / 0.72, 0.0, 1.0)
    edge = np.array([0.0065, 0.0065, 0.0065], np.float32)     # #151515 linear
    centre = np.array([0.0168, 0.0146, 0.0118], np.float32)   # #24211C linear
    bg = edge[None, None, :] * (1 - t[..., None]) + centre[None, None, :] * t[..., None]
    # soft contact shadow under the body
    cx, cy = 0.5, 0.5 + (0.50 - CAM_Y) / (2 * FRAME_HALF) + 0.055
    sh = np.exp(-(((uu - cx) / 0.17) ** 2 + ((vv - cy) / 0.045) ** 2) * 2.0)
    bg *= (1.0 - 0.55 * sh[..., None]).astype(np.float32)
    return bg.astype(np.float32)


EXPOSURE = 0.90


def render(size, verbose=True):
    env = build_env()
    levels = prefilter(env)
    if verbose:
        print('env ready', flush=True)
    d = make_rays(size)
    lo = np.array([-0.68, -0.55, -0.24], np.float32)
    hi = np.array([0.68, 0.78, 0.24], np.float32)
    tmin, tmax = ray_box(d, lo, hi)
    valid = (tmax > tmin) & (tmax > 0)
    vd = d[valid]
    hit, pos = march(vd, tmin[valid], tmax[valid])
    if verbose:
        print(f'march {size}px: {hit.sum()} hits of {vd.shape[0]}', flush=True)
    n = normals(pos[hit])
    col, n2, h, w = shade(pos[hit], n, vd[hit], levels)

    lin = np.zeros((size * size, 3), np.float32)
    alpha = np.zeros(size * size, np.float32)
    idx = np.nonzero(valid)[0][hit]
    lin[idx] = col
    alpha[idx] = 1.0

    bg = background(size).reshape(-1, 3)
    a = alpha[:, None]
    comp = lin * EXPOSURE + bg * (1 - a)
    return comp.reshape(size, size, 3), alpha.reshape(size, size), lin.reshape(size, size, 3)


def ios_profile():
    """Deterministic sRGB ICC profile.

    LittleCMS stamps the profile header with the current time, which would make
    every render byte-different.  Pin the creation date so repeated runs produce
    identical PNGs.
    """
    from PIL import ImageCms
    import struct
    prof = bytearray(ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes())
    prof[24:36] = struct.pack(">6H", 2025, 1, 1, 0, 0, 0)
    return bytes(prof)


def save_png(arr_srgb, path, profile=True):
    img = Image.fromarray(np.clip(arr_srgb * 255 + 0.5, 0, 255).astype(np.uint8), 'RGB')
    if profile:
        img.save(path, icc_profile=ios_profile())
    else:
        img.save(path)


SATURATION = 1.12


def grade(rgb, sat=None):
    sat = SATURATION if sat is None else sat
    lum = (0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2])[..., None]
    return np.clip(lum + (rgb - lum) * sat, 0.0, 1.0)


def block_avg(a, f):
    if f <= 1:
        return a
    h, w = a.shape[0] // f, a.shape[1] // f
    return a[:h * f, :w * f].reshape(h, f, w, f, a.shape[2]).mean(axis=(1, 3))


def save_icon(comp_linear, path, factor=1):
    buf = block_avg(comp_linear, factor)
    rgb = grade(to_srgb(aces(buf)))
    save_png(rgb, path)


def save_transparent(lin, alpha, path, factor=1):
    pm = lin * alpha[..., None]
    pm = block_avg(pm, factor)
    a = block_avg(alpha[..., None], factor)[..., 0]
    col = np.zeros_like(pm)
    nz = a > 1e-6
    col[nz] = pm[nz] / a[nz][:, None]
    rgb = grade(to_srgb(aces(col)))
    out = np.concatenate([rgb, a[..., None]], axis=2)
    img = Image.fromarray(np.clip(out * 255 + 0.5, 0, 255).astype(np.uint8), 'RGBA')
    img.save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--size', type=int, default=2048)
    ap.add_argument('--exposure', type=float, default=0.90)
    ap.add_argument('--saturation', type=float, default=1.12)
    ap.add_argument('--master', default='')
    ap.add_argument('--icon', default='')
    ap.add_argument('--icon-size', type=int, default=1024)
    ap.add_argument('--transparent', default='')
    ap.add_argument('--transparent-size', type=int, default=1024)
    a = ap.parse_args()
    global EXPOSURE, SATURATION
    EXPOSURE = a.exposure
    SATURATION = a.saturation
    comp, alpha, lin = render(a.size)
    if a.master:
        save_png(grade(to_srgb(aces(comp))), a.master)
        print('master      ', a.master)
    if a.icon:
        save_icon(comp, a.icon, a.size // a.icon_size)
        print('icon        ', a.icon)
    if a.transparent:
        save_transparent(lin, alpha, a.transparent, a.size // a.transparent_size)
        print('transparent ', a.transparent)


if __name__ == '__main__':
    main()