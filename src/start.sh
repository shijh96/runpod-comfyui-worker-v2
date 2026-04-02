#!/bin/bash
set -e

echo "[start.sh] Starting ComfyUI in background..."
python3 /comfyui/main.py --disable-auto-launch --disable-metadata --listen 0.0.0.0 --port 8188 &

echo "[start.sh] Starting RunPod handler..."
python3 -u /rp_handler.py
