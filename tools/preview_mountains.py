"""Approximate preview of tools/BuildBackgroundMountains.luau.

A straight port of the generator (Python's RNG, so the layout differs from
Roblox's but the style is the same), ray-traced with simple sun shading, a
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
rng = random.Random(SEED)

ISLAND_R = 300.0
GROUND = 0.0
CLOUD_DEPTH = 120
CLOUD_Y = GROUND - CLOUD_DEPTH

LAYERS = [
    dict(name="Near", count=9, gap=(950, 1400), visible=(420, 820), spire=0.6, detail=3, haze=0.0),
    dict(name="Mid", count=15, gap=(1750, 2500), visible=(500, 950), spire=0.55, detail=2, haze=0.25),
    dict(name="Far", count=22, gap=(2900, 3900), visible=(560, 1100), spire=0.5, detail=1, haze=0.48),
    dict(name="Horizon", count=12, gap=(4400, 5300), visible=(450, 950), spire=0.0, detail=0, haze=0.7),
]
CLOUD_RINGS = [(450, 12), (1500, 16), (2700, 18)]
FLOOR_REACH = 6200


def rgb(r, g, b):
    return np.array([r, g, b], dtype=float) / 255


ROCK, ROCK_LIGHT, ROCK_DARK, ROCK_BASE = rgb(128, 138, 122), rgb(152, 158, 140), rgb(106, 116, 104), rgb(102, 116, 106)
MOSS = [rgb(78, 128, 56), rgb(100, 146, 60), rgb(64, 110, 60)]
HAZE_TINT = rgb(188, 214, 198)
CLOUD_COLOR = rgb(240, 247, 242)
FLOOR_COLOR = rgb(206, 225, 215)
ATMOS_COLOR = rgb(199, 225, 176)
ZENITH = rgb(112, 176, 214)


def shade(color, haze):
    c = color + (HAZE_TINT - color) * haze
    return np.clip(c + rng.uniform(-0.03, 0.03), 0, 1)


def moss(haze):
    return shade(MOSS[rng.randint(0, 2)], haze)


def rot_y(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rot_x(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


ellipsoids = []  # (center, rotation, semi_axes, color)
peaks_info = []
cloud_spots = []
part_count = 0


def add_ellipsoid(center, rotation, size, color):
    global part_count
    size = np.minimum(np.array(size, dtype=float), 2040)
    ellipsoids.append((np.array(center, dtype=float), rotation, size / 2, color))
    part_count += 1


class Frame:
    def __init__(self, pos, rot):
        self.pos, self.rot = np.array(pos, dtype=float), rot

    def point(self, local):
        return self.pos + self.rot @ np.array(local, dtype=float)


def half_width_at(lobe, y):
    c, size = lobe["center"], lobe["size"]
    d = (y - c[1]) / (size[1] / 2)
    if abs(d) >= 1:
        return 0.0
    return min(size[0], size[2]) / 2 * math.sqrt(1 - d * d)


def top_of(lobe):
    return lobe["center"][1] + lobe["size"][1] / 2


def sculpt_add(frame, center, size, color):
    lobe = dict(center=np.array(center, dtype=float), size=np.array(size, dtype=float), yaw=rng.uniform(0, 2 * math.pi))
    add_ellipsoid(frame.point(center), frame.rot @ rot_y(lobe["yaw"]), size, color)
    return lobe


def sculpt_crown(frame, lobe, thickness, lip, color):
    depth = lobe["size"][1] / 2 * thickness
    rim = top_of(lobe) - depth
    d = (rim - lobe["center"][1]) / (lobe["size"][1] / 2)
    wf = math.sqrt(max(1 - d * d, 0))
    size = (lobe["size"][0] * wf * lip, depth * 2.3, lobe["size"][2] * wf * lip)
    cc = (lobe["center"][0], rim + depth * 0.3, lobe["center"][2])
    add_ellipsoid(frame.point(cc), frame.rot @ rot_y(lobe["yaw"]), size, color)


def direction(a):
    return np.array([math.cos(a), 0, math.sin(a)])


def build_stack(frame, origin, count, base_r, top, bottom_c, taper, lean, haze):
    layout = []
    cy, hh, hw, drift = 0.0, 1.0, base_r, np.zeros(3)
    for _ in range(count):
        layout.append((cy, hh, hw, drift.copy()))
        cy += hh * rng.uniform(0.65, 0.8)
        hh *= rng.uniform(0.7, 0.92)
        hw *= rng.uniform(*taper)
        drift = drift + lean * hw * rng.uniform(0, 0.3)
    last = layout[-1]
    scale = (top - bottom_c) / (last[0] + last[1])
    lobes = []
    for i, (cy, hh, hw, drift) in enumerate(layout):
        size = (hw * 2 * rng.uniform(0.92, 1.05), hh * 2 * scale, hw * 2 * rng.uniform(0.8, 1))
        c = np.array(origin, dtype=float) + drift + np.array([0, bottom_c + cy * scale, 0])
        tone = ROCK_BASE + (ROCK - ROCK_BASE) * (i / max(count - 1, 1))
        lobes.append(sculpt_add(frame, c, size, shade(tone, haze)))
    return lobes


def build_peak(layer, base):
    detail, haze = layer["detail"], layer["haze"]
    spire = rng.random() < layer["spire"]
    visible = rng.uniform(*layer["visible"])
    radius = visible / (rng.uniform(3.2, 4.6) if spire else rng.uniform(1.9, 2.7))
    tilt = math.radians(rng.uniform(0, 5 if spire else 2.5))
    frame = Frame(base, rot_y(rng.uniform(0, 2 * math.pi)) @ rot_x(tilt))
    lean = direction(rng.uniform(0, 2 * math.pi))
    main = build_stack(frame, (0, 0, 0), rng.randint(3, 4) if spire else rng.randint(2, 3), radius, visible,
                       visible * rng.uniform(-0.12, 0.05), (0.66, 0.8) if spire else (0.55, 0.72), lean, haze)
    summit = main[-1]
    if detail >= 1:
        sculpt_crown(frame, summit, rng.uniform(0.25, 0.38), 1.06, moss(haze))
    if detail >= 2:
        for lobe in main[:-1]:
            sculpt_crown(frame, lobe, rng.uniform(0.2, 0.28), 1.03, moss(haze))
        axis = np.array([summit["center"][0], 0, summit["center"][2]])
        for _ in range(rng.randint(2, 4)):
            y = top_of(summit) - summit["size"][1] / 2 * rng.uniform(0.15, 0.45)
            rim = half_width_at(summit, y)
            sz = rim * rng.uniform(0.35, 0.6)
            off = axis + direction(rng.uniform(0, 2 * math.pi)) * rim * rng.uniform(0.7, 0.95)
            sculpt_add(frame, off + np.array([0, y, 0]), (sz * 2, sz * 1.3, sz * 2), moss(haze))
    bc = rng.randint(2, 3) if detail >= 3 else (rng.randint(1, 2) if detail == 2 else rng.randint(0, 1))
    for _ in range(bc):
        h = visible * rng.uniform(0.3, 0.62)
        off = direction(rng.uniform(0, 2 * math.pi)) * radius * rng.uniform(0.7, 1.05)
        b = build_stack(frame, off, rng.randint(2, 3), radius * rng.uniform(0.45, 0.7), h, h * rng.uniform(-0.2, 0),
                        (0.6, 0.78), lean, haze)
        if detail >= 2:
            sculpt_crown(frame, b[-1], rng.uniform(0.3, 0.45), 1.05, moss(haze))
    rc = rng.randint(5, 8) if detail >= 3 else (rng.randint(2, 4) if detail == 2 else 0)
    for i in range(1, rc + 1):
        lobe = main[rng.randint(0, max(len(main) - 2, 0))]
        h = lobe["size"][1] * rng.uniform(0.35, 0.6)
        cy = lobe["center"][1] + lobe["size"][1] * 0.3 - h / 2
        axis = np.array([lobe["center"][0], 0, lobe["center"][2]])
        off = axis + direction(rng.uniform(0, 2 * math.pi)) * half_width_at(lobe, cy) * rng.uniform(0.86, 0.94)
        w = radius * rng.uniform(0.12, 0.22)
        sculpt_add(frame, off + np.array([0, cy, 0]), (w, h, w), shade(ROCK_DARK if i % 2 == 0 else ROCK_LIGHT, haze))
    if detail >= 3:
        for _ in range(rng.randint(3, 6)):
            lobe = main[rng.randint(max(len(main) - 2, 0), len(main) - 1)]
            y = lobe["center"][1] + lobe["size"][1] / 2 * rng.uniform(-0.2, 0.6)
            sz = radius * rng.uniform(0.14, 0.26)
            axis = np.array([lobe["center"][0], 0, lobe["center"][2]])
            off = axis + direction(rng.uniform(0, 2 * math.pi)) * half_width_at(lobe, y) * 0.95
            sculpt_add(frame, off + np.array([0, y, 0]), (sz * 2, sz * 1.2, sz * 2), moss(haze))
    top = frame.point((summit["center"][0], top_of(summit), summit["center"][2]))
    return dict(position=top, topY=top[1], radius=radius * 0.7)


def build_range(layer, base, tangent):
    tallest = rng.uniform(*layer["visible"])
    domes = rng.randint(3, 6)
    length = tallest * rng.uniform(1.2, 2.2)
    si = rng.randint(2, domes - 1)
    out = []
    for i in range(1, domes + 1):
        along = ((i - 1) / (domes - 1) - 0.5 + rng.uniform(-0.08, 0.08)) * length
        h = tallest * (1 if i == si else rng.uniform(0.45, 0.85))
        w = h * rng.uniform(0.55, 0.9)
        pos = base + tangent * along + np.array([0, -h * 0.05, 0])
        add_ellipsoid(pos, rot_y(rng.uniform(0, 2 * math.pi)), (w, h * 1.9, w * rng.uniform(0.7, 1)),
                      shade(ROCK if i == si else ROCK_BASE, layer["haze"]))
        out.append(dict(position=pos, topY=pos[1] + h * 0.95, radius=w * 0.4))
    return out


def noise(x, y, z):
    return 0.3 * math.sin(2.1 * x + 1.3 * y + 0.7 * z) * math.cos(1.7 * y - 0.9 * x + z)


for li, layer in enumerate(LAYERS, start=1):
    sector = 2 * math.pi / layer["count"]
    phase = rng.uniform(0, sector)
    gmin, gmax = layer["gap"]
    for i in range(layer["count"]):
        ang = phase + (i + rng.uniform(0.15, 0.85)) * sector
        wob = noise(math.cos(ang) * 1.5, math.sin(ang) * 1.5, SEED % 997 + li * 17.3)
        t = min(1, max(0, 0.2 + rng.random() * 0.6 + wob))
        dist = ISLAND_R + gmin + (gmax - gmin) * t
        base = direction(ang) * dist + np.array([0, CLOUD_Y, 0])
        if layer["detail"] == 0:
            peaks_info += build_range(layer, base, direction(ang + math.pi / 2))
        else:
            p = build_peak(layer, base)
            peaks_info.append(p)
            if layer["detail"] >= 2:
                cloud_spots.append((base, p["radius"] / 0.7))

# Cloud puffs: sample each emitter's steady state (rate x lifetime particles).
puffs = []  # (position, size, alpha)
emitters = []
for gap, rate in [(120, 0.45), (320, 0.3)]:
    sr = ISLAND_R + gap
    n = int(min(max(round(2 * math.pi * sr / 170), 10), 28))
    for i in range(n):
        a = (i + rng.uniform(-0.3, 0.3)) / n * 2 * math.pi
        emitters.append((direction(a) * (sr + rng.uniform(-60, 60)), 280, rate))
for pos, r in cloud_spots:
    emitters.append((np.array([pos[0], 0, pos[2]]), min(r * 4.5, 1600), min(max(r / 250, 0.35), 0.9)))
for gap, count in CLOUD_RINGS:
    ph = rng.uniform(0, 2 * math.pi)
    for i in range(count):
        a = ph + (i + rng.uniform(-0.3, 0.3)) / count * 2 * math.pi
        emitters.append((direction(a) * (ISLAND_R + gap + rng.uniform(-150, 150)), 800, 0.3))
part_count += len(emitters)
floor_tiles = 0
reach = ISLAND_R + FLOOR_REACH
tiles = math.ceil(reach * 2 / 2048)
first = -(tiles - 1) * 2048 / 2
for ix in range(tiles):
    for iz in range(tiles):
        ox, oz = first + ix * 2048, first + iz * 2048
        if math.hypot(max(abs(ox) - 1024, 0), max(abs(oz) - 1024, 0)) <= reach:
            floor_tiles += 1
part_count += floor_tiles
particles = 0
for pos, width, rate in emitters:
    n = int(round(rate * 37.5))
    particles += n
    for _ in range(n):
        age = rng.random()
        size = 60 + 40 * age + rng.uniform(-15, 15) * (1 - age)
        alpha = 1 - (0.35 if 0.2 <= age <= 0.75 else (1 - (age / 0.2) * 0.65 if age < 0.2 else 0.45 + (age - 0.75) / 0.25 * 0.55))
        p = pos + np.array([rng.uniform(-width / 2, width / 2), CLOUD_Y + 15 + rng.uniform(-20, 20) + age * 30, rng.uniform(-width / 2, width / 2)])
        puffs.append((p, size, max(alpha, 0)))

max_dim = max(float(e[2].max()) * 2 for e in ellipsoids)
print(f"parts ~{part_count} (ellipsoids {len(ellipsoids)}, emitters {len(emitters)}, floor tiles {floor_tiles}); "
      f"particles ~{particles}; largest ellipsoid axis {max_dim:.0f} studs")

# ---------------------------------------------------------------- rendering
SUN = np.array([0.35, 0.75, 0.55]); SUN /= np.linalg.norm(SUN)


def fog(dist):
    return 1 - np.exp(-np.power(dist / 3000.0, 1.3))


def sky(dirs):
    elev = np.clip(dirs[..., 1], 0, 1)
    t = np.power(elev, 0.45)[..., None]
    col = ATMOS_COLOR * (1 - t) + ZENITH * t
    sun_glow = np.clip((dirs @ SUN), 0, 1)[..., None] ** 40 * 0.35
    return np.clip(col + sun_glow, 0, 1)


def render(eye, dirs, name):
    h, w, _ = dirs.shape
    d = dirs.reshape(-1, 3)
    depth = np.full(d.shape[0], np.inf)
    color = np.zeros_like(d)
    normal = np.zeros_like(d)
    for c, R, axes, col in ellipsoids:
        oc = (eye - c) @ R / axes
        dd = (d @ R) / axes
        a = np.einsum("ij,ij->i", dd, dd)
        b = 2 * dd @ oc
        cc = oc @ oc - 1
        disc = b * b - 4 * a * cc
        hit = disc > 0
        if not hit.any():
            continue
        t = np.full(d.shape[0], np.inf)
        sq = np.sqrt(np.where(hit, disc, 0))
        t0 = (-b - sq) / (2 * a)
        t = np.where(hit & (t0 > 0), t0, np.inf)
        closer = t < depth
        if not closer.any():
            continue
        depth = np.where(closer, t, depth)
        p = eye + d[closer] * t[closer, None]
        local = (p - c) @ R / axes
        n = (local / axes) @ R.T
        n /= np.linalg.norm(n, axis=1, keepdims=True)
        normal[closer] = n
        color[closer] = col
    # cloud floor plane
    with np.errstate(divide="ignore", invalid="ignore"):
        tf = (CLOUD_Y - eye[1]) / d[:, 1]
    fp = eye + d * np.where(np.isfinite(tf), tf, 0)[:, None]
    on_floor = (tf > 0) & (np.hypot(fp[:, 0], fp[:, 2]) < ISLAND_R + FLOOR_REACH) & (tf < depth)
    # the island placeholder: a disc at ground level
    with np.errstate(divide="ignore", invalid="ignore"):
        ti = (GROUND - eye[1]) / d[:, 1]
    ip = eye + d * np.where(np.isfinite(ti), ti, 0)[:, None]
    on_island = (ti > 0) & (np.hypot(ip[:, 0], ip[:, 2]) < ISLAND_R) & (ti < depth)
    solid = np.isfinite(depth)
    lit = np.clip(normal @ SUN, 0, 1)
    shaded = color * (0.58 + 0.55 * lit)[:, None]
    out = sky(d)
    out[solid] = shaded[solid]
    out[on_floor] = FLOOR_COLOR * (0.58 + 0.55 * SUN[1])
    depth = np.where(on_floor, tf, depth)
    island_first = on_island & (ti < depth)
    out[island_first] = rgb(96, 150, 74) * (0.58 + 0.55 * SUN[1])
    depth = np.where(island_first, ti, depth)
    visible = np.isfinite(depth)
    f = fog(np.where(visible, depth, 0))[:, None]
    haze_col = sky(d * np.array([1, 0, 1]) + np.array([0, 0.02, 0]))
    out = np.where(visible[:, None], out * (1 - f) + haze_col * f, out)
    img = out.reshape(h, w, 3)
    return img, depth.reshape(h, w)


def splat_puffs(img, depthbuf, eye, project):
    order = sorted(puffs, key=lambda q: -np.linalg.norm(q[0] - eye))
    h, w, _ = img.shape
    for pos, size, alpha in order:
        res = project(pos)
        if res is None:
            continue
        x, y, dist, scale = res
        r = size / 2 * scale
        if r < 0.7 or alpha <= 0.01:
            continue
        x0, x1 = int(max(x - 2 * r, 0)), int(min(x + 2 * r + 1, w))
        y0, y1 = int(max(y - 2 * r, 0)), int(min(y + 2 * r + 1, h))
        if x0 >= x1 or y0 >= y1:
            continue
        yy, xx = np.mgrid[y0:y1, x0:x1]
        g = np.exp(-(((xx - x) ** 2 + (yy - y) ** 2) / (2 * (r * 0.6) ** 2))) * alpha
        g = np.where(depthbuf[y0:y1, x0:x1] > dist, g, 0)[..., None]
        col = CLOUD_COLOR * (0.8 + 0.3 * SUN[1])
        f = fog(np.array(dist))
        col = col * (1 - f) + ATMOS_COLOR * f
        img[y0:y1, x0:x1] = img[y0:y1, x0:x1] * (1 - g) + np.clip(col, 0, 1) * g
    return img


def perspective(eye, yaw_deg, pitch_deg, w=960, h=540, fov=70):
    yaw, pitch = math.radians(yaw_deg), math.radians(pitch_deg)
    fwd = np.array([math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)])
    right = np.cross(fwd, [0, 1, 0]); right /= np.linalg.norm(right)
    up = np.cross(right, fwd)
    f = (h / 2) / math.tan(math.radians(fov / 2))
    xs = (np.arange(w) - w / 2 + 0.5)
    ys = (h / 2 - np.arange(h) - 0.5)
    dirs = fwd * f + right * xs[None, :, None] + up * ys[:, None, None]
    dirs /= np.linalg.norm(dirs, axis=2, keepdims=True)

    def project(p):
        v = p - eye
        z = v @ fwd
        if z <= 1:
            return None
        return (w / 2 + (v @ right) / z * f, h / 2 - (v @ up) / z * f, np.linalg.norm(v), f / z)

    img, depth = render(eye, dirs, "")
    return splat_puffs(img, depth, eye, project)


def panorama(eye, w=2400, h=420, lo=-12, hi=40):
    az = np.linspace(0, 2 * math.pi, w, endpoint=False)
    el = np.radians(np.linspace(hi, lo, h))
    dirs = np.stack([np.sin(az)[None, :] * np.cos(el)[:, None], np.sin(el)[:, None] * np.ones((1, w)),
                     np.cos(az)[None, :] * np.cos(el)[:, None]], axis=2)

    def project(p):
        v = p - eye
        dist = np.linalg.norm(v)
        a = math.atan2(v[0], v[2]) % (2 * math.pi)
        e = math.degrees(math.asin(v[1] / dist))
        x = a / (2 * math.pi) * w
        y = (hi - e) / (hi - lo) * h
        return (x, y, dist, (w / (2 * math.pi)) / dist)

    img, depth = render(eye, dirs, "")
    return splat_puffs(img, depth, eye, project)


def save(img, path):
    Image.fromarray((np.clip(img, 0, 1) ** (1 / 1.1) * 255).astype(np.uint8)).save(path)


out = sys.argv[2] if len(sys.argv) > 2 else "."
eye = np.array([0.0, GROUND + 14, ISLAND_R - 40])
save(perspective(eye, 0, 6), f"{out}/preview_view_north.png")
save(perspective(np.array([ISLAND_R - 40, GROUND + 14, 0.0]), 90, 6), f"{out}/preview_view_east.png")
save(panorama(np.array([0.0, GROUND + 14, 0.0])), f"{out}/preview_panorama.png")
print("saved previews")
