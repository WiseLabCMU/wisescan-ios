#!/usr/bin/env python3
"""#54: derive ack->shutter latency (lambda) per (camera model, shutter path).

lambda_ms = (EXIF shutter epoch - camera_clock_offset_ms) - (captured_at_epoch_ms + shutter_ack_ms)

- EXIF DateTimeOriginal (0x9003) is zone-less and 1 s granular; SubSecTimeOriginal
  (0x9291) refines it when the camera writes it. The sidecar's offset was measured
  zone-correct (OSC dateTimeZone carries the zone), so the EXIF zone is solved per
  bundle: all stills in a bundle share one zone, and the true lambda is sub-second,
  so the whole-hour shift that minimizes the bundle's median |lambda| is the zone.
- Quantization: with 1 s EXIF resolution, a single lambda is +/-500 ms; the per-group
  median over many stills is what converges. Report n, median, IQR, and offset unc.
"""
import json, glob, os, struct, sys, datetime, statistics

def exif_tags(path):
    """Return (DateTimeOriginal, SubSecTimeOriginal) parsing JPEG APP1 by hand."""
    with open(path,'rb') as f: data=f.read(256*1024)
    i=2
    while i+4 < len(data):
        if data[i]!=0xFF: break
        marker=data[i+1]; size=struct.unpack('>H',data[i+2:i+4])[0]
        if marker==0xE1 and data[i+4:i+10]==b'Exif\x00\x00':
            t=data[i+10:i+2+size]; return parse_tiff(t)
        if marker==0xDA: break
        i+=2+size
    return None,None

def parse_tiff(t):
    if len(t)<8: return None,None
    le = t[:2]==b'II'; u16=lambda o: struct.unpack('<H' if le else '>H',t[o:o+2])[0]
    u32=lambda o: struct.unpack('<I' if le else '>I',t[o:o+4])[0]
    def read_ifd(off, want):
        out={}
        if off+2>len(t): return out
        n=u16(off)
        for k in range(n):
            e=off+2+k*12
            tag=u16(e); typ=u16(e+2); cnt=u32(e+4)
            if tag in want or tag==0x8769:
                size=cnt*(1 if typ in (1,2,7) else 2 if typ==3 else 4 if typ in (4,9) else 8)
                voff=u32(e+8) if size>4 else e+8
                raw=t[voff:voff+size]
                if tag==0x8769: out['exif_ifd']=u32(e+8)
                elif typ==2: out[tag]=raw.split(b'\0')[0].decode('ascii','ignore')
        return out
    ifd0=read_ifd(u32(4), set())
    tags={}
    if 'exif_ifd' in ifd0:
        tags=read_ifd(ifd0['exif_ifd'], {0x9003,0x9291,0x9011})
    return tags.get(0x9003), tags.get(0x9291)

rows=[]
for d in sorted(glob.glob(os.path.expanduser('~/Downloads/staging_*/'))):
    sides=sorted(glob.glob(d+'equirect_stills/still_*.json'))
    per_bundle=[]
    for f in sides:
        j=json.load(open(f))
        off=j.get('camera_clock_offset_ms')
        if off is None or j.get('shutter_ack_ms') is None or j.get('captured_at_epoch_ms') is None: continue
        jpg=f[:-5]+'.JPG'
        if not os.path.exists(jpg): continue
        dto,sub=exif_tags(jpg)
        if not dto: continue
        try: base=datetime.datetime.strptime(dto,'%Y:%m:%d %H:%M:%S')
        except ValueError: continue
        frac=float('0.'+sub.strip()) if sub and sub.strip().isdigit() else 0.0
        naive_ms=(base.replace(tzinfo=datetime.timezone.utc).timestamp()+frac)*1000
        per_bundle.append((naive_ms, off, j['captured_at_epoch_ms']+j['shutter_ack_ms'],
                           j.get('camera_model','?'), j.get('shutter_path','?'), j.get('camera_clock_offset_unc_ms'),
                           sub is not None, os.path.basename(f)))
    if not per_bundle: continue
    # solve the bundle's zone: whole-hour shift minimizing median |lambda|
    best=None
    for h in range(-14,15):
        lams=[(nm - h*3600_000 - off) - anchor for nm,off,anchor,*_ in per_bundle]
        med=statistics.median(abs(l) for l in lams)
        if best is None or med<best[1]: best=(h,med)
    h=best[0]
    for nm,off,anchor,model,path,unc,has_sub,name in per_bundle:
        lam=(nm - h*3600_000 - off) - anchor
        rows.append(dict(bundle=os.path.basename(d.rstrip('/'))[8:16], still=name, model=model,
                         path=path, lambda_ms=round(lam), offset_unc_ms=unc, subsec=has_sub, zone_h=h))

groups={}
for r in rows: groups.setdefault((r['model'],r['path']),[]).append(r['lambda_ms'])
print(f"{'model':<20}{'path':<6}{'n':<4}{'median':<9}{'IQR':<14}values")
for (m,p),vals in sorted(groups.items()):
    vals.sort()
    q1,q3=vals[len(vals)//4], vals[3*len(vals)//4]
    print(f"{m:<20}{p:<6}{len(vals):<4}{statistics.median(vals):<9.0f}{f'{q1}..{q3}':<14}{vals}")
print(f"\nzones solved: {sorted(set(r['zone_h'] for r in rows))};  subsec present: {sum(1 for r in rows if r['subsec'])}/{len(rows)}")
json.dump(rows, open(os.path.join(os.path.dirname(__file__) or '.', 'latency-results.json'),'w'), indent=1)
