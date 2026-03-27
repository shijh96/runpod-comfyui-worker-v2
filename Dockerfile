# syntax=docker/dockerfile:1
#
# Layer 2: Application image (custom nodes + dependencies)
# Fast rebuild (~2-3 min) — no model downloads.
# Requires models base image to be built first:
#   docker build -f Dockerfile.models -t ghcr.io/shijh96/infinitetalk-models:staging .
#   docker push ghcr.io/shijh96/infinitetalk-models:staging
#
FROM ghcr.io/shijh96/infinitetalk-models:staging

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

# ComfyS3: use the base image's pre-configured version.
# Do NOT re-clone — the base image's ComfyS3 already reads RunPod's BUCKET_* env vars.

# ---------------------------------------------------------------------------
# Install C/C++ compiler and Python headers for torch.compile (inductor backend)
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y gcc g++ python3-dev && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install SageAttention for optimized attention computation
# ---------------------------------------------------------------------------
RUN pip install sageattention triton soundfile
