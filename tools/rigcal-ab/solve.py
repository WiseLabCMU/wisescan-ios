"""Photometric (ZNCC) rig solver — offline A/B against the device's edge cost.
Model identical to v14: camPos = phonePos + R_WP*t_P, gravity-leveled yaw.
Cost: 1 - trimmed mean ZNCC over (keyframe, still) pairs. No pitch, no elevation
nuisance — whether it needs them is measured afterward, not assumed."""
import glob, json, math, os, sys, time
import numpy as np

CACHE = os.path.expanduser("~/Downloads/ab_cache")
EQW, EQH = 1024, 512

def compose(phone, t, yaw):
    R = phone[:3, :3]; pos = phone[:3, 3]
    cam = pos + R @ t
    fwd = -R[:, 2]; h = np.array([fwd[0], 0, fwd[2]])
    if np.linalg.norm(h) < 1e-3:
        up = R[:, 1]; h = np.array([up[0], 0, up[2]])
    f = h/np.linalg.norm(h)
    c, s = math.cos(yaw), math.sin(yaw)
    f = np.array([c*f[0]+s*f[2], 0, -s*f[0]+c*f[2]])  # rotate about +Y
    right = np.cross([0, 1, 0], -f); right /= np.linalg.norm(right)
    upv = np.cross(-f, right)
    Rc = np.stack([right, upv, -f], 1)   # columns: right, up, back
    return cam, Rc

def project(pts, cam, Rc):
    d = (pts - cam) @ Rc                 # world→cam = R^T · (p - cam)
    n = np.linalg.norm(d, axis=1)
    ok = n > 0.3
    dn = d/np.maximum(n, 1e-9)[:, None]
    lat = np.arcsin(np.clip(dn[:, 1], -1, 1))
    lon = np.arctan2(dn[:, 0], -dn[:, 2])
    x = (lon+math.pi)/(2*math.pi)*EQW
    y = (math.pi/2-lat)/math.pi*EQH
    return np.clip(x.astype(int), 0, EQW-1), np.clip(y.astype(int), 0, EQH-1), ok

class Scan:
    def __init__(self, npz, name):
        z = np.load(npz, allow_pickle=False)
        self.name = name
        self.stills = z["stills"]; self.masks = z["masks"]; self.gvecs = z["gvecs"]
        self.metas = json.loads(str(z["metas"]))
        self.pts = z["pts"]; self.grays = z["grays"]
        self.kfc = z["kf_counts"]
        # subsample to ~8k points, preserving per-keyframe boundaries
        idx = []
        start = 0; total = self.kfc.sum(); stride = max(1, total//8000)
        self.kf_slices = []
        for c in self.kfc:
            sel = np.arange(start, start+c, stride); idx.append(sel)
            self.kf_slices.append(len(sel)); start += c
        idx = np.concatenate(idx)
        self.pts = self.pts[idx]; self.grays = self.grays[idx]
        self.phones = [np.array(m["phone"], np.float32) for m in self.metas]
        sways = [m["sway"] for m in self.metas]
        order = np.argsort(sways)
        self.solve_set = [i for i in order if sways[i] <= 0.040][:5]
        # measured rod direction from camera gravity (Horn fit), else -x
        self.rod = self.rod_direction()
    def rod_direction(self):
        A, B = [], []
        for i, m in enumerate(self.phones):
            g = self.gvecs[i]
            if np.linalg.norm(g) < 0.5: continue
            local = -m[1, :3]                       # gravity in phone frame = -(row y of R)
            if np.linalg.norm(local) < 0.5: continue
            A.append(local/np.linalg.norm(local)); B.append(g/np.linalg.norm(g))
        if len(A) < 4: return None
        A, B = np.array(A), np.array(B)
        S = A.T @ B
        N = np.array([[S[0,0]+S[1,1]+S[2,2], S[1,2]-S[2,1], S[2,0]-S[0,2], S[0,1]-S[1,0]],
                      [S[1,2]-S[2,1], S[0,0]-S[1,1]-S[2,2], S[0,1]+S[1,0], S[2,0]+S[0,2]],
                      [S[2,0]-S[0,2], S[0,1]+S[1,0], -S[0,0]+S[1,1]-S[2,2], S[1,2]+S[2,1]],
                      [S[0,1]-S[1,0], S[2,0]+S[0,2], S[1,2]+S[2,1], -S[0,0]-S[1,1]+S[2,2]]])
        w, V = np.linalg.eigh(N); q = V[:, -1]
        R = np.array([[1-2*(q[2]**2+q[3]**2), 2*(q[1]*q[2]-q[3]*q[0]), 2*(q[1]*q[3]+q[2]*q[0])],
                      [2*(q[1]*q[2]+q[3]*q[0]), 1-2*(q[1]**2+q[3]**2), 2*(q[2]*q[3]-q[1]*q[0])],
                      [2*(q[1]*q[3]-q[2]*q[0]), 2*(q[2]*q[3]+q[1]*q[0]), 1-2*(q[1]**2+q[2]**2)]])
        gmean = B.mean(0); ax = np.argmax(np.abs(gmean))
        body = np.zeros(3); body[ax] = np.sign(gmean[ax])
        rod = -(R.T @ body); rod /= np.linalg.norm(rod)
        return rod.astype(np.float32)
    def cost(self, t, yaw, still_ids=None, elev_rows=0.0):
        zn, total_pairs = [], 0
        for s in (still_ids if still_ids is not None else self.solve_set):
            cam, Rc = compose(self.phones[s], t, yaw)
            x, y, ok = project(self.pts, cam, Rc)
            if elev_rows: y = np.clip(y + int(round(elev_rows)), 0, EQH-1)
            keep = ok & (self.masks[s][y, x] > 0.5)
            pred = self.stills[s][y, x]
            start = 0
            for n in self.kf_slices:
                sl = slice(start, start+n); start += n
                k = keep[sl]
                if k.sum() < 60: total_pairs += 1; continue
                a = pred[sl][k]; b = self.grays[sl][k]
                sa, sb = a.std(), b.std()
                total_pairs += 1
                if sa < 1e-4 or sb < 1e-4: continue
                zn.append(((a-a.mean())*(b-b.mean())).mean()/(sa*sb))
        if not zn: return 2.0
        zn = np.sort(np.array(zn))
        keepn = max(1, int(len(zn)*0.8))       # drop worst 20%
        return 1.0 - zn[-keepn:].mean() if False else 1.0 - zn[len(zn)-keepn:].mean()

def nelder_mead(f, x0, scales, iters=250, tol=1e-5):
    n = len(x0)
    simplex = [np.array(x0, float)]
    for d in range(n):
        v = np.array(x0, float); v[d] += scales[d]; simplex.append(v)
    vals = [f(v) for v in simplex]
    for it in range(iters):
        o = np.argsort(vals); simplex = [simplex[i] for i in o]; vals = [vals[i] for i in o]
        if vals[-1]-vals[0] < tol: break
        cen = np.mean(simplex[:-1], 0)
        xr = cen + (cen - simplex[-1]); fr = f(xr)
        if fr < vals[0]:
            xe = cen + 2*(xr-cen); fe = f(xe)
            simplex[-1], vals[-1] = (xe, fe) if fe < fr else (xr, fr)
        elif fr < vals[-2]:
            simplex[-1], vals[-1] = xr, fr
        else:
            xc = cen + 0.5*(simplex[-1]-cen); fc = f(xc)
            if fc < vals[-1]: simplex[-1], vals[-1] = xc, fc
            else:
                for i in range(1, n+1):
                    simplex[i] = simplex[0] + 0.5*(simplex[i]-simplex[0]); vals[i] = f(simplex[i])
    o = np.argsort(vals)
    return simplex[o[0]], vals[o[0]], it+1

def solve(scan, tape, mode):
    rod = scan.rod if scan.rod is not None else np.array([-1, 0, 0], np.float32)
    anchor = tape*rod
    # coarse yaw circle at the anchor
    ys = np.linspace(-math.pi, math.pi, 72, endpoint=False)
    cs = [scan.cost(anchor, y) for y in ys]
    y0 = ys[int(np.argmin(cs))]
    if mode == "parity":
        along, across = 0.03, 0.07
    else:
        along, across = 0.25, 0.25
    ywin = math.radians(35)
    def clamp_cost(v):
        t, yaw = v[:3], v[3]
        d = t - anchor; a = d @ rod; ac = np.linalg.norm(d - a*rod)
        if abs(a) > along or ac > across or abs(yaw-y0) > ywin: return 3.0
        return scan.cost(t, yaw)
    x, c, it = nelder_mead(clamp_cost, [*anchor, y0], [0.02, 0.02, 0.02, 0.08])
    t, yaw = x[:3], x[3]
    # per-still yaw at solved t (all stills, not just solve set)
    per = []
    for s in range(len(scan.phones)):
        fine = np.linspace(yaw-math.radians(12), yaw+math.radians(12), 49)
        cc = [scan.cost(t, yy, still_ids=[s]) for yy in fine]
        per.append(math.degrees(fine[int(np.argmin(cc))]-yaw))
    # residual elevation bias at the solution
    rows = np.arange(-32, 33, 4)
    ec = [scan.cost(t, yaw, elev_rows=r) for r in rows]
    elev_deg = rows[int(np.argmin(ec))]*180/EQH
    return dict(t=[float(v) for v in t], length=float(np.linalg.norm(t)), yaw=float(math.degrees(yaw)),
                zncc=float(1-c), coarse_yaw=float(math.degrees(y0)), per_still_spread=float(np.ptp(per)),
                elev_bias_deg=float(elev_deg), iters=it,
                rod_off_deg=float(math.degrees(math.acos(np.clip(-rod[0], -1, 1)))) if scan.rod is not None else None)

ERA_686 = {"AF13FA67","BFED9CD2","FDBFC10A","AB32CCA8","B42F9231","654993FF","60172200","4A99660B"}
out = {}
files = sorted(glob.glob(CACHE+"/*.npz"))
only = set(sys.argv[1:]) if len(sys.argv) > 1 else None
for f in files:
    name = os.path.basename(f)[:-4]
    if only and name not in only: continue
    t0 = time.time()
    scan = Scan(f, name)
    if len(scan.solve_set) < 3:
        print(name, "SKIP <3 usable stills", flush=True); continue
    tape = 0.686 if name in ERA_686 else 0.724
    res = {m: solve(scan, tape, m) for m in ("parity", "free")}
    out[name] = dict(tape=tape, stills=len(scan.phones), used=len(scan.solve_set),
                     model=scan.metas[0]["model"], **{f"{k}_{m}": v for m, r in res.items() for k, v in r.items()})
    p, fr = res["parity"], res["free"]
    print(f"{name} [{scan.metas[0]['model'][-2:]}] tape={tape:.3f} | "
          f"parity |t|={p['length']:.3f} yaw={p['yaw']:+6.1f} zncc={p['zncc']:.3f} | "
          f"FREE |t|={fr['length']:.3f} Δtape={100*(fr['length']-tape):+.1f}cm yaw={fr['yaw']:+6.1f} "
          f"spread={fr['per_still_spread']:.1f}° elev={fr['elev_bias_deg']:+.1f}° "
          f"({time.time()-t0:.0f}s)", flush=True)
json.dump(out, open(CACHE+"/results.json", "w"), indent=1)
print("saved", CACHE+"/results.json")
