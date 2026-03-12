# syntax=docker/dockerfile:1
#
# Custom worker image for RunPod / ComfyUI with pre-baked workflow models
# and cached torchaudio assets to minimise cold-start latency.
FROM runpod/worker-comfyui:5.5.0-base

ENV COMFY_HOME=/comfyui \
    HF_HOME=/opt/cache/huggingface \
    TRANSFORMERS_CACHE=/opt/cache/huggingface \
    TORCH_HOME=/opt/cache/torch

RUN mkdir -p "${HF_HOME}" "${TORCH_HOME}" \
  && chown -R root:root "${HF_HOME}" "${TORCH_HOME}"

# ---------------------------------------------------------------------------
# Pre-download diffusion models, LoRAs and encoders referenced by the workflow.
# ---------------------------------------------------------------------------
RUN comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors --relative-path models/diffusion_models --filename Wan2_1-InfiniTetalk-Single_fp16.safetensors && \
    comfy model download --url https://huggingface.co/852wa/ani_wan2.1/resolve/main/aniWan2114BFp8E4m3fn_i2v480pNew.safetensors --relative-path models/diffusion_models --filename aniWan2114BFp8E4m3fn_i2v480pNew.safetensors && \
    comfy model download --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors --relative-path models/vae --filename wan_2.1_vae.safetensors && \
    comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors --relative-path models/loras --filename lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors && \
    comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/rCM/Wan_2_1_T2V_14B_480p_rCM_lora_average_rank_83_bf16.safetensors --relative-path models/loras --filename Wan_2_1_T2V_14B_480p_rCM_lora_average_rank_83_bf16.safetensors && \
    comfy model download --url https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors --relative-path models/clip_vision --filename clip_vision_h.safetensors && \
    comfy model download --url https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors --relative-path models/text_encoders --filename umt5-xxl-enc-bf16.safetensors

# ---------------------------------------------------------------------------
# Step 2: snapshot the TencentGameMate wav2vec2 model so the worker never
# downloads it at runtime. We keep it inside the Comfy models tree to match
# what the workflow expects.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Step 3: Download htdemucs_ft (Demucs v4, SDR 9.2) for set-soft/AudioSeparation node.
# Replaces hdemucs v3 (SDR 7.7) for improved vocal separation quality.
# ---------------------------------------------------------------------------
RUN comfy model download \
    --url https://huggingface.co/set-soft/audio_separation/resolve/main/Demucs/htdemucs_ft.safetensors \
    --relative-path models/audio/Demucs \
    --filename htdemucs_ft.safetensors

# ---------------------------------------------------------------------------
# Install custom nodes & Python requirements.
# ---------------------------------------------------------------------------
RUN comfy node install ComfyUI-WanVideoWrapper && \
    comfy node install comfyui-videohelpersuite && \
    comfy node install comfyui-various && \
    comfy node install seedvr2_videoupscaler && \
    comfy node install comfyui_layerstyle && \
    comfy node install ComfyUI_Comfyroll_CustomNodes

# set-soft/AudioSeparation node (AudioSeparateDemucs) with htdemucs_ft v4 support
RUN git clone https://github.com/set-soft/AudioSeparation.git /comfyui/custom_nodes/AudioSeparation && \
    pip install 'seconohe>=1.0.2'

# ZMG URL nodes (LoadImageFromUrl / LoadAudioFromUrl)
RUN rm -rf /comfyui/custom_nodes/ComfyUI-ZMG-Nodes && \
    git clone https://github.com/fq393/ComfyUI-ZMG-Nodes.git /comfyui/custom_nodes/ComfyUI-ZMG-Nodes && \
    pip install -r /comfyui/custom_nodes/ComfyUI-ZMG-Nodes/requirements.txt

# S3 helper node for uploads
RUN rm -rf /comfyui/custom_nodes/ComfyS3 && \
    git clone https://github.com/TemryL/ComfyS3.git /comfyui/custom_nodes/ComfyS3 && \
    pip install -r /comfyui/custom_nodes/ComfyS3/requirements.txt

# ---------------------------------------------------------------------------
# Install C/C++ compiler and Python headers for torch.compile (inductor backend)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y gcc g++ python3-dev && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install SageAttention for optimized attention computation
# ---------------------------------------------------------------------------
RUN pip install sageattention triton
