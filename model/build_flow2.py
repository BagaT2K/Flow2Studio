# Lofree Flow 2 (84 keys) — procedural Blender model.
#
#   blender -b --python build_flow2.py -- --out out [--finish spacegray|silver] [--render] [--env]
#
# Everything is modelled in millimetres from the official dimensions
# (341.2 x 126 mm case, 19.05 mm key pitch) and measurements taken on Lofree's
# product photos, then scaled to metres before export.
import bpy, bmesh, math, os, sys
from mathutils import Vector, Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
def arg(name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(arg("--out", os.path.join(HERE, "out")))
FINISH = arg("--finish", "spacegray")
DO_RENDER = "--render" in argv
DO_ENV = "--env" in argv
os.makedirs(OUT, exist_ok=True)

# ----------------------------------------------------------------- dimensions
U = 19.05
CASE_W, CASE_D, CASE_H = 341.2, 126.0, 12.5
CASE_R = 5.5
HW, HD = CASE_W / 2, CASE_D / 2
WELL_X0, WELL_X1 = -HW + 5.1, -HW + 5.1 + 305.3
WELL_Y0, WELL_Y1 = -HD + 5.4, HD - 5.0            # front, rear
WELL_R = 1.2
PLATE_Z = CASE_H - 5.0
GRID_X0 = WELL_X0 + (305.3 - 16 * U) / 2
GRID_Y1 = WELL_Y1 - ((WELL_Y1 - WELL_Y0) - 6 * U) / 2   # rear edge of row 0
KEY_Z0 = CASE_H - 1.2
KEY_H = 7.0
RIGHT = HW

# touch bar (right flank), USB-C, status LED, logo
TB_Y0, TB_Y1, TB_Z, TB_H, TB_R = -40.1, 29.6, 6.9, 6.65, 2.5
USB_Y, USB_Z, USB_W, USB_H = 46.7, 6.2, 10.3, 3.55
LED_X, LED_Y, LED_L, LED_W = 155.2, 54.3, 14.1, 0.9

# ------------------------------------------------------------------- layout
def build_layout():
    rows = [
        [1] * 16,
        [1] * 13 + [2, 1],
        [1.5] + [1] * 12 + [1.5, 1],
        [1.75] + [1] * 11 + [2.25, 1],
        [2.25] + [1] * 10 + [1.75, 1, 1],
        [1.25, 1.25, 1.25, 6.25, 1, 1, 1, 1, 1, 1],
    ]
    keys, i = [], 0
    for r, row in enumerate(rows):
        x = 0.0
        for w in row:
            keys.append({"id": i, "x": x, "y": r, "w": w})
            x += w
            i += 1
        assert abs(x - 16) < 1e-6, (r, x)
    assert len(keys) == 84
    return keys
LAYOUT = build_layout()

# ---------------------------------------------------------------- scene setup
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.unit_settings.system = "METRIC"
scene.unit_settings.scale_length = 1.0
kb = bpy.data.collections.new("Flow2_84")
scene.collection.children.link(kb)
studio = bpy.data.collections.new("Studio")
scene.collection.children.link(studio)

# ------------------------------------------------------------------ materials
def srgb(r, g, b):
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r), f(g), f(b), 1.0)

def principled(name, base, metallic=0.0, rough=0.5, coat=0.0, emission=None, strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = base
    b.inputs["Metallic"].default_value = metallic
    b.inputs["Roughness"].default_value = rough
    if coat:
        b.inputs["Coat Weight"].default_value = coat
        b.inputs["Coat Roughness"].default_value = 0.05
    if emission:
        b.inputs["Emission Color"].default_value = emission
        b.inputs["Emission Strength"].default_value = strength
    return m

DARK = FINISH != "silver"
M = {}
M["aluminum"] = principled("Aluminum", srgb(0.55, 0.555, 0.595) if DARK else srgb(0.84, 0.85, 0.87), 1.0, 0.40)
M["plate"] = principled("Plate", srgb(0.045, 0.045, 0.05) if DARK else srgb(0.80, 0.81, 0.82), 0.0, 0.7)
M["switch"] = principled("Switch", srgb(0.03, 0.03, 0.035) if DARK else srgb(0.70, 0.71, 0.72), 0.0, 0.6)
M["glass"] = principled("TouchGlass", srgb(0.015, 0.015, 0.018), 0.0, 0.08, coat=1.0)
M["rubber"] = principled("Rubber", srgb(0.04, 0.04, 0.04), 0.0, 0.9)
M["port_ring"] = principled("PortRing", srgb(0.80, 0.81, 0.83), 1.0, 0.16)
M["port_dark"] = principled("PortDark", srgb(0.03, 0.03, 0.035), 0.6, 0.35)
M["led"] = principled("StatusLED", srgb(0.02, 0.02, 0.02), 0.0, 0.3, emission=srgb(0.3, 1.0, 0.45), strength=0.0)

def keycap_material():
    m = bpy.data.materials.new("Keycap")
    m.use_nodes = True
    nt = m.node_tree
    b = nt.nodes["Principled BSDF"]
    b.inputs["Roughness"].default_value = 0.52
    color = os.path.join(OUT, "keycaps_%s.png" % ("dark" if DARK else "light"))
    mask = os.path.join(OUT, "legends.png")
    if os.path.exists(color):
        t = nt.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(color)
        nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    else:
        b.inputs["Base Color"].default_value = srgb(0.11, 0.11, 0.115) if DARK else srgb(0.9, 0.9, 0.89)
    if os.path.exists(mask):
        t2 = nt.nodes.new("ShaderNodeTexImage")
        t2.image = bpy.data.images.load(mask)
        t2.image.colorspace_settings.name = "Non-Color"
        nt.links.new(t2.outputs["Color"], b.inputs["Emission Color"])
        b.inputs["Emission Strength"].default_value = 0.0
    return m
M["keycap"] = keycap_material()

# -------------------------------------------------------------------- helpers
def rrect(hw, hd, r, seg=8, cx=0.0, cy=0.0, support=0.0):
    """CCW rounded-rectangle loop starting at the +x/+y corner.
    With support > 0, an extra point is added on the straight edges just before and
    after every corner so flat walls keep exact normals under smooth shading."""
    r = max(1e-4, min(r, hw, hd))
    pts = []
    for ox, oy, a0 in ((hw - r, hd - r, 0), (-hw + r, hd - r, 90), (-hw + r, -hd + r, 180), (hw - r, -hd + r, 270)):
        for i in range(seg + 1):
            a = math.radians(a0 + 90.0 * i / seg)
            p = (cx + ox + r * math.cos(a), cy + oy + r * math.sin(a))
            t = (-math.sin(a), math.cos(a))
            if support and i == 0:
                pts.append((p[0] - support * t[0], p[1] - support * t[1]))
            pts.append(p)
            if support and i == seg:
                pts.append((p[0] + support * t[0], p[1] + support * t[1]))
    return pts

def loft(rings, cap_start=True, cap_end=True):
    n = len(rings[0])
    verts = [tuple(p) for ring in rings for p in ring]
    faces = []
    for k in range(len(rings) - 1):
        a, b = k * n, (k + 1) * n
        for i in range(n):
            j = (i + 1) % n
            faces.append((a + i, a + j, b + j, b + i))
    if cap_start:
        faces.append(tuple(reversed(range(n))))
    if cap_end:
        faces.append(tuple(range((len(rings) - 1) * n, len(rings) * n)))
    return verts, faces

def shade(me, angle=40):
    for p in me.polygons:
        p.use_smooth = True
    me.set_sharp_from_angle(angle=math.radians(angle))

def new_obj(name, verts, faces, mat=None, angle=40, collection=None, recalc=False):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    if recalc:
        bm = bmesh.new()
        bm.from_mesh(me)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(me)
        bm.free()
    me.update()
    shade(me, angle)
    ob = bpy.data.objects.new(name, me)
    (collection or kb).objects.link(ob)
    if mat:
        me.materials.append(mat)
    return ob

def slab(cx, cy, hw, hd, r, z0, z1, bev=0.15, seg=8):
    """Rounded slab with small bevels, in the XY plane."""
    b = min(bev, (z1 - z0) / 2 - 1e-4)
    rings = [
        [(x, y, z0) for x, y in rrect(hw - b, hd - b, r - b, seg, cx, cy)],
        [(x, y, z0 + b) for x, y in rrect(hw, hd, r, seg, cx, cy)],
        [(x, y, z1 - b) for x, y in rrect(hw, hd, r, seg, cx, cy)],
        [(x, y, z1) for x, y in rrect(hw - b, hd - b, r - b, seg, cx, cy)],
    ]
    return loft(rings)

def flank_prism(sections, y_c, z_c):
    """Prism along X on the right flank. sections = [(x, half_len_y, half_h_z, radius)]."""
    rings = []
    for x, hl, hh, r in sections:
        rings.append([(x, y_c + a, z_c + b) for a, b in rrect(hl, hh, r, 10)])
    return loft(rings)

def boolean_cut(target, cutter):
    mod = target.modifiers.new("cut", "BOOLEAN")
    mod.operation = "DIFFERENCE"
    mod.solver = "EXACT"
    mod.object = cutter
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(target.evaluated_get(dg))
    target.modifiers.clear()
    old = target.data
    target.data = me
    bpy.data.meshes.remove(old)
    bpy.data.objects.remove(cutter, do_unlink=True)

# ----------------------------------------------------------------------- case
def build_case():
    seg = 12
    c, cb, c2 = 0.6, 0.5, 0.28
    wcx, wcy = (WELL_X0 + WELL_X1) / 2, (WELL_Y0 + WELL_Y1) / 2
    whw, whd = (WELL_X1 - WELL_X0) / 2, (WELL_Y1 - WELL_Y0) / 2
    H = CASE_H
    def outer(inset, z):
        return [(x, y, z) for x, y in rrect(HW - inset, HD - inset, CASE_R - inset, seg, support=0.08)]
    def well(grow, z):
        return [(x, y, z) for x, y in rrect(whw + grow, whd + grow, WELL_R + grow, seg, wcx, wcy, support=0.08)]
    e, nb = 0.06, 4   # support loops keep the big flat faces flat-shaded
    rings = [outer(cb + e, 0.0)]
    for i in range(nb + 1):
        t = math.radians(90.0 * i / nb)
        rings.append(outer(cb * (1 - math.sin(t)), cb * (1 - math.cos(t))))
    rings += [outer(0.0, cb + e), outer(0.0, H - c - e)]
    for i in range(nb + 1):
        t = math.radians(90.0 * i / nb)
        rings.append(outer(c * (1 - math.cos(t)), H - c + c * math.sin(t)))
    rings += [outer(c + e, H), well(c2 + e, H), well(c2, H), well(0.0, H - c2), well(0.0, H - c2 - e),
              well(0.0, PLATE_Z - 0.6)]
    v, f = loft(rings)
    case = new_obj("case", v, f, M["aluminum"], angle=30)

    # touch bar pocket (chamfered, 0.6 mm deep)
    v, f = flank_prism([
        (RIGHT + 1.0, (TB_Y1 - TB_Y0) / 2 + 1.25, TB_H / 2 + 1.25, TB_R + 1.25),
        (RIGHT - 0.25, (TB_Y1 - TB_Y0) / 2, TB_H / 2, TB_R),
        (RIGHT - 0.7, (TB_Y1 - TB_Y0) / 2, TB_H / 2, TB_R),
    ], (TB_Y0 + TB_Y1) / 2, TB_Z)
    boolean_cut(case, new_obj("cut_tb", v, f, recalc=True))

    # USB-C opening
    v, f = flank_prism([
        (RIGHT + 1.0, USB_W / 2, USB_H / 2, USB_H / 2),
        (RIGHT - 7.5, USB_W / 2, USB_H / 2, USB_H / 2),
    ], USB_Y, USB_Z)
    boolean_cut(case, new_obj("cut_usb", v, f, recalc=True))

    # status LED slit (top face, right wing)
    rings = [
        [(x, y, H + 1.0) for x, y in rrect(LED_L / 2 + 1.2, LED_W / 2 + 1.2, LED_W / 2 + 1.2, 8, LED_X, LED_Y)],
        [(x, y, H - 0.2) for x, y in rrect(LED_L / 2, LED_W / 2, LED_W / 2, 8, LED_X, LED_Y)],
        [(x, y, H - 0.9) for x, y in rrect(LED_L / 2, LED_W / 2, LED_W / 2, 8, LED_X, LED_Y)],
    ]
    v, f = loft(rings)
    boolean_cut(case, new_obj("cut_led", v, f, recalc=True))

    # engraved wordmark (ball-end groove), reading front -> rear on the right wing
    for cutter in logo_cutters():
        boolean_cut(case, cutter)

    shade(case.data, 30)
    return case

def logo_cutters():
    Hc, Wc, rc, gap = 6.2, 2.9, 1.25, 1.75
    tube_r, lift = 0.78, 0.44
    def arc(cx, cy, r, a0, a1, n=8):
        return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
                 cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]
    def loop_o():
        return rrect(Wc / 2, Hc / 2, rc, 8, Wc / 2, Hc / 2), True
    glyphs = {
        "L": [([(0, Hc)] + arc(rc, rc, rc, 180, 270) + [(Wc, 0)], False)],
        "o": [loop_o()],
        "F": [([(0, 0)] + arc(rc, Hc - rc, rc, 180, 90) + [(Wc, Hc)], False),
              ([(0.2, Hc * 0.5), (Wc * 0.82, Hc * 0.5)], False)],
        "r": [([(0, 0)] + arc(rc, Hc - rc, rc, 180, 90) + [(Wc * 0.9, Hc)], False)],
        "e": [([(0.25, Hc * 0.5), (Wc, Hc * 0.5)], False),
              ([(Wc, Hc * 0.5)] + arc(Wc - rc, Hc - rc, rc, 0, 90) + arc(rc, Hc - rc, rc, 90, 180)
               + arc(rc, rc, rc, 180, 270) + [(Wc * 0.95, 0)], False)],
    }
    x_base, y_start = 163.75 - 0.6, -56.3 + 0.6
    out = []
    u0 = 0.0
    for ch in "LoFree":
        for pts, cyclic in glyphs[ch]:
            cu = bpy.data.curves.new("logo", "CURVE")
            cu.dimensions = "3D"
            cu.bevel_depth = tube_r
            cu.bevel_resolution = 5
            cu.use_fill_caps = True
            sp = cu.splines.new("POLY")
            sp.points.add(len(pts) - 1)
            for p, (u, v) in zip(sp.points, pts):
                p.co = (x_base - v, y_start + u0 + u, CASE_H + lift, 1.0)
            sp.use_cyclic_u = cyclic
            tmp = bpy.data.objects.new("logo_curve", cu)
            kb.objects.link(tmp)
            dg = bpy.context.evaluated_depsgraph_get()
            me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
            bpy.data.objects.remove(tmp, do_unlink=True)
            ob = bpy.data.objects.new("cut_logo", me)
            kb.objects.link(ob)
            out.append(ob)
        u0 += Wc + gap
    return out

# -------------------------------------------------------------------- keycaps
def clamp_rr(x, y, hw, hd, r):
    if abs(x) > hw - r and abs(y) > hd - r:
        cx, cy = math.copysign(hw - r, x), math.copysign(hd - r, y)
        dx, dy = x - cx, y - cy
        n = math.hypot(dx, dy)
        if n > r:
            return cx + dx * r / n, cy + dy * r / n
    return x, y

def grid_lines(h, r, curve=None, ncurve=5, nmid=4):
    """Grid coordinates along one axis: fine near the corners, same count for any size."""
    left = [-h, -h + r / 3, -h + 2 * r / 3, -h + r]
    if curve is None:
        mid = [(-h + r) + (2 * (h - r)) * i / nmid for i in range(1, nmid)]
        return left + mid + [-v for v in reversed(left)]
    inner = -h + curve
    zone = [(-h + r) + (inner - (-h + r)) * i / ncurve for i in range(1, ncurve + 1)]
    half = left + zone
    if inner < -1e-4:
        return half + [-v for v in reversed(half)]
    return half[:-1] + [0.0] + [-v for v in reversed(half[:-1])]

def build_keycap(key):
    w = key["w"]
    bw, bd = w * U - 1.45, U - 1.45
    tw, td = bw - 3.0, bd - 2.6
    hw_b, hd_b, r_b = bw / 2, bd / 2, 1.1
    hw_t, hd_t, r_t = tw / 2 - 0.17, td / 2 - 0.17, 1.45
    hw_v, hd_v, r_v = tw / 2 + 0.05, td / 2 + 0.05, 1.65
    Lz = min(hw_t, 7.13)                      # width of the curved zone of the dish
    D = 0.42
    def ztop(x):
        t = max(0.0, min(1.0, (abs(x) - (hw_t - Lz)) / Lz))
        return KEY_H - D * (1 - t * t)

    xs = grid_lines(hw_t, r_t, curve=Lz)
    ys = grid_lines(hd_t, r_t)
    nu, nv = len(xs) - 1, len(ys) - 1
    verts, faces = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            x, y = clamp_rr(xs[i], ys[j], hw_t, hd_t, r_t)
            verts.append((x, y, ztop(x)))
    idx = lambda i, j: j * (nu + 1) + i
    for j in range(nv):
        for i in range(nu):
            faces.append((idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1)))
    n_top = len(faces)

    perim = [(i, 0) for i in range(nu + 1)] + [(nu, j) for j in range(1, nv + 1)] \
        + [(i, nv) for i in range(nu - 1, -1, -1)] + [(0, j) for j in range(nv - 1, 0, -1)]
    top_loop = [idx(i, j) for i, j in perim]

    def ring(hw, hd, r, zfun):
        gx = grid_lines(hw, r, curve=Lz + (hw - hw_t))
        gy = grid_lines(hd, r)
        base = len(verts)
        for i, j in perim:
            x, y = clamp_rr(gx[i], gy[j], hw, hd, r)
            verts.append((x, y, zfun(x)))
        return list(range(base, base + len(perim)))
    slope = (hw_b - hw_v) / (KEY_H - 0.21 - 0.35)
    bevel = ring(hw_v, hd_v, r_v, lambda x: ztop(x) - 0.21)
    sup = ring(hw_v + slope * 0.3, hd_v + slope * 0.3, r_v, lambda x: ztop(x) - 0.51)
    base = ring(hw_b, hd_b, r_b, lambda x: 0.35)
    foot = ring(hw_b - 0.25, hd_b - 0.25, r_b - 0.2, lambda x: 0.0)
    n = len(perim)
    for lower, upper in ((bevel, top_loop), (sup, bevel), (base, sup), (foot, base)):
        for i in range(n):
            j = (i + 1) % n
            faces.append((lower[i], lower[j], upper[j], upper[i]))

    cx = GRID_X0 + (key["x"] + w / 2) * U
    cy = GRID_Y1 - (key["y"] + 0.5) * U
    ob = new_obj("key_%d" % key["id"], verts, faces, M["keycap"], angle=42)
    ob.location = (cx, cy, KEY_Z0)

    me = ob.data
    uv = me.uv_layers.new(name="UVMap")
    blank = (0.4 / (16 * U), 1.0 - 0.4 / (6 * U))
    for p in me.polygons:
        for li in p.loop_indices:
            if p.index < n_top:
                vx, vy, _ = me.vertices[me.loops[li].vertex_index].co
                uv.data[li].uv = ((cx + vx - GRID_X0) / (16 * U), 1.0 - (GRID_Y1 - (cy + vy)) / (6 * U))
            else:
                uv.data[li].uv = blank
    return ob

# --------------------------------------------------------------- other parts
def build_parts():
    wcx, wcy = (WELL_X0 + WELL_X1) / 2, (WELL_Y0 + WELL_Y1) / 2
    whw, whd = (WELL_X1 - WELL_X0) / 2, (WELL_Y1 - WELL_Y0) / 2
    # switch plate (floor of the key well)
    pts = rrect(whw + 0.6, whd + 0.6, WELL_R, 4, wcx, wcy)
    new_obj("plate", [(x, y, PLATE_Z) for x, y in pts], [tuple(range(len(pts)))], M["plate"])

    # switch housings: one merged mesh
    verts, faces = [], []
    for k in LAYOUT:
        cx = GRID_X0 + (k["x"] + k["w"] / 2) * U
        cy = GRID_Y1 - (k["y"] + 0.5) * U
        v, f = slab(cx, cy, 6.9, 6.9, 1.0, PLATE_Z, KEY_Z0 + 0.6, 0.3, 3)
        o = len(verts)
        verts += v
        faces += [tuple(i + o for i in face) for face in f]
    new_obj("switches", verts, faces, M["switch"])

    # bottom plate
    v, f = slab(0, 0, HW - 0.9, HD - 0.9, CASE_R - 0.9, -0.4, 0.2, 0.12, 12)
    new_obj("bottom", v, f, M["aluminum"])

    # touch bar glass
    hl, hh = (TB_Y1 - TB_Y0) / 2 - 0.04, TB_H / 2 - 0.04
    v, f = flank_prism([
        (RIGHT - 0.7, hl, hh, TB_R),
        (RIGHT - 0.24, hl, hh, TB_R),
        (RIGHT - 0.16, hl - 0.08, hh - 0.08, TB_R - 0.08),
    ], (TB_Y0 + TB_Y1) / 2, TB_Z)
    new_obj("touchbar", v, f, M["glass"], recalc=True)

    # USB-C: polished chamfer ring, dark shell, tongue
    r0 = USB_H / 2
    ring_a = [(RIGHT + 0.01, USB_Y + a, USB_Z + b) for a, b in rrect(USB_W / 2 + 0.45, r0 + 0.45, r0 + 0.45, 10)]
    ring_b = [(RIGHT - 0.02, USB_Y + a, USB_Z + b) for a, b in rrect(USB_W / 2 + 0.12, r0 + 0.12, r0 + 0.12, 10)]
    ring_c = [(RIGHT - 0.55, USB_Y + a, USB_Z + b) for a, b in rrect(USB_W / 2 - 0.55, r0 - 0.32, r0 - 0.32, 10)]
    v, f = loft([ring_a, ring_b, ring_c], cap_start=False, cap_end=False)
    new_obj("usbc_ring", v, f, M["port_ring"], angle=60, recalc=False)
    ring_d = [(RIGHT - 6.8, USB_Y + a, USB_Z + b) for a, b in rrect(USB_W / 2 - 0.55, r0 - 0.32, r0 - 0.32, 10)]
    v, f = loft([ring_c, ring_d], cap_start=False, cap_end=True)
    new_obj("usbc_shell", v, f, M["port_dark"], recalc=False)
    v, f = flank_prism([(RIGHT - 1.3, 3.3, 0.33, 0.3), (RIGHT - 6.8, 3.3, 0.33, 0.3)], USB_Y, USB_Z)
    new_obj("usbc_tongue", v, f, M["port_dark"], recalc=True)

    # status LED light pipe
    v, f = slab(LED_X, LED_Y, LED_L / 2 - 0.02, LED_W / 2 - 0.02, LED_W / 2 - 0.02, CASE_H - 0.9, CASE_H - 0.32, 0.05, 8)
    new_obj("led", v, f, M["led"])

    # feet and flip-out kickstands (folded)
    for side, sx in (("L", -1), ("R", 1)):
        v, f = slab(sx * (HW - 36), -HD + 9.5, 11.0, 2.2, 2.2, -1.9, -0.4, 0.35, 8)
        new_obj("foot_%s" % side, v, f, M["rubber"])
        v, f = slab(sx * (HW - 27), HD - 12.5, 15.0, 6.0, 1.0, -1.5, -0.4, 0.2, 4)
        new_obj("kickstand_%s" % side, v, f, M["aluminum"])
        v, f = slab(sx * (HW - 27), HD - 20.8, 15.0, 2.4, 1.0, -1.9, -0.4, 0.3, 4)
        new_obj("kickstand_tip_%s" % side, v, f, M["rubber"])

# ----------------------------------------------------------------------- build
build_case()
build_parts()
for k in LAYOUT:
    build_keycap(k)

# millimetres -> metres
S = Matrix.Scale(0.001, 4)
for ob in kb.objects:
    ob.data.transform(S)
    ob.location = ob.location * 0.001
    ob.data.update()

tris = sum(len(p.vertices) - 2 for ob in kb.objects for p in ob.data.polygons)
print("FLOW2: %d objects, %d triangles" % (len(kb.objects), tris))

# --------------------------------------------------------------------- studio
def emitter(name, loc, rot, size, strength, color=(1, 1, 1)):
    me = bpy.data.meshes.new(name)
    sx, sy = size[0] / 2, size[1] / 2
    me.from_pydata([(-sx, -sy, 0), (sx, -sy, 0), (sx, sy, 0), (-sx, sy, 0)], [], [(0, 1, 2, 3)])
    ob = bpy.data.objects.new(name, me)
    ob.location, ob.rotation_euler = loc, [math.radians(a) for a in rot]
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    nt.nodes.remove(nt.nodes["Principled BSDF"])
    e = nt.nodes.new("ShaderNodeEmission")
    e.inputs["Color"].default_value = (*color, 1)
    e.inputs["Strength"].default_value = strength
    nt.links.new(e.outputs[0], nt.nodes["Material Output"].inputs["Surface"])
    me.materials.append(m)
    ob.visible_camera = False
    studio.objects.link(ob)
    return ob

def build_studio():
    world = bpy.data.worlds.new("Studio")
    world.use_nodes = True
    nt = world.node_tree
    bg = nt.nodes["Background"]
    # soft vertical gradient: bright ceiling, mid-grey horizon, darker floor
    tc = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    mp = nt.nodes.new("ShaderNodeMapRange")
    nt.links.new(tc.outputs["Generated"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mp.inputs["Value"])
    mp.inputs["From Min"].default_value = -1
    mp.inputs["From Max"].default_value = 1
    nt.links.new(mp.outputs[0], ramp.inputs[0])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (0.42, 0.42, 0.43, 1)     # light desk bounce
    els[1].position, els[1].color = 1.0, (0.70, 0.72, 0.76, 1)
    mid = els.new(0.5)
    mid.color = (0.26, 0.27, 0.29, 1)
    nt.links.new(ramp.outputs[0], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 1.0
    scene.world = world
    # softboxes
    emitter("key_box", (0.15, -0.60, 0.85), (34, 8, 0), (1.3, 0.9), 2.4)
    emitter("rear_strip", (0.0, 0.95, 0.45), (-70, 0, 0), (1.8, 0.28), 4.0, (0.92, 0.96, 1.0))
    emitter("right_strip", (1.0, 0.0, 0.32), (0, -72, 0), (0.3, 1.4), 3.2, (0.95, 0.97, 1.0))
    emitter("left_fill", (-1.1, -0.2, 0.4), (0, 70, 0), (0.6, 1.2), 1.2, (1.0, 0.97, 0.93))
    emitter("front_fill", (0.0, -1.1, 0.25), (78, 0, 0), (1.6, 0.4), 1.0)
build_studio()

def setup_cycles(samples=96):
    scene.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    except Exception as e:
        print("GPU unavailable:", e)
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"

def look_at(ob, target):
    d = Vector(target) - ob.location
    ob.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()

def render(name, loc, target, lens=85, res=(1500, 1000), ortho=None, transparent=False):
    cam = bpy.data.cameras.new(name)
    cam.lens = lens
    cam.clip_start, cam.clip_end = 0.01, 50
    if ortho:
        cam.type = "ORTHO"
        cam.ortho_scale = ortho
    ob = bpy.data.objects.new(name, cam)
    ob.location = loc
    look_at(ob, target)
    scene.collection.objects.link(ob)
    scene.camera = ob
    scene.render.resolution_x, scene.render.resolution_y = res
    scene.render.film_transparent = transparent
    scene.render.image_settings.file_format = "PNG"
    scene.render.filepath = os.path.join(OUT, "render_%s_%s.png" % (FINISH, name))
    bpy.ops.render.render(write_still=True)

if DO_RENDER:
    setup_cycles()
    # shadow-catching backdrop
    fl = bpy.data.meshes.new("floor")
    fl.from_pydata([(-3, -3, -0.0019), (3, -3, -0.0019), (3, 3, -0.0019), (-3, 3, -0.0019)], [], [(0, 1, 2, 3)])
    flo = bpy.data.objects.new("floor", fl)
    fl.materials.append(principled("Backdrop", srgb(0.93, 0.93, 0.94), 0.0, 0.6))
    studio.objects.link(flo)
    only = arg("--views", "hero,top,side,low").split(",")
    if "hero" in only:
        render("hero", (0.50, -0.66, 0.56), (0.0, 0.0, 0.0), 85)
    if "top" in only:
        render("top", (0.0, -0.02, 1.4), (0.0, 0.0, 0.0), 120, res=(1500, 700))
    if "side" in only:
        render("side", (1.2, 0.0, 0.012), (0.0, 0.0, 0.009), 85, res=(1500, 500), ortho=0.16)
    if "low" in only:
        render("low", (0.36, -0.20, 0.07), (0.10, 0.02, 0.006), 70)
    if "detail" in only:
        render("detail", (0.34, -0.20, 0.16), (0.14, -0.025, 0.008), 90)

if DO_ENV:
    # equirectangular studio environment for the app's image-based lighting
    setup_cycles(128)
    for ob in kb.objects:
        ob.hide_render = True
    for ob in studio.objects:
        ob.visible_camera = True
        if ob.name == "floor":
            ob.hide_render = True
    cam = bpy.data.cameras.new("env")
    cam.type = "PANO"
    cam.panorama_type = "EQUIRECTANGULAR"
    ob = bpy.data.objects.new("env", cam)
    ob.location = (0, 0, 0.02)
    ob.rotation_euler = (math.radians(90), 0, 0)
    scene.collection.objects.link(ob)
    scene.camera = ob
    scene.render.resolution_x, scene.render.resolution_y = 1024, 512
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_depth = "16"
    scene.render.filepath = os.path.join(OUT, "studio_env.exr")
    bpy.ops.render.render(write_still=True)
    for ob in kb.objects:
        ob.hide_render = False

# --------------------------------------------------------------------- export
if "--no-export" not in argv:
    layer = bpy.context.view_layer
    layer.layer_collection.children["Studio"].exclude = True
    for ob in list(scene.collection.objects):
        bpy.data.objects.remove(ob, do_unlink=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "Flow2-84-%s.blend" % FINISH))
    bpy.ops.object.select_all(action="DESELECT")
    for ob in kb.objects:
        ob.select_set(True)
    usd = os.path.join(OUT, "Flow2-84-%s.usdz" % FINISH)
    bpy.ops.wm.usd_export(filepath=usd, selected_objects_only=True, export_materials=True,
                          export_uvmaps=True, export_normals=True, root_prim_path="/Flow2")
    print("exported", usd)
    try:
        bpy.ops.export_scene.gltf(filepath=os.path.join(OUT, "Flow2-84-%s.glb" % FINISH),
                                  export_format="GLB", use_selection=True)
    except Exception as e:
        print("glb export skipped:", e)
