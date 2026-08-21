"""Prep: turn each staging bundle into a compact .npz the solver can load fast.
Replicates the device's data path exactly: LE-byte-stream depth, keyframe
unprojection through row-major t_XX cam-to-world, gray from the keyframe image."""
import json, glob, math, os, struct, subprocess, sys, zlib
import numpy as np

CACHE = os.path.expanduser(os.environ.get("AB_CACHE", "~/Downloads/ab_cache"))
EQW, EQH = 1024, 512
KFW = 256

def sh(cmd):
    subprocess.run(cmd, check=True, capture_output=True)

def pgm_gray(src, w, h, dst):
    if not os.path.exists(dst):
        sh(["ffmpeg", "-loglevel", "error", "-y", "-i", src,
            "-vf", f"scale={w}:{h}", "-pix_fmt", "gray", dst])
    with open(dst, "rb") as f:
        assert f.readline().strip() == b"P5"
        dims = f.readline().split()
        while dims and dims[0].startswith(b"#"): dims = f.readline().split()
        W, H = int(dims[0]), int(dims[1]); f.readline()
        return np.frombuffer(f.read(W*H), np.uint8).reshape(H, W).astype(np.float32)/255.0

def depth_le(path):
    d = open(path, "rb").read(); pos = 8; idat = b""; w = h = 0
    while pos < len(d):
        ln = struct.unpack(">I", d[pos:pos+4])[0]; typ = d[pos+4:pos+8]
        if typ == b"IHDR": w, h = struct.unpack(">II", d[pos+8:pos+16])
        if typ == b"IDAT": idat += d[pos+8:pos+8+ln]
        pos += 12+ln
    raw = zlib.decompress(idat); stride = w*2
    out = np.zeros((h, stride), np.uint8); prev = np.zeros(stride, np.uint8); i = 0
    for r in range(h):
        ft = raw[i]; i += 1
        line = np.frombuffer(raw[i:i+stride], np.uint8).copy(); i += stride
        if ft == 1:
            for x in range(2, stride): line[x] = (int(line[x])+int(line[x-2])) & 255
        elif ft == 2: line = (line.astype(np.int16)+prev).astype(np.uint8)
        elif ft == 3:
            for x in range(stride):
                a = int(line[x-2]) if x >= 2 else 0
                line[x] = (int(line[x]) + ((a+int(prev[x]))>>1)) & 255
        elif ft == 4:
            for x in range(stride):
                a = int(line[x-2]) if x >= 2 else 0
                b = int(prev[x]); c = int(prev[x-2]) if x >= 2 else 0
                p = a+b-c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (int(line[x])+pr) & 255
        out[r] = line; prev = line
    # LE byte stream = true millimetres (established on-device + offline)
    return out.reshape(h, w, 2)[:, :, 0].astype(np.uint16) | (out.reshape(h, w, 2)[:, :, 1].astype(np.uint16) << 8)

def gravity(jpg):
    d = open(jpg, "rb").read(400000); i = 2; exif = None
    while i < len(d)-4:
        if d[i] != 0xFF: break
        m = d[i+1]; ln = struct.unpack(">H", d[i+2:i+4])[0]; p = d[i+4:i+2+ln]
        if m == 0xE1 and p.startswith(b"Exif"): exif = p[6:]; break
        if m == 0xDA: break
        i += 2+ln
    if exif is None or exif[:2] != b"MM": return None
    def ifd(o):
        n = struct.unpack(">H", exif[o:o+2])[0]; out = {}
        for k in range(n):
            e = o+2+k*12; tag, typ, cnt = struct.unpack(">HHI", exif[e:e+8])
            sz = {1:1,2:1,3:2,4:4,5:8,7:1,9:4,10:8}.get(typ,1)*cnt
            val = exif[e+8:e+8+sz] if sz <= 4 else exif[struct.unpack(">I", exif[e+8:e+12])[0]:][:sz]
            out[tag] = val
        return out
    i0 = ifd(struct.unpack(">I", exif[4:8])[0])
    if 0x8769 not in i0: return None
    ex = ifd(struct.unpack(">I", i0[0x8769][:4])[0])
    mn = ex.get(0x927C)
    if mn is None: return None
    for o in range(0, len(mn)-24, 2):
        try: v = [struct.unpack(">iI", mn[o+8*k:o+8*k+8]) for k in range(3)]
        except struct.error: break
        d0 = v[0][1]
        if d0 < 1000 or any(dd != d0 for _, dd in v): continue
        vec = np.array([n/d0 for n, dd in v], np.float32)
        if abs(np.linalg.norm(vec)-1) < 0.01: return vec
    return None

def prep(bundle):
    name = os.path.basename(bundle)[8:16]
    out = os.path.join(CACHE, name+".npz")
    if os.path.exists(out): return out
    tmp = os.path.join(CACHE, "tmp_"+name); os.makedirs(tmp, exist_ok=True)
    sj = sorted(glob.glob(bundle+"/equirect_stills/*.json"))
    stills, metas, masks, gvecs = [], [], [], []
    for j in sj:
        meta = json.load(open(j))
        jpg = j[:-5]+".JPG"
        if not os.path.exists(jpg): continue
        stills.append(pgm_gray(jpg, EQW, EQH, os.path.join(tmp, os.path.basename(jpg)+".pgm")))
        g = gravity(jpg)
        gvecs.append(g if g is not None else np.zeros(3, np.float32))
        mpath = bundle+"/equirect_masks/"+os.path.basename(j)[:-5]+".png"
        masks.append(pgm_gray(mpath, EQW, EQH, os.path.join(tmp, os.path.basename(mpath)+".pgm"))
                     if os.path.exists(mpath) else np.ones((EQH, EQW), np.float32))
        m = np.array(meta["phone_transform"], np.float32).reshape(4, 4, order="F")  # column-major
        sway = (meta.get("exposure_motion_m") or meta.get("trigger_motion_m") or 0)
        sdeg = (meta.get("exposure_motion_deg") or meta.get("trigger_motion_deg") or 0)
        metas.append(dict(phone=m.tolist(), sway=float(sway)+0.686*math.tan(math.radians(abs(sdeg))),
                          model=meta.get("still_source", "?")))
    if len(stills) < 3: return None
    # keyframes: frames with camera json + image + depth, 12 evenly spread
    cams = sorted(glob.glob(bundle+"/cameras/frame_*.json"))
    usable = [c for c in cams if os.path.exists(bundle+"/images/"+os.path.basename(c)[:-5]+".jpg")
              and os.path.exists(bundle+"/depth/"+os.path.basename(c)[:-5]+".png")]
    if len(usable) < 4: return None
    step = max(1, len(usable)//12)
    pts, grays = [], []
    for c in usable[::step][:12]:
        cj = json.load(open(c)); stem = os.path.basename(c)[:-5]
        T = np.eye(4, dtype=np.float32)
        for r in range(4):
            for col in range(4):
                v = cj.get(f"t_{r}{col}")
                if v is not None: T[r, col] = v
        img = pgm_gray(bundle+"/images/"+stem+".jpg", KFW, KFW*cj["height"]//cj["width"],
                       os.path.join(tmp, stem+".pgm"))
        dep = depth_le(bundle+"/depth/"+stem+".png").astype(np.float32)
        dh, dw = dep.shape
        rr, cc = np.mgrid[0:dh:4, 0:dw:4]
        mm = dep[rr, cc]
        ok = (mm > 300) & (mm < 8000)
        rr, cc, mm = rr[ok], cc[ok], mm[ok]
        z = mm/1000.0
        fx, fy, cx, cy, W, H = cj["fx"], cj["fy"], cj["cx"], cj["cy"], cj["width"], cj["height"]
        fullx = cc/dw*W; fully = rr/dh*H
        cam = np.stack([(fullx-cx)*z/fx, (cy-fully)*z/fy, -z, np.ones_like(z)], 1)
        world = cam @ T.T
        ih, iw = img.shape
        gy = np.clip((rr/dh*ih).astype(int), 0, ih-1); gx = np.clip((cc/dw*iw).astype(int), 0, iw-1)
        pts.append(world[:, :3]); grays.append(img[gy, gx])
    np.savez_compressed(out,
        stills=np.stack(stills), masks=np.stack(masks), gvecs=np.stack(gvecs),
        metas=json.dumps(metas), kf_counts=np.array([len(p) for p in pts]),
        pts=np.concatenate(pts), grays=np.concatenate(grays))
    return out

os.makedirs(CACHE, exist_ok=True)
bundles = sorted(glob.glob(os.path.expanduser("~/Downloads/staging_*")))
for b in bundles:
    try:
        r = prep(b)
        print(os.path.basename(b)[8:16], "→", "cached" if r else "SKIP (insufficient data)", flush=True)
    except Exception as e:
        print(os.path.basename(b)[8:16], "→ ERROR", type(e).__name__, str(e)[:80], flush=True)
