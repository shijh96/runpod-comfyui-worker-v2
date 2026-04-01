# syntax=docker/dockerfile:1
#
# Single-stage Dockerfile: models + custom nodes + dependencies
#
# Build locally and push to Docker Hub:
#   docker build --platform linux/amd64 -t shijh96/infinitetalk-staging:v1 .
#   docker push shijh96/infinitetalk-staging:v1
#
FROM runpod/worker-comfyui:5.5.0-base

# Enable NVENC video encoding (requires video capability)
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    NVIDIA_VISIBLE_DEVICES=all

ENV COMFY_HOME=/comfyui \
    HF_HOME=/opt/cache/huggingface \
    TRANSFORMERS_CACHE=/opt/cache/huggingface \
    TORCH_HOME=/opt/cache/torch \
    HF_ENDPOINT=https://hf-mirror.com

RUN mkdir -p "${HF_HOME}" "${TORCH_HOME}" \
  && chown -R root:root "${HF_HOME}" "${TORCH_HOME}"

# ---------------------------------------------------------------------------
# Pre-download models (each in separate RUN for Docker layer caching)
# Uses hf-mirror.com for reliable downloads in China
# ---------------------------------------------------------------------------

# InfiniteTalk model (~4.9GB)
RUN comfy model download \
    --url https://hf-mirror.com/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors \
    --relative-path models/diffusion_models \
    --filename Wan2_1-InfiniTetalk-Single_fp16.safetensors

# Wan2.1 i2v 480p model (~7GB)
RUN comfy model download \
    --url https://hf-mirror.com/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors \
    --relative-path models/diffusion_models \
    --filename wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors

# VAE (~500MB)
RUN comfy model download \
    --url https://hf-mirror.com/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors \
    --relative-path models/vae \
    --filename wan_2.1_vae.safetensors

# Lightx2v LoRA (~500MB)
RUN comfy model download \
    --url https://hf-mirror.com/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors \
    --relative-path models/loras \
    --filename lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors

# CLIP Vision (~1.2GB)
RUN comfy model download \
    --url https://hf-mirror.com/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors \
    --relative-path models/clip_vision \
    --filename clip_vision_h.safetensors

# umt5-xxl text encoder (~4.5GB)
RUN comfy model download \
    --url https://hf-mirror.com/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors \
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
    --url https://hf-mirror.com/set-soft/audio_separation/resolve/main/Demucs/htdemucs_ft.safetensors \
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
# Install custom nodes (only what the workflow needs)
#
# Kept:
#   - ComfyUI-WanVideoWrapper:    all InfiniteTalk/MultiTalk/Wan nodes
#   - comfyui-videohelpersuite:    VHS_LoadAudio, AudioCrop, VHS_VideoCombine
#   - seedvr2_videoupscaler:       FlashVSRInitPipe, FlashVSRNodeAdv
#   - comfyui_layerstyle:          LayerUtility: ImageScaleByAspectRatio V2
#   - set-soft/AudioSeparation:    AudioSeparateDemucs
#
# Removed (unused by workflow):
#   - comfyui-various              (JWInteger — not in workflow)
#   - ComfyUI_Comfyroll_CustomNodes (CR Prompt Text — not in workflow)
#   - ComfyUI-ZMG-Nodes           (URL loaders — replaced by LoadImage + VHS_LoadAudio)
# ---------------------------------------------------------------------------
RUN comfy node install ComfyUI-WanVideoWrapper && \
    comfy node install comfyui-videohelpersuite && \
    comfy node install seedvr2_videoupscaler && \
    comfy node install comfyui_layerstyle

# set-soft/AudioSeparation node (AudioSeparateDemucs) with htdemucs_ft v4 support
RUN git clone https://github.com/set-soft/AudioSeparation.git /comfyui/custom_nodes/AudioSeparation && \
    pip install 'seconohe>=1.0.2'

# ---------------------------------------------------------------------------
# Install C/C++ compiler and Python headers for torch.compile (inductor backend)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y gcc g++ python3-dev && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install SageAttention, Triton, and runtime dependencies
# ---------------------------------------------------------------------------
RUN pip install sageattention triton soundfile brotli
