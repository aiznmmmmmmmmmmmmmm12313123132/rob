"""Approximate preview of tools/BuildBackgroundMountains.luau.

A straight port of the generator (Python's RNG, so the exact layout differs
from Roblox's but the style is the same), drawn with a small z-buffer
rasterizer: the painted face colours, simple daytime sun shading on top, a
distance haze standing in for Roblox's Atmosphere, and soft sprites for the
cloud particles. Not a Roblox render. Keep it in step with the Luau when
changing the design.

Usage: python3 tools/preview_mountains.py [seed] [output_dir]   (needs numpy + Pillow)
"""

import math
import random
import sys

import numpy as np
from PIL import Image

SEED = int(sys.argv[1]) if len(sys.argv) > 1 else 7310
OUT = sys.argv[2] if len(sys.argv) > 2 else "."
rng = random.Random(SEED)

ISLAND_R = 300.0
GROUND = 0.0
CLOUD_Y = GROUND - 120
CULL = -0.2

LAYERS = [
    dict(name="Near", count=9, gap=(950, 1400), height=(450, 850), spire=0.55, detail=3, haze=0.0),
    dict(name="Mid", count=14, gap=(1750, 2500), height=(520, 980), spire=0.45, detail=2, haze=0.28),
    dict(name="Far", count=20, gap=(2900, 3900), height=(600, 1150), spire=0.35, detail=1, haze=0.52),
    dict(name="Horizon", count=11, gap=(4400, 5300), height=(500, 1000), spire=0.0, detail=0, haze=0.74),
]
CLOUD_RINGS = [(450, 12), (1500, 16), (2700, 18)]
FLOOR_REACH = 6200


def rgb(r, g, b):
    return np.array([r, g, b], dtype=float) / 255


ROCK_LIT, ROCK_SHADOW = rgb(238, 164, 138), rgb(150, 96, 128)
ROCK_GLOW, ROCK_DEEP = rgb(252, 214, 200), rgb(104, 64, 98)
HAZE_TINT = rgb(236, 172, 170)
CLOUD_COLOR, FLOOR_COLOR = rgb(252, 226, 222), rgb(230, 184, 188)
HORIZON_SKY, ZENITH_SKY = rgb(245, 178, 160), rgb(140, 160, 205)

SUN = np.array([0.35, 0.75, 0.55]); SUN /= np.linalg.norm(SUN)
side = np.array([SUN[0], 0, SUN[2]]); side /= np.linalg.norm(side)
KEY = side * math.cos(math.radians(25)) + np.array([0, 1, 0]) * math.sin(math.radians(25))
VIEW = np.array([0, GROUND + 10, 0])


def lerp(a, b, t):
    return a + (b - a) * t


def direction(a):
    return np.array([math.cos(a), 0, math.sin(a)])


triangles = []  # (a, b, c, color, normal)
wedges = 0


def face_color(n, centroid, shading):
    lit = max(0.0, float(n @ KEY))
    c = lerp(ROCK_SHADOW, ROCK_LIT, lit ** 0.8)
    hf = min(max((centroid[1] - shading["base"]) / shading["height"], 0), 1)
    glow = max(min(max((n[1] - 0.2) / 0.5, 0), 1), lit * 0.5) * hf ** 1.5
    c = lerp(c, ROCK_GLOW, glow * 0.7)
    c = lerp(c, ROCK_DEEP, (1 - hf) ** 2 * 0.45)
    c = lerp(c, HAZE_TINT, shading["haze"])
    return np.clip(c + rng.uniform(-0.025, 0.025), 0, 1)


def face(a, b, c, inside, shading):
    global wedges
    centroid = (a + b + c) / 3
    n = np.cross(b - a, c - a)
    if np.linalg.norm(n) < 1e-3:
        return
    n = n / np.linalg.norm(n)
    outward = np.array([centroid[0] - inside[0], 0, centroid[2] - inside[2]])
    if n @ outward < 0:
        n = -n
    to_view = VIEW - centroid
    if n @ (to_view / np.linalg.norm(to_view)) < CULL:
        return
    triangles.append((a, b, c, face_color(n, centroid, shading), n))
    wedges += 2


def quad(a, b, c, d, inside, shading):
    if rng.random() < 0.5:
        face(a, b, c, inside, shading); face(a, c, d, inside, shading)
    else:
        face(a, b, d, inside, shading); face(b, c, d, inside, shading)


def build_cone(base, height, radius, sides, rings, power, lean, shading):
    vrings = []
    twist = rng.uniform(0, 2 * math.pi)
    bottom = CLOUD_Y - 30
    ridges = [rng.uniform(1.05, 1.35) if (s + 1) % 2 == 0 else rng.uniform(0.7, 0.92) for s in range(sides)]
    for ring in range(rings):
        t = ring / rings
        rr = radius * (1 - t) ** power
        if ring == rings - 1:
            rr *= 0.75
        rc = base + lean * height * t
        y = bottom + (base[1] + height - bottom) * t
        verts = []
        for s in range(sides):
            ang = twist + (s + rng.uniform(-0.12, 0.12)) / sides * 2 * math.pi
            reach = rr * ridges[s] * rng.uniform(0.9, 1.1)
            if ring > 0 and rng.random() < 0.15:
                reach *= 1.25
            jy = rng.uniform(-0.12, 0.12) * height / rings if ring > 0 else 0
            v = rc + direction(ang) * reach
            v[1] = y + jy
            verts.append(v)
        vrings.append(verts)
        twist += rng.uniform(-0.15, 0.15)
    apex = base + lean * height + np.array([0, height, 0])
    axis = base + lean * height * 0.5
    for ring in range(rings - 1):
        lo, up = vrings[ring], vrings[ring + 1]
        for s in range(sides):
            n = (s + 1) % sides
            quad(lo[s], lo[n], up[n], up[s], axis, shading)
    top = vrings[-1]
    for s in range(sides):
        face(top[s], top[(s + 1) % sides], apex, axis, shading)
    return apex


peaks, cloud_spots = [], []


def build_peak(layer, base):
    detail = layer["detail"]
    spire = rng.random() < layer["spire"]
    height = rng.uniform(*layer["height"])
    radius = height / (rng.uniform(2.6, 4.2) if spire else rng.uniform(1.3, 2.2))
    shading = dict(haze=layer["haze"], base=CLOUD_Y, height=height)
    lean = direction(rng.uniform(0, 2 * math.pi)) * rng.uniform(0, 0.12 if spire else 0.2)
    apex = build_cone(base, height, radius, 8 if detail >= 3 else (7 if detail == 2 else 6),
                      4 if detail >= 3 else 3, rng.uniform(0.45, 0.7) if spire else rng.uniform(0.9, 1.4), lean, shading)
    n = rng.randint(2, 3) if detail >= 3 else (rng.randint(1, 2) if detail == 2 else rng.randint(0, 1))
    for _ in range(n):
        off = direction(rng.uniform(0, 2 * math.pi)) * radius * rng.uniform(0.45, 0.9)
        build_cone(base + off, height * rng.uniform(0.3, 0.65), radius * rng.uniform(0.45, 0.7),
                   6 if detail >= 3 else 5, 3 if detail >= 3 else 2,
                   rng.uniform(0.5, 0.8) if spire else rng.uniform(0.9, 1.3),
                   lean + direction(rng.uniform(0, 2 * math.pi)) * 0.08, shading)
    return dict(position=apex, radius=radius * 0.6), radius


def build_range(layer, angle, distance):
    height = rng.uniform(*layer["height"])
    arc = height * rng.uniform(1.8, 3)
    segs = rng.randint(6, 9)
    depth = height * 0.9
    out, tan = direction(angle), direction(angle + math.pi / 2)
    shading = dict(haze=layer["haze"], base=CLOUD_Y, height=height)
    middle = out * distance
    behind = middle + out * 5000
    bots, mids, tops = [], [], []
    for i in range(segs + 1):
        s = i / segs
        along = middle + tan * (s - 0.5) * arc
        taper = math.sin(s * math.pi) ** 0.6
        ridge = rng.uniform(0.7, 1) if i % 2 == 0 else rng.uniform(0.35, 0.62)
        rh = height * max(ridge * taper, 0.12)
        sway = tan * rng.uniform(-0.3, 0.3) * arc / segs
        t = along + out * rng.uniform(0, 60) + sway
        tops.append(np.array([t[0], CLOUD_Y + rh, t[2]]))
        m = along - out * depth * 0.45 + sway * 0.5
        mids.append(np.array([m[0], CLOUD_Y + rh * rng.uniform(0.4, 0.55), m[2]]))
        b = along - out * depth
        bots.append(np.array([b[0], CLOUD_Y - 30, b[2]]))
        if ridge >= 0.7:
            peaks.append(dict(position=tops[-1], radius=arc / segs * 0.5))
    for i in range(segs):
        quad(bots[i], bots[i + 1], mids[i + 1], mids[i], behind, shading)
        quad(mids[i], mids[i + 1], tops[i + 1], tops[i], behind, shading)


def noise(x, y, z):
    return 0.3 * math.sin(2.1 * x + 1.3 * y + 0.7 * z) * math.cos(1.7 * y - 0.9 * x + z)


for li, layer in enumerate(LAYERS, start=1):
    sector = 2 * math.pi / layer["count"]
    phase = rng.uniform(0, sector)
    gmin, gmax = layer["gap"]
    for i in range(layer["count"]):
        ang = phase + (i + rng.uniform(0.15, 0.85)) * sector
        t = min(1, max(0, 0.2 + rng.random() * 0.6 + noise(math.cos(ang) * 1.5, math.sin(ang) * 1.5, SEED % 997 + li * 17.3)))
        dist = ISLAND_R + gmin + (gmax - gmin) * t
        if layer["detail"] == 0:
            build_range(layer, ang, dist)
        else:
            base = direction(ang) * dist + np.array([0, CLOUD_Y, 0])
            p, r = build_peak(layer, base)
            peaks.append(p)
            if layer["detail"] >= 2:
                cloud_spots.append((base, r))

# Clouds: sample each emitter's steady state.
emitters = []
for gap, rate in [(120, 0.45), (320, 0.3)]:
    sr = ISLAND_R + gap
    n = int(min(max(round(2 * math.pi * sr / 170), 10), 28))
    for i in range(n):
        a = (i + rng.uniform(-0.3, 0.3)) / n * 2 * math.pi
        emitters.append((direction(a) * (sr + rng.uniform(-60, 60)), 280, rate))
for pos, r in cloud_spots:
    emitters.append((np.array([pos[0], 0, pos[2]]), min(r * 3, 1600), min(max(r / 250, 0.35), 0.9)))
for gap, count in CLOUD_RINGS:
    ph = rng.uniform(0, 2 * math.pi)
    for i in range(count):
        a = ph + (i + rng.uniform(-0.3, 0.3)) / count * 2 * math.pi
        emitters.append((direction(a) * (ISLAND_R + gap + rng.uniform(-150, 150)), 800, 0.3))
reach = ISLAND_R + FLOOR_REACH
tiles = math.ceil(reach * 2 / 2048)
first = -(tiles - 1) * 2048 / 2
floor_tiles = sum(1 for ix in range(tiles) for iz in range(tiles)
                  if math.hypot(max(abs(first + ix * 2048) - 1024, 0), max(abs(first + iz * 2048) - 1024, 0)) <= reach)
puffs = []
for pos, width, rate in emitters:
    for _ in range(int(round(rate * 37.5))):
        age = rng.random()
        size = 60 + 40 * age + rng.uniform(-15, 15) * (1 - age)
        if age < 0.2:
            alpha = age / 0.2 * 0.65
        elif age <= 0.75:
            alpha = 0.65 - (age - 0.2) / 0.55 * 0.1
        else:
            alpha = 0.55 * (1 - (age - 0.75) / 0.25)
        p = pos + np.array([rng.uniform(-width / 2, width / 2), CLOUD_Y + 15 + rng.uniform(-20, 20) + age * 30,
                            rng.uniform(-width / 2, width / 2)])
        puffs.append((p, size, alpha))

print(f"faces {len(triangles)} -> wedges {wedges}; emitters {len(emitters)}; floor tiles {floor_tiles}; "
      f"total parts ~{wedges + len(emitters) + floor_tiles}; particles ~{len(puffs)}")


# ---------------------------------------------------------------- rendering

def haze_amount(dist):
    return 1 - np.exp(-np.power(np.maximum(dist, 0) / 3000.0, 1.3))


def sky(dirs):
    t = np.power(np.clip(dirs[..., 1], 0, 1), 0.5)[..., None]
    col = HORIZON_SKY * (1 - t) + ZENITH_SKY * t
    glow = np.clip(dirs @ SUN, 0, 1)[..., None] ** 30 * 0.3
    return np.clip(col + glow, 0, 1)


def render(eye, dirs, project):
    """dirs: HxWx3 unit rays; project(points Nx3) -> (x, y, dist) arrays."""
    h, w, _ = dirs.shape
    zbuf = np.full((h, w), np.inf)
    img = sky(dirs)
    shade_tris = sorted(triangles, key=lambda t: -np.linalg.norm((t[0] + t[1] + t[2]) / 3 - eye))
    for a, b, c, col, n in shade_tris:
        pts = np.array([a, b, c])
        xs, ys, ds = project(pts)
        if xs is None:
            continue
        variants = [xs]
        if project.wraps and xs.max() - xs.min() > w / 2:
            xs = np.where(xs < w / 2, xs + w, xs)
            variants = [xs, xs - w]
        lit = 0.55 + 0.55 * max(0.0, float(n @ SUN))
        for vx in variants:
            x0, x1 = int(max(math.floor(vx.min()), 0)), int(min(math.ceil(vx.max()), w - 1))
            y0, y1 = int(max(math.floor(ys.min()), 0)), int(min(math.ceil(ys.max()), h - 1))
            if x0 > x1 or y0 > y1:
                continue
            yy, xx = np.mgrid[y0:y1 + 1, x0:x1 + 1] + 0.5
            (ax, bx, cx), (ay, by, cy) = vx, ys
            den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(den) < 1e-9:
                continue
            l1 = ((by - cy) * (xx - cx) + (cx - bx) * (yy - cy)) / den
            l2 = ((cy - ay) * (xx - cx) + (ax - cx) * (yy - cy)) / den
            l3 = 1 - l1 - l2
            inside = (l1 >= -1e-6) & (l2 >= -1e-6) & (l3 >= -1e-6)
            d = l1 * ds[0] + l2 * ds[1] + l3 * ds[2]
            zb = zbuf[y0:y1 + 1, x0:x1 + 1]
            m = inside & (d < zb)
            if not m.any():
                continue
            zb[m] = d[m]
            f = haze_amount(d[m])[:, None]
            region = img[y0:y1 + 1, x0:x1 + 1]
            region[m] = np.clip(col * lit, 0, 1) * (1 - f) + HORIZON_SKY * f
    # cloud floor
    with np.errstate(divide="ignore", invalid="ignore"):
        tf = (CLOUD_Y - eye[1]) / dirs[..., 1]
    fp = eye + dirs * np.where(np.isfinite(tf), tf, 0)[..., None]
    on_floor = (tf > 0) & (np.hypot(fp[..., 0], fp[..., 2]) < reach) & (tf < zbuf)
    f = haze_amount(np.where(on_floor, tf, 0))[..., None]
    floor_col = FLOOR_COLOR * (0.58 + 0.55 * SUN[1])
    img = np.where(on_floor[..., None], floor_col * (1 - f) + HORIZON_SKY * f, img)
    zbuf = np.where(on_floor, tf, zbuf)
    # island stand-in
    with np.errstate(divide="ignore", invalid="ignore"):
        ti = (GROUND - eye[1]) / dirs[..., 1]
    ip = eye + dirs * np.where(np.isfinite(ti), ti, 0)[..., None]
    on_island = (ti > 0) & (np.hypot(ip[..., 0], ip[..., 2]) < ISLAND_R) & (ti < zbuf)
    img = np.where(on_island[..., None], rgb(96, 150, 74) * 0.95, img)
    zbuf = np.where(on_island, ti, zbuf)
    # cloud puffs, back to front
    for pos, size, alpha in sorted(puffs, key=lambda q: -np.linalg.norm(q[0] - eye)):
        xs, ys, ds = project(pos[None, :])
        if xs is None:
            continue
        x, y, dist = xs[0], ys[0], ds[0]
        r = size / 2 * project.scale(dist)
        if r < 0.7 or alpha <= 0.01:
            continue
        x0, x1 = int(max(x - 2 * r, 0)), int(min(x + 2 * r + 1, w))
        y0, y1 = int(max(y - 2 * r, 0)), int(min(y + 2 * r + 1, h))
        if x0 >= x1 or y0 >= y1:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1]
        g = np.exp(-(((xx - x) ** 2 + (yy - y) ** 2) / (2 * (r * 0.6) ** 2))) * alpha
        g = np.where(zbuf[y0:y1, x0:x1] > dist, g, 0)[..., None]
        fh = float(haze_amount(np.array(dist)))
        col = np.clip(CLOUD_COLOR * 0.95 * (1 - fh) + HORIZON_SKY * fh, 0, 1)
        img[y0:y1, x0:x1] = img[y0:y1, x0:x1] * (1 - g) + col * g
    return img


def perspective(eye, yaw_deg, pitch_deg, w=960, h=540, fov=70):
    yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
    fwd = np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)])
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    f = (h / 2) / math.tan(math.radians(fov / 2))
    xs = np.arange(w) - w / 2 + 0.5
    ys = h / 2 - np.arange(h) - 0.5
    dirs = fwd * f + right * xs[None, :, None] + up * ys[:, None, None]
    dirs /= np.linalg.norm(dirs, axis=2, keepdims=True)

    def project(p):
        v = p - eye
        z = v @ fwd
        if (z <= 1).any():
            return None, None, None
        return w / 2 + (v @ right) / z * f, h / 2 - (v @ up) / z * f, np.linalg.norm(v, axis=1)

    project.wraps = False
    project.scale = lambda dist: f / dist
    return render(eye, dirs, project)


def panorama(eye, w=2400, h=420, lo=-12, hi=40):
    az = np.linspace(0, 2 * math.pi, w, endpoint=False)
    el = np.radians(np.linspace(hi, lo, h))
    dirs = np.stack([np.sin(az)[None, :] * np.cos(el)[:, None], np.sin(el)[:, None] * np.ones((1, w)),
                     np.cos(az)[None, :] * np.cos(el)[:, None]], axis=2)

    def project(p):
        v = p - eye
        dist = np.linalg.norm(v, axis=1)
        a = np.arctan2(v[:, 0], v[:, 2]) % (2 * math.pi)
        e = np.degrees(np.arcsin(v[:, 1] / dist))
        return a / (2 * math.pi) * w, (hi - e) / (hi - lo) * h, dist

    project.wraps = True
    project.scale = lambda dist: (w / (2 * math.pi)) / dist
    return render(eye, dirs, project)


def save(img, path):
    Image.fromarray((np.clip(img, 0, 1) ** (1 / 1.1) * 255).astype(np.uint8)).save(path)


save(perspective(np.array([0.0, GROUND + 14, ISLAND_R - 40]), 0, 6), f"{OUT}/mountains-view-1.png")
save(perspective(np.array([ISLAND_R - 40, GROUND + 14, 0.0]), 90, 6), f"{OUT}/mountains-view-2.png")
save(panorama(np.array([0.0, GROUND + 14, 0.0])), f"{OUT}/mountains-panorama.png")
print("saved previews")
