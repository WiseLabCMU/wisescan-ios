#!/bin/bash
# One-shot AR Capture -> box-cropped Gaussian splat.
#
#   tools/ar-capture-splat/run.sh INPUT_DIR [OUTPUT_DIR] [--full-res] [--pairs rule|topkN] [--iter N]
#
# INPUT_DIR is an unzipped AR Capture dump (photos/, photo_depth/, photo_confidence/, photos.csv,
# manifest.json, optional focus_region.json). OUTPUT_DIR defaults to INPUT_DIR + "_splat".
# Both must sit under WISELAB_ROOT, which the LichtFeld container mounts at /workspace.
#
# Stages (timed into OUTPUT_DIR/timings.txt):
#   1 ingest     stills, ARKit pose priors, focus box                    scan4d-splat-sfm image, CPU
#   2 sfm        SIFT + ARKit pairs + pose_prior_mapper                  scan4d-splat-sfm image, GPU
#     normals    MoGe-2 normals, in parallel with sfm                    LichtFeld container, GPU
#   3 box_masks  per-still masks, depth, prior blanking, cropped seed    scan4d-splat-sfm image, CPU
#   4 train      LichtFeld box-first training, half resolution default   LichtFeld container, GPU
#   5 finalize   hard crop to the box, SOG, summary.json                 both
#
# Needs: Docker with GPU access; the image built from this folder's Dockerfile; the LichtFeld Studio
# compose container running (docker/docker-compose.yml in the LichtFeld repo), with its build at
# LFS_BIN. LFS_HOME holds the MoGe weights and the numpy the crop-box hook needs; both are fetched on
# first use if missing.
set -euo pipefail
export MSYS_NO_PATHCONV=1

WISELAB_ROOT=${WISELAB_ROOT:-/d/Workspace/WiseLab}           # host path, as this shell sees it
WISELAB_MOUNT=${WISELAB_MOUNT:-D:/Workspace/WiseLab}         # the same folder, as `docker run -v` takes it
SFM_IMAGE=${SFM_IMAGE:-scan4d-splat-sfm}
LFS_CONTAINER=${LFS_CONTAINER:-lichtfeld-studio}
LFS_BIN=${LFS_BIN:-/home/wsl/projects/LichtFeld-Studio/build/LichtFeld-Studio}
LFS_HOME=${LFS_HOME:-/workspace/4dscans/.lfs_home}           # container path

usage() { sed -n '2,8p' "$0"; exit 1; }
[ $# -ge 1 ] || usage
IN=$(cd "$1" && pwd); shift
OUT=""
RES="-r 2"; PAIRS="rule"; ITER=30000
while [ $# -gt 0 ]; do
  case $1 in
    --full-res) RES="-r 1"; shift ;;
    --pairs) PAIRS=$2; shift 2 ;;
    --iter) ITER=$2; shift 2 ;;
    -h|--help) usage ;;
    *) [ -z "$OUT" ] && OUT=$1 && shift || usage ;;
  esac
done
OUT=${OUT:-${IN}_splat}
mkdir -p "$OUT/work"
OUT=$(cd "$OUT" && pwd)
for p in "$IN" "$OUT"; do
  case $p in "$WISELAB_ROOT"/*) ;; *) echo "error: $p is not under WISELAB_ROOT=$WISELAB_ROOT" >&2; exit 1 ;; esac
done
rel() { echo "${1#$WISELAB_ROOT/}"; }
IN_S=/w/$(rel "$IN"); OUT_S=/w/$(rel "$OUT")                    # paths in the SfM container
OUT_L=/workspace/$(rel "$OUT")                                  # paths in the LichtFeld container
[ -f "$IN/manifest.json" ] && [ -f "$IN/photos.csv" ] || { echo "error: $IN is not an AR Capture dump" >&2; exit 1; }
docker image inspect "$SFM_IMAGE" > /dev/null 2>&1 || { echo "error: build the image first: docker build -t $SFM_IMAGE $(dirname "$0")" >&2; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$LFS_CONTAINER" 2>/dev/null)" = true ] || { echo "error: container $LFS_CONTAINER is not running" >&2; exit 1; }

SFM="docker run --rm --gpus all -v $WISELAB_MOUNT:/w $SFM_IMAGE python"
LFS="docker exec -e HOME=$LFS_HOME $LFS_CONTAINER"
T=$OUT/timings.txt
: > "$T"
t_all=$(date +%s)
step() { local name=$1; shift; local t0; t0=$(date +%s); echo "[$(date -u +%H:%M:%S)] $name"; "$@"; echo "$name $(( $(date +%s) - t0 )) s" >> "$T"; }

# The crop-box hook needs numpy in LichtFeld's embedded Python.
$LFS sh -c "test -d $LFS_HOME/.lichtfeld/venv/lib/python3/site-packages/numpy || pip3 install --quiet --target $LFS_HOME/.lichtfeld/venv/lib/python3/site-packages 'numpy<2.3'"

step ingest $SFM ingest.py "$IN_S" "$OUT_S"
cp "$(dirname "$0")/box_hook.py" "$OUT/work/box_hook.py"

normals() { $LFS sh -c "$LFS_BIN preprocess $OUT_L/dataset --mode normals > $OUT_L/work/normals.log 2>&1"; }
sfm() { $SFM sfm.py "$OUT_S" --pairs "$PAIRS" | tail -1; }
t0=$(date +%s)
echo "[$(date -u +%H:%M:%S)] sfm + normals (parallel)"
normals & npid=$!
sfm
wait $npid
echo "sfm+normals $(( $(date +%s) - t0 )) s" >> "$T"

step box_masks $SFM box_masks.py "$IN_S" "$OUT_S"

train() {
  rm -rf "$OUT/train"; mkdir -p "$OUT/train"
  $LFS sh -c "BOX_JSON=$OUT_L/work/box.json BOX_CHECK=1500 $LFS_BIN --headless --use-depth-loss --depth-loss-mode ssi-depth --use-normal-loss --max-width 0 $RES --iter=$ITER --test-every 8 --eval --eval-steps $ITER --mask-mode ignore --cropbox-lr-scale 0 --cropbox-loss-weight 0 --python-script $OUT_L/work/box_hook.py -d $OUT_L/dataset -o $OUT_L/train > $OUT_L/train/train.log 2>&1"
}
step train train

finalize() {
  $LFS sh -c "$LFS_BIN convert $OUT_L/train/project.licht $OUT_L/train/full.ply -f ply > $OUT_L/train/convert.log 2>&1"
  $SFM finalize.py "$OUT_S" train | tail -1
  $LFS sh -c "$LFS_BIN convert $OUT_L/train/splat.ply $OUT_L/train/splat.sog -f sog >> $OUT_L/train/convert.log 2>&1"
  rm -f "$OUT/train/full.ply"
}
step finalize finalize
echo "total $(( $(date +%s) - t_all )) s" >> "$T"
echo
cat "$T"
echo "splat: $OUT/train/splat.sog (cropped to the box); summary: $OUT/train/summary.json; mask check: $OUT/work/masks_preview.jpg"
