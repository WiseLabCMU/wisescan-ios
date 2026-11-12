"""LichtFeld --python-script hook: install the training crop box from BOX_JSON (box_masks.py output)
and verify it. At BOX_CHECK and BOX_CHECK+1 it snapshots the Gaussians; with --cropbox-lr-scale 0,
those outside the box must not change between the two steps while those inside do. The result goes
to BOX_CHECK_FILE (default: box_check.txt beside BOX_JSON). LichtFeld's embedded Python needs numpy
in ~/.lichtfeld/venv/lib/python3/site-packages.
"""
import json
import os

import numpy as np

import lichtfeld as lf

BOX_JSON = os.environ["BOX_JSON"]
CHECK_FILE = os.environ.get("BOX_CHECK_FILE", os.path.join(os.path.dirname(BOX_JSON), "box_check.txt"))
BOX = json.load(open(BOX_JSON))
CHECK = int(os.environ.get("BOX_CHECK", "1500"))
T = np.array(BOX["box_to_model"], np.float64)
LO, HI = np.array(BOX["min"]), np.array(BOX["max"])
state = {}


def report(msg):
    lf.log.info(f"[box] {msg}")
    with open(CHECK_FILE, "a") as fh:
        fh.write(msg + "\n")

def arr(t):
    return np.asarray(t.cpu().numpy() if hasattr(t, "cpu") else t, np.float64)


def model_arrays():
    m = lf.get_scene().training_model()
    X = arr(m.means_raw).reshape(-1, 3)
    return X, arr(m.sh0_raw).reshape(len(X), -1)


def inside(X):
    q = (X - T[:3, 3]) @ T[:3, :3]                 # model -> box local (T rotation is orthonormal)
    return np.all((q >= LO) & (q <= HI), axis=1)


@lf.on_training_start
def install_box(ctx=None):
    scene = lf.get_scene()
    node = scene.get_node(scene.training_model_node_name)
    cid = scene.get_or_create_cropbox_for_splat(node.id)
    data = scene.get_cropbox_data(cid)
    data.min = tuple(float(v) for v in LO)
    data.max = tuple(float(v) for v in HI)
    data.inverse = False
    data.enabled = True
    scene.set_cropbox_data(cid, data)
    scene.get_node_by_id(cid).set_local_transform(T.astype(np.float32))
    X, _ = model_arrays()
    back = scene.get_cropbox_data(cid)
    report(f"installed crop box on '{node.name}' (cropbox node {cid}): min {tuple(back.min)} max {tuple(back.max)}"
           f" enabled {back.enabled}; cropbox world {scene.get_node_by_id(cid).world_transform}")
    report(f"initial Gaussians {len(X):,}, inside the box by this script's test {inside(X).mean():.1%}")


@lf.on_post_step
def check(ctx=None):
    if isinstance(ctx, dict):
        it = next((int(ctx[k]) for k in ("iteration", "iter", "step") if k in ctx), lf.trainer_current_iteration())
    else:
        it = getattr(ctx, "iteration", None) or lf.trainer_current_iteration()
    if "first" not in state:
        state["first"] = True
        report(f"post-step hook live: first iteration seen {it}; ctx keys {sorted(ctx) if isinstance(ctx, dict) else type(ctx).__name__}")
    if it == CHECK and "a" not in state:
        state["a"] = model_arrays()
        state["it"] = it
    elif "a" in state and "done" not in state and it > state["it"]:
        Xa, Ca = state["a"]
        Xb, Cb = model_arrays()
        state["done"] = True
        if len(Xa) != len(Xb) or Ca is None:
            report(f"check skipped at {it}: Gaussian count changed {len(Xa)} -> {len(Xb)} or no sh0")
            return
        ins = inside(Xa)
        dc = np.abs(Cb - Ca).max(axis=1) > 0
        dx = np.abs(Xb - Xa).max(axis=1) > 0
        report(f"check {state['it']}->{it}: inside {ins.sum():,} / outside {(~ins).sum():,} Gaussians;"
               f" colour changed inside {dc[ins].mean():.1%}, outside {dc[~ins].mean() if (~ins).any() else float('nan'):.1%};"
               f" position changed inside {dx[ins].mean():.1%}, outside {dx[~ins].mean() if (~ins).any() else float('nan'):.1%}")
