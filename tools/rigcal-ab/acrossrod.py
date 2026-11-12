#!/usr/bin/env python3
"""#52: why does the across-rod solve component ride the +/-7 cm wall?

Uses the FREE-mode solutions already in ab_cache/results.json (the +/-25 cm box:
what the photometric cost wants with no tape), plus a fresh Horn rod fit per
bundle, to separate the issue's three candidates:

(a) gravity cross-axis noise  -> leave-one-out rod-fit spread, converted to cm of
    across-rod shift at tape length; if it covers the observed disagreement, the
    gravity anchor is simply that uncertain.
(b) a real clamp offset       -> the across-rod disagreement VECTOR should point the
    same way (phone frame) across every scan of the same rig era; resultant/mean
    ratio near 1 = consistent physical offset the gravity model cannot see.
(c) photometric across pull   -> disagreement uncorrelated with gravity quality and
    inconsistent in direction, present regardless of era.
"""
import json, os, glob, math, sys
import numpy as np

CACHE = os.path.expanduser(os.environ.get("AB_CACHE", "~/Downloads/ab_cache"))
res = json.load(open(CACHE + "/results.json"))
ERA_686 = {"AF13FA67","BFED9CD2","FDBFC10A","AB32CCA8","B42F9231","654993FF","60172200","4A99660B"}

def horn(A, B):
    S = A.T @ B
    N = np.array([[S[0,0]+S[1,1]+S[2,2], S[1,2]-S[2,1], S[2,0]-S[0,2], S[0,1]-S[1,0]],
                  [S[1,2]-S[2,1], S[0,0]-S[1,1]-S[2,2], S[0,1]+S[1,0], S[2,0]+S[0,2]],
                  [S[2,0]-S[0,2], S[0,1]+S[1,0], -S[0,0]+S[1,1]-S[2,2], S[1,2]+S[2,1]],
                  [S[0,1]-S[1,0], S[2,0]+S[0,2], S[1,2]+S[2,1], -S[0,0]-S[1,1]+S[2,2]]])
    w, V = np.linalg.eigh(N); q = V[:, -1]
    return np.array([[1-2*(q[2]**2+q[3]**2), 2*(q[1]*q[2]-q[3]*q[0]), 2*(q[1]*q[3]+q[2]*q[0])],
                     [2*(q[1]*q[2]+q[3]*q[0]), 1-2*(q[1]**2+q[3]**2), 2*(q[2]*q[3]-q[1]*q[0])],
                     [2*(q[1]*q[3]-q[2]*q[0]), 2*(q[2]*q[3]+q[1]*q[0]), 1-2*(q[1]**2+q[2]**2)]])

def rod_from(A, B):
    R = horn(A, B)
    gmean = B.mean(0); ax = int(np.argmax(np.abs(gmean)))
    body = np.zeros(3); body[ax] = np.sign(gmean[ax])
    r = -(R.T @ body); return r/np.linalg.norm(r)

rows=[]
for name, r in sorted(res.items()):
    npz = f"{CACHE}/{name}.npz"
    if not os.path.exists(npz): continue
    z = np.load(npz, allow_pickle=False)
    gv = z["gvecs"]; metas = json.loads(str(z["metas"]))
    A,Bv=[],[]
    for i,m in enumerate(metas):
        g=gv[i]; loc=-np.array(m["phone"],np.float32)[1,:3]
        if np.linalg.norm(g)<0.5 or np.linalg.norm(loc)<0.5: continue
        A.append(loc/np.linalg.norm(loc)); Bv.append(g/np.linalg.norm(g))
    if len(A)<4: continue
    A,Bv=np.array(A),np.array(Bv)
    rod=rod_from(A,Bv)
    # residuals + leave-one-out rod spread
    R=horn(A,Bv)
    resid=[math.degrees(math.acos(np.clip(np.dot(R@a,b),-1,1))) for a,b in zip(A,Bv)]
    loo=[]
    for i in range(len(A)):
        m=np.ones(len(A),bool); m[i]=False
        loo.append(math.degrees(math.acos(np.clip(abs(np.dot(rod_from(A[m],Bv[m]),rod)),-1,1))))
    tape = 0.686 if name in ERA_686 else 0.724
    era  = "686" if name in ERA_686 else "724"
    anchor = tape*rod
    ey = np.array([0,1,0],float); ey = ey-(ey@rod)*rod; ey/=np.linalg.norm(ey)
    ez = np.cross(rod,ey)
    out={}
    for mode in ("parity","free"):
        t=np.array(r[f"t_{mode}"]); d=t-anchor
        along=float(d@rod); acr=d-along*rod
        out[mode]=dict(along_cm=100*along, across_cm=100*float(np.linalg.norm(acr)),
                       ay=100*float(acr@ey), az=100*float(acr@ez))
    rows.append(dict(name=name, era=era, model=r["model"][-2:].strip(), tape=tape,
                     grav_mean=float(np.mean(resid)), grav_max=float(np.max(resid)),
                     loo_deg=float(np.max(loo)), grav_across_cm=100*tape*math.sin(math.radians(max(loo))),
                     zncc=float(r.get("zncc_free", r.get("zncc_parity",0)) or 0), **{f"{k}_{m}":v for m,o in out.items() for k,v in o.items()}))

print(f"{'bundle':<10}{'era':<5}{'mdl':<4}{'grav mean/max/loo°':<20}{'grav→cm':<9}{'FREE along':<11}{'FREE across (ay,az)cm':<24}{'parity across':<14}")
for r in rows:
    print(f"{r['name']:<10}{r['era']:<5}{r['model']:<4}"
          f"{r['grav_mean']:.1f}/{r['grav_max']:.1f}/{r['loo_deg']:.1f}{'':<8}"
          f"{r['grav_across_cm']:<9.1f}{r['along_cm_free']:<+11.1f}"
          f"{r['across_cm_free']:5.1f} ({r['ay_free']:+5.1f},{r['az_free']:+5.1f}){'':<6}"
          f"{r['across_cm_parity']:5.1f} ({r['ay_parity']:+5.1f},{r['az_parity']:+5.1f})")
for era in ("686","724"):
    sub=[r for r in rows if r['era']==era]
    if not sub: continue
    V=np.array([[r['ay_free'],r['az_free']] for r in sub])
    mags=np.linalg.norm(V,axis=1); resultant=np.linalg.norm(V.mean(0))
    print(f"\nera {era}: n={len(sub)}  mean|across|={mags.mean():.1f}cm  resultant/mean={resultant/mags.mean():.2f}"
          f"  mean vec=({V[:,0].mean():+.1f},{V[:,1].mean():+.1f})cm"
          f"  gravity-explains: {np.mean([r['grav_across_cm'] for r in sub]):.1f}cm")
corr=np.corrcoef([r['grav_across_cm'] for r in rows],[r['across_cm_free'] for r in rows])[0,1]
print(f"\ncorr(gravity-uncertainty cm, observed across cm) = {corr:+.2f}")
json.dump(rows, open(os.path.join(os.path.dirname(os.path.abspath(__file__)),'acrossrod-results.json'),'w'), indent=1)
