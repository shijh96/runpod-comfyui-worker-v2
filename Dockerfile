#
# RunPod ComfyUI worker for InfiniteTalk + FlashVSR (Staging)
#
# Pushed to GitHub, RunPod auto-builds on push.
# Base image is on Docker Hub (fast pull on RunPod builder).
# Models downloaded from HuggingFace during build.
#
FROM runpod/worker-comfyui:5.5.0-base

# Enable NVENC video encoding (requires video capability)
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    NVIDIA_VISIBLE_DEVICES=all

ENV COMFY_HOME=/comfyui \
    HF_HOME=/opt/cache/huggingface \
    TRANSFORMERS_CACHE=/opt/cache/huggingface \
    TORCH_HOME=/opt/cache/torch

RUN mkdir -p "${HF_HOME}" "${TORCH_HOME}" \
  && chown -R root:root "${HF_HOME}" "${TORCH_HOME}"

# ---------------------------------------------------------------------------
# Update ComfyUI core to exact version matching local (0.17.0, commit f6b869d7)
# Base image has 0.3.64; we need 0.17.0 for consistent generation quality.
# ---------------------------------------------------------------------------
RUN cd /comfyui && \
    git remote set-url origin https://github.com/comfyanonymous/ComfyUI.git && \
    git fetch origin && \
    git checkout f6b869d7 && \
    pip install -r requirements.txt

# ---------------------------------------------------------------------------
# Pre-download models (each in separate RUN for Docker layer caching)
# ---------------------------------------------------------------------------

# InfiniteTalk model (~4.9GB)
RUN comfy model download \
    --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors \
    --relative-path models/diffusion_models \
    --filename Wan2_1-InfiniTetalk-Single_fp16.safetensors

# Wan2.1 i2v 480p model (~7GB)
RUN comfy model download \
    --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors \
    --relative-path models/diffusion_models \
    --filename wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors

# VAE (~500MB)
RUN comfy model download \
    --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors \
    --relative-path models/vae \
    --filename wan_2.1_vae.safetensors

# Lightx2v LoRA (~500MB)
RUN comfy model download \
    --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
    --relative-path models/loras \
    --filename lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors

# CLIP Vision (~1.2GB)
RUN comfy model download \
    --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors \
    --relative-path models/clip_vision \
    --filename clip_vision_h.safetensors

# umt5-xxl text encoder (~4.5GB)
RUN comfy model download \
    --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors \
    --relative-path models/text_encoders \
    --filename umt5-xxl-enc-bf16.safetensors

# Wav2Vec2 model for lip-sync audio processing
RUN python - <<'PY'
import pathlib
from huggingface_hub import snapshot_download
target_dir = pathlib.Path("/comfyui/models/transformers/TencentGameMate/chinese-wav2vec2-base")
target_dir.mkdir(parents=True, exist_ok=True)
snapshot_download(
    repo_id="TencentGameMate/chinese-wav2vec2-base",
    revision="main",
    local_dir=target_dir,
    local_dir_use_symlinks=False,
)
PY

# Demucs v4 (htdemucs_ft) for vocal separation
RUN comfy model download \
    --url https://huggingface.co/set-soft/audio_separation/resolve/main/Demucs/htdemucs_ft.safetensors \
    --relative-path models/audio/Demucs \
    --filename htdemucs_ft.safetensors

# FlashVSR v1.1 models for 3x upscaling
RUN python - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id="JunhaoZhuang/FlashVSR-v1.1",
    local_dir="/comfyui/models/FlashVSR-v1.1",
    local_dir_use_symlinks=False,
)
print("FlashVSR-v1.1 downloaded to /comfyui/models/FlashVSR-v1.1/")
PY

# ---------------------------------------------------------------------------
# Enable offline mode AFTER all downloads are complete
# ---------------------------------------------------------------------------
ENV HF_HUB_OFFLINE=1 \
    TRANSFORMERS_OFFLINE=1

# ---------------------------------------------------------------------------
# Install custom nodes — pinned to exact versions matching local machine
# Source: jiahe@100.84.91.125:/home/jiahe/workspace/ComfyUI/custom_nodes/
# ---------------------------------------------------------------------------

# WanVideoWrapper v1.4.7 (commit e091c4a) — all InfiniteTalk/MultiTalk/Wan nodes
RUN git clone https://github.com/kijai/ComfyUI-WanVideoWrapper.git /comfyui/custom_nodes/ComfyUI-WanVideoWrapper && \
    cd /comfyui/custom_nodes/ComfyUI-WanVideoWrapper && git checkout e091c4a && \
    pip install -r requirements.txt

# comfyui-videohelpersuite — VHS_LoadAudio, VHS_VideoCombine (registry, local is v1.6.1)
RUN comfy node install comfyui-videohelpersuite

# comfyui_layerstyle (commit d94bef1) — LayerUtility: ImageScaleByAspectRatio V2
RUN git clone https://github.com/chflame163/ComfyUI_LayerStyle.git /comfyui/custom_nodes/comfyui_layerstyle && \
    cd /comfyui/custom_nodes/comfyui_layerstyle && git checkout d94bef1 && \
    pip install -r requirements.txt

# audio-separation-nodes-comfyui — AudioCrop (registry, local is v1.4.0)
RUN comfy node install audio-separation-nodes-comfyui

# FlashVSR Ultra Fast (commit 4820b3f) — FlashVSRInitPipe, FlashVSRNodeAdv
RUN rm -rf /comfyui/custom_nodes/ComfyUI-FlashVSR_Ultra_Fast && \
    git clone https://github.com/lihaoyun6/ComfyUI-FlashVSR_Ultra_Fast.git /comfyui/custom_nodes/ComfyUI-FlashVSR_Ultra_Fast && \
    cd /comfyui/custom_nodes/ComfyUI-FlashVSR_Ultra_Fast && git checkout 4820b3f && \
    pip install -r requirements.txt

# set-soft/AudioSeparation v1.1.3 (commit 621bd27) — AudioSeparateDemucs
RUN git clone https://github.com/set-soft/AudioSeparation.git /comfyui/custom_nodes/AudioSeparation && \
    cd /comfyui/custom_nodes/AudioSeparation && git checkout 621bd27 && \
    pip install 'seconohe>=1.0.2'

# ---------------------------------------------------------------------------
# Install C/C++ compiler and Python headers for torch.compile (inductor backend)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y gcc g++ python3-dev && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install SageAttention, Triton, and runtime dependencies
# ---------------------------------------------------------------------------
RUN pip install sageattention triton soundfile boto3 runpod

# ---------------------------------------------------------------------------
# Copy custom handler and startup script
# ---------------------------------------------------------------------------
COPY src/rp_handler.py /rp_handler.py
COPY src/start.sh /start.sh
RUN chmod +x /start.sh

# ---------------------------------------------------------------------------
# Start ComfyUI + Handler via start.sh
# ---------------------------------------------------------------------------
CMD ["/start.sh"]
