# SfM and box stages of the AR Capture -> splat pipeline (ingest, sfm, box_masks, finalize).
#
# Base: the local nerfstudio:blackwell image, which carries COLMAP 3.11 built for CUDA 12.8 (so it
# runs on Blackwell GPUs such as the RTX 5080) plus numpy, scipy, Pillow and OpenCV. Training runs in
# the separate LichtFeld Studio container; run.sh drives both.
#
#   docker build -t scan4d-splat-sfm tools/ar-capture-splat
FROM nerfstudio:blackwell
COPY ingest.py sfm.py box_masks.py finalize.py box_hook.py /opt/ar-capture-splat/
WORKDIR /opt/ar-capture-splat
ENV PYTHONUNBUFFERED=1
