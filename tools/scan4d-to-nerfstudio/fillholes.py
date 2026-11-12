#!/usr/bin/env python3
"""Repair the ARKit mesh before rendering priors: debias it, then fill planar holes.

Two defects measured on real scans (staging_5DABB526), both fixable from data we already
carry:

1. **Iso-surface bias.** The fused mesh sits a systematic ~2-3 cm *behind* the LiDAR
   surface (mesh depth - LiDAR depth: median +3.1 cm, IQR +2.6..+4.7, all positive — a
   translation would flip sign with view direction; this doesn't). Displacing vertices
   along their normals removes it. `debias()` measures the bias against the scan's own
   LiDAR frames and displaces by exactly that, per scan, with one refinement pass.

2. **Holes in flat surfaces.** Table tops were 55-81 % covered by the mesh while the LiDAR
   had seen 84-98 % of the same cells. RoomPlan gives us the plane hypotheses (every
   surface/box face: centre, in-plane axes, normal, extent); the LiDAR points confirm which
   parts of each plane actually exist. On a 3 cm grid in the plane: mark cells with LiDAR
   evidence, morphologically close + fill enclosed holes, clip to the RoomPlan footprint,
   subtract doors/windows/openings, and patch only the cells the mesh does not already
   cover. The patch sits at the LiDAR-fitted plane offset, not RoomPlan's nominal one.
   Evidence gating is what makes this safe: a round table on a rectangular RoomPlan box
   only gets the disc filled, because the corners have no evidence to enclose.

RoomPlan conventions (verified on roomplan.json v1): `transform` is column-major 4x4;
local x spans `width`, local y spans `height`, local z is the normal (surfaces have
depth 0). Objects are boxes; all six faces are used as plane hypotheses except for
chairs (concave — the box is not a surface).

Needs numpy, open3d, scipy (ndimage) — all in the nerfstudio image.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import open3d as o3d

CELL_M = 0.03            # in-plane grid pitch
PLANE_TOL_M = 0.04       # LiDAR point counts as "on the plane" within this
FOOTPRINT_MARGIN_M = 0.10
CLOSE_RADIUS_CELLS = 5   # 15 cm: bridges LiDAR sampling gaps without spanning real openings
MIN_EVIDENCE = 2         # LiDAR hits per cell before it counts
MESH_COVERED_M = 0.06    # cell already has mesh within this -> no patch
MIN_PATCH_CELLS = 20     # ignore specks
SKIP_CATEGORIES = {"chair"}


@dataclass
class Plane:
    label: str
    centre: np.ndarray      # (3,)
    u: np.ndarray           # in-plane axis, unit
    v: np.ndarray           # in-plane axis, unit
    n: np.ndarray           # normal, unit
    half_u: float
    half_v: float
    excludes: list = field(default_factory=list)  # (cu, cv, hu, hv) rects in plane coords
    # filled during processing
    grid: np.ndarray | None = None      # evidence counts (nv, nu)
    offsets: list = field(default_factory=list)  # signed distances of evidence, for refit

    def local(self, pts):
        d = pts - self.centre
        return d @ self.u, d @ self.v, d @ self.n

    def shape(self):
        nu = int(np.ceil(2 * (self.half_u + FOOTPRINT_MARGIN_M) / CELL_M))
        nv = int(np.ceil(2 * (self.half_v + FOOTPRINT_MARGIN_M) / CELL_M))
        return nv, nu

    def cell_centres(self):
        nv, nu = self.shape()
        cu = (np.arange(nu) + 0.5) * CELL_M - (self.half_u + FOOTPRINT_MARGIN_M)
        cv = (np.arange(nv) + 0.5) * CELL_M - (self.half_v + FOOTPRINT_MARGIN_M)
        return cu, cv


def _mat(transform):
    T = np.array(transform, dtype=np.float64).reshape(4, 4).T  # column-major -> row-major
    return T[:3, :3], T[:3, 3]


def roomplan_planes(rp: dict) -> list[Plane]:
    planes: list[Plane] = []
    openings = []
    for s in rp.get("surfaces", []):
        R, t = _mat(s["transform"])
        d = s["dimensions"]
        p = Plane(s["category"], t, R[:, 0], R[:, 1], R[:, 2], d["width"] / 2, d["height"] / 2)
        if s["category"] in ("door", "window", "opening"):
            openings.append(p)
        else:
            planes.append(p)
    # Attach openings to the wall they lie in (same plane within 10 cm, centre inside extent).
    for o in openings:
        for w in planes:
            if w.label != "wall":
                continue
            lu, lv, ln = w.local(o.centre[None])
            if abs(ln[0]) < 0.10 and abs(lu[0]) <= w.half_u + 0.05 and abs(lv[0]) <= w.half_v + 0.05:
                w.excludes.append((lu[0], lv[0], o.half_u + 0.03, o.half_v + 0.03))
                break
    for o in rp.get("objects", []):
        if o["category"] in SKIP_CATEGORIES:
            continue
        R, t = _mat(o["transform"])
        d = o["dimensions"]
        ax = [R[:, 0], R[:, 1], R[:, 2]]
        half = [d["width"] / 2, d["height"] / 2, d["depth"] / 2]
        for k in range(3):
            for sgn in (+1, -1):
                i, j = (k + 1) % 3, (k + 2) % 3
                n = sgn * ax[k]
                planes.append(Plane(f"{o['category']}:{'+-'[sgn < 0]}{'xyz'[k]}",
                                    t + n * half[k], ax[i], ax[j], n, half[i], half[j]))
    return planes


def accumulate_evidence(planes: list[Plane], pts: np.ndarray):
    """Bin world points into every plane's grid they lie on (within PLANE_TOL_M)."""
    for p in planes:
        lu, lv, ln = p.local(pts)
        m = (np.abs(ln) < PLANE_TOL_M) & (np.abs(lu) < p.half_u + FOOTPRINT_MARGIN_M) \
            & (np.abs(lv) < p.half_v + FOOTPRINT_MARGIN_M)
        if not m.any():
            continue
        nv, nu = p.shape()
        iu = ((lu[m] + p.half_u + FOOTPRINT_MARGIN_M) / CELL_M).astype(np.int64).clip(0, nu - 1)
        iv = ((lv[m] + p.half_v + FOOTPRINT_MARGIN_M) / CELL_M).astype(np.int64).clip(0, nv - 1)
        if p.grid is None:
            p.grid = np.zeros((nv, nu), np.int32)
        np.add.at(p.grid, (iv, iu), 1)
        if len(p.offsets) < 200_000:
            p.offsets.extend(ln[m][:: max(1, m.sum() // 2000)].tolist())


def build_patches(planes: list[Plane], scene) -> tuple[o3d.geometry.TriangleMesh, list[str]]:
    from scipy import ndimage

    verts, tris, report = [], [], []
    disk = np.ones((2 * CLOSE_RADIUS_CELLS + 1,) * 2, bool)
    yy, xx = np.ogrid[-CLOSE_RADIUS_CELLS:CLOSE_RADIUS_CELLS + 1, -CLOSE_RADIUS_CELLS:CLOSE_RADIUS_CELLS + 1]
    disk &= (xx ** 2 + yy ** 2) <= CLOSE_RADIUS_CELLS ** 2

    for p in planes:
        if p.grid is None:
            continue
        E = p.grid >= MIN_EVIDENCE
        if E.sum() < MIN_PATCH_CELLS:
            continue
        F = ndimage.binary_fill_holes(ndimage.binary_closing(E, structure=disk))
        F &= ndimage.binary_dilation(E, structure=disk)  # never grow past 15 cm from evidence
        cu, cv = p.cell_centres()
        CU, CV = np.meshgrid(cu, cv)
        inside = (np.abs(CU) <= p.half_u + 0.03) & (np.abs(CV) <= p.half_v + 0.03)
        for (eu, ev, hu, hv) in p.excludes:
            inside &= ~((np.abs(CU - eu) <= hu) & (np.abs(CV - ev) <= hv))
        F &= inside
        if not F.any():
            continue
        # Refit the plane offset to the LiDAR: the patch goes where the sensor saw the surface.
        off = float(np.median(p.offsets)) if p.offsets else 0.0
        centres = p.centre + off * p.n + CU[F][:, None] * p.u + CV[F][:, None] * p.v
        dm = scene.compute_distance(o3d.core.Tensor(centres.astype(np.float32))).numpy()
        hole = np.zeros_like(F)
        hole[F] = dm > MESH_COVERED_M
        n_hole = int(hole.sum())
        report.append(f"  {p.label:<14} footprint {int(inside.sum()):>6} cells | evidence {100 * E[inside].mean():3.0f}% "
                      f"| filled {100 * F[inside].mean():3.0f}% | mesh missing {n_hole:>5} cells "
                      f"({n_hole * CELL_M * CELL_M:.2f} m²) | offset {100 * off:+.1f} cm")
        if n_hole < MIN_PATCH_CELLS:
            continue
        # Two triangles per hole cell. Cell corners in plane coords.
        base = len(verts)
        iv, iu = np.nonzero(hole)
        for k, (i, j) in enumerate(zip(iv, iu)):
            u0, v0 = cu[j] - CELL_M / 2, cv[i] - CELL_M / 2
            for du, dv in ((0, 0), (CELL_M, 0), (CELL_M, CELL_M), (0, CELL_M)):
                verts.append(p.centre + off * p.n + (u0 + du) * p.u + (v0 + dv) * p.v)
            b = base + 4 * k
            tris.append((b, b + 1, b + 2))
            tris.append((b, b + 2, b + 3))
    patch = o3d.geometry.TriangleMesh()
    if tris:
        patch.vertices = o3d.utility.Vector3dVector(np.array(verts))
        patch.triangles = o3d.utility.Vector3iVector(np.array(tris, np.int32))
        patch.merge_close_vertices(1e-4)
    return patch, report


def debias(mesh: o3d.geometry.TriangleMesh, measure_bias, rounds: int = 2):
    """Displace vertices along their normals until mesh depth matches LiDAR depth.

    `measure_bias(mesh)` returns median(mesh_depth - lidar_depth) in metres over sample
    frames. Positive = mesh behind the true surface -> push outward (along +normal, which
    ARKit orients toward free space). Depth changes by d/cos(view angle) per unit of
    normal displacement, so one pass over-/under-shoots; a second pass converges.
    """
    mesh.compute_vertex_normals()
    total = 0.0
    hist = []
    for _ in range(rounds):
        b = measure_bias(mesh)
        hist.append(b)
        if abs(b) < 0.003:
            break
        step = 0.7 * b  # damped: depth responds ~1.4x to normal displacement
        v = np.asarray(mesh.vertices) + step * np.asarray(mesh.vertex_normals)
        mesh.vertices = o3d.utility.Vector3dVector(v)
        total += step
    hist.append(measure_bias(mesh))
    return mesh, total, hist


# --- ceiling -------------------------------------------------------------------------
# RoomPlan has no ceiling category and its wall heights inflate to the tallest extent, so the
# ceiling is MEASURED from the mesh's own downward-facing faces and extended locally. The
# extension is normals-only (see meshrender: depthless geometry): a flat down-facing normal is
# right even when the height is 30 cm off, a depth prior at the wrong height actively pulls.
CEIL_CELL_M = 0.10
CEIL_MIN_HEIGHT_M = 2.3          # below this a down-facing face is a shelf/cabinet underside
CEIL_MIN_AREA_M2 = 2.0           # measured fragments needed before extrapolating at all
CEIL_MIN_AREA_FRAC = 0.05        # ... and at least this fraction of the footprint
CEIL_PEAK_TOL_M = 0.15           # fragments within this of the peak count as "the" ceiling
CEIL_MIN_PEAK_FRAC = 0.70        # else multimodal (soffits, ducts, mezzanine) -> refuse
CEIL_CONTRADICT_M = 0.20         # other geometry this far off-plane in a column blocks it
CEIL_MAX_EXTEND_M = 4.0          # never grow farther than this from a measured fragment
CEIL_DOWN_NY = -0.9              # triangle normal y below this = faces the room


# ARMeshClassification raw values, one byte per emitted face in face_classes.bin (aligned to
# mesh.obj face order; rigid transforms and debias preserve it, appended patches do not have it).
LABEL_NONE, LABEL_WALL, LABEL_FLOOR, LABEL_CEILING = 0, 1, 2, 3
LABEL_TABLE, LABEL_SEAT, LABEL_WINDOW, LABEL_DOOR = 4, 5, 6, 7


def load_face_classes(path: Path, n_faces: int):
    b = np.frombuffer(Path(path).read_bytes(), dtype=np.uint8)
    if len(b) != n_faces:
        print(f"face classes: {len(b)} labels for {n_faces} faces — ignoring {Path(path).name}")
        return None
    return b


FLOOR_PEAK_TOL_M = 0.10
FLOOR_MIN_PEAK_FRAC = 0.80       # else split-level / stairs -> refuse
FLOOR_MIN_AREA_M2 = 2.0
FLOOR_MARGIN_M = 0.05


def build_floor(mesh: o3d.geometry.TriangleMesh, planes: list[Plane], labels=None):
    """Full floor quad at the LiDAR-measured height. Returns (quad mesh, report lines).

    The floor is the one surface a plain quad is right for: gravity makes it flat, RoomPlan
    gives the footprint, the mesh's floor-labelled faces give the height, and anything
    standing on it occludes it naturally in the ray-cast. Carries depth AND normals. Refuses
    when the labelled-floor heights are not one peak (split levels, stairs).
    """
    rep = []
    floors = [p for p in planes if p.label == "floor"]
    walls = [p for p in planes if p.label == "wall"]
    if not floors or len(walls) < 3:
        rep.append("  floor: skipped — needs a RoomPlan floor and >= 3 walls (not a room)")
        return o3d.geometry.TriangleMesh(), rep
    floor = floors[0]
    mesh.compute_triangle_normals()
    tri = np.asarray(mesh.triangles)
    v = np.asarray(mesh.vertices)
    tn = np.asarray(mesh.triangle_normals)
    cen = v[tri].mean(axis=1)
    area = 0.5 * np.linalg.norm(np.cross(v[tri[:, 1]] - v[tri[:, 0]], v[tri[:, 2]] - v[tri[:, 0]]), axis=1)
    lu, lv, ln = floor.local(cen)
    in_fp = (np.abs(lu) <= floor.half_u + 0.3) & (np.abs(lv) <= floor.half_v + 0.3)
    up = (tn @ floor.n) > 0.9
    if labels is not None:
        cand = up & in_fp & (labels == LABEL_FLOOR)
        src = "floor-labelled faces"
    else:
        cand = up & in_fp & (np.abs(ln) < 0.3)
        src = "up-facing faces near the RoomPlan floor"
    meas = float(area[cand].sum())
    if meas < FLOOR_MIN_AREA_M2:
        rep.append(f"  floor: skipped — only {meas:.2f} m² of {src}")
        return o3d.geometry.TriangleMesh(), rep
    bins = np.arange(ln[cand].min() - 0.05, ln[cand].max() + 0.1, 0.05)
    hist, _ = np.histogram(ln[cand], bins=bins, weights=area[cand])
    peak = float(bins[int(np.argmax(hist))] + 0.025)
    near = cand & (np.abs(ln - peak) <= FLOOR_PEAK_TOL_M)
    frac = float(area[near].sum() / meas)
    off = float(np.average(ln[near], weights=area[near]))
    if frac < FLOOR_MIN_PEAK_FRAC:
        rep.append(f"  floor: skipped — multimodal: only {100 * frac:.0f}% of {meas:.2f} m² within "
                   f"±{100 * FLOOR_PEAK_TOL_M:.0f} cm of the {peak:+.2f} m peak")
        return o3d.geometry.TriangleMesh(), rep
    hu, hv = floor.half_u + FLOOR_MARGIN_M, floor.half_v + FLOOR_MARGIN_M
    c = floor.centre + off * floor.n
    corners = [c - hu * floor.u - hv * floor.v, c + hu * floor.u - hv * floor.v,
               c + hu * floor.u + hv * floor.v, c - hu * floor.u + hv * floor.v]
    quad = o3d.geometry.TriangleMesh()
    quad.vertices = o3d.utility.Vector3dVector(np.array(corners))
    quad.triangles = o3d.utility.Vector3iVector(np.array([[0, 1, 2], [0, 2, 3]], np.int32))
    rep.append(f"  floor: full quad {2 * hu:.1f} x {2 * hv:.1f} m at {100 * off:+.1f} cm from RoomPlan floor "
               f"({meas:.1f} m² of {src}, {100 * frac:.0f}% in one peak) — depth + normals")
    return quad, rep


def build_ceiling(mesh: o3d.geometry.TriangleMesh, planes: list[Plane], labels=None):
    """Measured-ceiling extension. Returns (patch mesh, report lines, height or None)."""
    from scipy import ndimage

    rep = []
    floors = [p for p in planes if p.label == "floor"]
    walls = [p for p in planes if p.label == "wall"]
    if not floors or len(walls) < 3:
        rep.append("  ceiling: skipped — needs a RoomPlan floor and >= 3 walls (not a room)")
        return o3d.geometry.TriangleMesh(), rep, None
    floor = floors[0]
    floor_y = float(floor.centre[1])
    fu, fv = floor.u, floor.v            # in-plane axes of the floor (horizontal)
    hu, hv = floor.half_u, floor.half_v

    mesh.compute_triangle_normals()
    tri = np.asarray(mesh.triangles)
    v = np.asarray(mesh.vertices)
    tn = np.asarray(mesh.triangle_normals)
    cen = v[tri].mean(axis=1)
    area = 0.5 * np.linalg.norm(np.cross(v[tri[:, 1]] - v[tri[:, 0]], v[tri[:, 2]] - v[tri[:, 0]]), axis=1)
    h = cen[:, 1] - floor_y
    lu = (cen - floor.centre) @ fu
    lv = (cen - floor.centre) @ fv
    in_fp = (np.abs(lu) <= hu + 0.05) & (np.abs(lv) <= hv + 0.05)
    down = tn[:, 1] < CEIL_DOWN_NY
    if labels is not None:
        # ARKit's own semantic labels beat the geometric heuristic: cabinet undersides and
        # duct bottoms are down-facing too, but are not labelled ceiling.
        cand = down & in_fp & (labels == LABEL_CEILING) & (h > 1.5)
        src = "ceiling-labelled"
    else:
        cand = down & in_fp & (h > CEIL_MIN_HEIGHT_M)
        src = "down-facing"
    footprint_area = 4 * hu * hv
    meas_area = float(area[cand].sum())
    if meas_area < max(CEIL_MIN_AREA_M2, CEIL_MIN_AREA_FRAC * footprint_area):
        rep.append(f"  ceiling: skipped — only {meas_area:.2f} m² of {src} mesh "
                   f"(footprint {footprint_area:.1f} m²)")
        return o3d.geometry.TriangleMesh(), rep, None

    # Area-weighted height histogram; the ceiling is the dominant peak.
    bins = np.arange(CEIL_MIN_HEIGHT_M, h[cand].max() + 0.1, 0.05)
    hist, _ = np.histogram(h[cand], bins=bins, weights=area[cand])
    sm = np.convolve(hist, np.ones(3), mode="same")
    peak_h = float(bins[int(np.argmax(sm))] + 0.025)
    near = cand & (np.abs(h - peak_h) <= CEIL_PEAK_TOL_M)
    ceil_h = float(np.average(h[near], weights=area[near]))
    frac = float(area[near].sum() / meas_area)
    if frac < CEIL_MIN_PEAK_FRAC:
        rep.append(f"  ceiling: skipped — multimodal: only {100 * frac:.0f}% of {meas_area:.2f} m² "
                   f"within ±{100 * CEIL_PEAK_TOL_M:.0f} cm of the {peak_h:.2f} m peak")
        return o3d.geometry.TriangleMesh(), rep, None

    # 2D footprint grid. M = measured ceiling cells, B = blocked (other geometry in the column
    # above CEIL_MIN_HEIGHT_M that is not at the ceiling height: soffits, ducts, walls rising
    # above the plane — a mezzanine underside would also land here).
    nu = int(np.ceil(2 * hu / CEIL_CELL_M))
    nv = int(np.ceil(2 * hv / CEIL_CELL_M))

    def cells(mask):
        iu = ((lu[mask] + hu) / CEIL_CELL_M).astype(np.int64).clip(0, nu - 1)
        iv = ((lv[mask] + hv) / CEIL_CELL_M).astype(np.int64).clip(0, nv - 1)
        g = np.zeros((nv, nu), bool)
        g[iv, iu] = True
        return g

    M = cells(near)
    other = in_fp & (h > CEIL_MIN_HEIGHT_M) & (np.abs(h - ceil_h) > CEIL_CONTRADICT_M)
    B = cells(other) & ~M
    # Wall tops rising above the plane also block: any vertex well above the ceiling.
    vh = v[:, 1] - floor_y
    vlu = (v - floor.centre) @ fu
    vlv = (v - floor.centre) @ fv
    above = (vh > ceil_h + CEIL_CONTRADICT_M) & (np.abs(vlu) <= hu + 0.05) & (np.abs(vlv) <= hv + 0.05)
    if above.any():
        iu = ((vlu[above] + hu) / CEIL_CELL_M).astype(np.int64).clip(0, nu - 1)
        iv = ((vlv[above] + hv) / CEIL_CELL_M).astype(np.int64).clip(0, nv - 1)
        B[iv, iu] = True
    B &= ~M

    # Local growth from measured cells through unblocked cells, bounded in distance.
    grown = M.copy()
    steps = int(CEIL_MAX_EXTEND_M / CEIL_CELL_M)
    for _ in range(steps):
        nxt = ndimage.binary_dilation(grown) & ~B
        if (nxt == grown).all():
            break
        grown = nxt
    E = grown & ~M
    rep.append(f"  ceiling: measured {area[near].sum():.2f} m² at {ceil_h:.2f} m above floor "
               f"({100 * frac:.0f}% of {src} area in one peak); extended {E.sum() * CEIL_CELL_M ** 2:.2f} m², "
               f"blocked {int(B.sum())} cells by other geometry")
    if not E.any():
        return o3d.geometry.TriangleMesh(), rep, ceil_h

    verts, tris = [], []
    y = floor_y + ceil_h
    iv, iu = np.nonzero(E)
    for k, (i, j) in enumerate(zip(iv, iu)):
        u0 = -hu + j * CEIL_CELL_M
        v0 = -hv + i * CEIL_CELL_M
        for du, dv in ((0, 0), (CEIL_CELL_M, 0), (CEIL_CELL_M, CEIL_CELL_M), (0, CEIL_CELL_M)):
            p = floor.centre + (u0 + du) * fu + (v0 + dv) * fv
            verts.append([p[0], y, p[2]])
        b = 4 * k
        tris.append((b, b + 1, b + 2))
        tris.append((b, b + 2, b + 3))
    patch = o3d.geometry.TriangleMesh()
    patch.vertices = o3d.utility.Vector3dVector(np.array(verts))
    patch.triangles = o3d.utility.Vector3iVector(np.array(tris, np.int32))
    patch.merge_close_vertices(1e-4)
    return patch, rep, ceil_h


def transform_planes(planes: list[Plane], M: np.ndarray) -> list[Plane]:
    """Rigidly move planes by 4x4 M (used to undo the canonical-frame registration so
    RoomPlan lands in the same raw capture frame as the cameras)."""
    R = M[:3, :3]
    for p in planes:
        p.centre = (M @ np.append(p.centre, 1.0))[:3]
        p.u, p.v, p.n = R @ p.u, R @ p.v, R @ p.n
    return planes


def load_roomplan(path: Path) -> list[Plane]:
    rp = json.loads(Path(path).read_text())
    return roomplan_planes(rp)
