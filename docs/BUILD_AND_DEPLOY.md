# Staging 镜像 Build & Deploy 流程

## 概述

Staging 镜像在**远程 Linux 机器**上 build（模型从本地 ComfyUI 目录 COPY），然后通过 SSH pipe stream 到本机 Docker，最后从本机 push 到 Docker Hub。

RunPod staging endpoint 配置为 `shijh96/infinitetalk-staging:latest`，push 后新 worker 会自动拉取最新镜像。

## 前置条件

- 远程机器：`jiahe@100.84.91.125`，已安装 Docker，ComfyUI 模型在 `/home/jiahe/workspace/ComfyUI/models/`
- 本机：Docker Desktop 运行中，已登录 Docker Hub（`docker login --username shijh96`）
- RunPod endpoint 已配置为 `shijh96/infinitetalk-staging:latest`

## 完整流程

### Step 1: 同步文件到远程机器

```bash
# 确保远程目录存在
ssh jiahe@100.84.91.125 "mkdir -p /tmp/infinitetalk-staging/src"

# 传 Dockerfile 和 handler
scp infinitetalk-flashvsr-staging/Dockerfile jiahe@100.84.91.125:/tmp/infinitetalk-staging/
scp infinitetalk-flashvsr-staging/src/rp_handler.py jiahe@100.84.91.125:/tmp/infinitetalk-staging/src/
scp infinitetalk-flashvsr-staging/src/start.sh jiahe@100.84.91.125:/tmp/infinitetalk-staging/src/
```

### Step 2: 准备模型目录（首次或模型有变动时）

在远程机器上把 ComfyUI 的模型文件复制/链接到 build 目录：

```bash
ssh jiahe@100.84.91.125 "
cd /tmp/infinitetalk-staging && \
mkdir -p models/diffusion_models models/vae models/loras models/clip_vision \
         models/text_encoders models/transformers/TencentGameMate models/audio/Demucs && \
cp /home/jiahe/workspace/ComfyUI/models/diffusion_models/Wan2_1-InfiniTetalk-Single_fp16.safetensors models/diffusion_models/ && \
cp /home/jiahe/workspace/ComfyUI/models/diffusion_models/wan2.1_i2v_480p_14B_fp8_e4m3fn.safetensors models/diffusion_models/ && \
cp /home/jiahe/workspace/ComfyUI/models/vae/wan_2.1_vae.safetensors models/vae/ && \
cp /home/jiahe/workspace/ComfyUI/models/loras/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors models/loras/ && \
cp /home/jiahe/workspace/ComfyUI/models/clip_vision/clip_vision_h.safetensors models/clip_vision/ && \
cp /home/jiahe/workspace/ComfyUI/models/text_encoders/umt5-xxl-enc-bf16.safetensors models/text_encoders/ && \
cp -r /home/jiahe/workspace/ComfyUI/models/transformers/TencentGameMate/chinese-wav2vec2-base models/transformers/TencentGameMate/ && \
cp /home/jiahe/workspace/ComfyUI/models/audio/Demucs/htdemucs_ft.safetensors models/audio/Demucs/ && \
cp -r /home/jiahe/workspace/ComfyUI/models/FlashVSR-v1.1 models/
"
```

> 注意：模型文件约 35GB，首次复制需要几分钟。如果模型没变，跳过此步。

### Step 3: 远程 Build

```bash
ssh jiahe@100.84.91.125 "cd /tmp/infinitetalk-staging && DOCKER_BUILDKIT=0 docker build -t shijh96/infinitetalk-staging:v5 ."
```

> **必须用 `DOCKER_BUILDKIT=0`**（legacy builder），BuildKit 在大镜像 build 时容易卡死。
> 远程是 x86_64 原生，不需要 `--platform` 参数。
> 如果只改了代码/handler（模型没变），模型 COPY 层会被 Docker 缓存跳过，build 很快。

### Step 4: Stream 镜像到本机

```bash
ssh jiahe@100.84.91.125 "docker save shijh96/infinitetalk-staging:v5" | docker load
```

> 通过 SSH pipe 直接 stream，不落盘，不占远程/本机磁盘（但传输过程中本机 Docker 磁盘会增长约 50-60GB）。
> 传输时间取决于网络带宽，通常 20-40 分钟。

### Step 5: Tag + Push 到 Docker Hub

```bash
docker tag shijh96/infinitetalk-staging:v5 shijh96/infinitetalk-staging:latest
docker push shijh96/infinitetalk-staging:v5
docker push shijh96/infinitetalk-staging:latest
```

### Step 6: 验证

发一个测试请求到 RunPod staging endpoint。旧 worker 会在 5 秒 idle 后自动回收，新请求会拉最新镜像。

如需强制刷新 worker：RunPod Console → endpoint → Edit → Max workers 设 0 → Save → 改回 2 → Save。

## 只改代码/Handler 时的快速流程

如果只修改了 `rp_handler.py`、`start.sh` 或 Dockerfile 中的非模型部分：

```bash
# 1. 传文件
scp infinitetalk-flashvsr-staging/Dockerfile jiahe@100.84.91.125:/tmp/infinitetalk-staging/
scp infinitetalk-flashvsr-staging/src/rp_handler.py jiahe@100.84.91.125:/tmp/infinitetalk-staging/src/
scp infinitetalk-flashvsr-staging/src/start.sh jiahe@100.84.91.125:/tmp/infinitetalk-staging/src/

# 2. Build（模型层 cached，很快）
ssh jiahe@100.84.91.125 "cd /tmp/infinitetalk-staging && DOCKER_BUILDKIT=0 docker build -t shijh96/infinitetalk-staging:latest ."

# 3. Stream + Load + Push
ssh jiahe@100.84.91.125 "docker save shijh96/infinitetalk-staging:latest" | docker load
docker push shijh96/infinitetalk-staging:latest
```

## 模型清单

| 模型 | 路径 | 大小 | 用途 |
|------|------|------|------|
| Wan2_1-InfiniTetalk-Single_fp16 | diffusion_models/ | 4.8GB | InfiniteTalk lipsync |
| wan2.1_i2v_480p_14B_fp8_e4m3fn | diffusion_models/ | 16GB | Wan2.1 视频生成 |
| wan_2.1_vae | vae/ | 243MB | VAE 解码 |
| lightx2v LoRA | loras/ | 704MB | 步骤蒸馏加速 |
| clip_vision_h | clip_vision/ | 1.2GB | CLIP 视觉编码 |
| umt5-xxl-enc-bf16 | text_encoders/ | 11GB | 文本编码 |
| chinese-wav2vec2-base | transformers/TencentGameMate/ | ~400MB | 音频处理 |
| htdemucs_ft | audio/Demucs/ | 321MB | 人声分离 |
| FlashVSR-v1.1 | FlashVSR-v1.1/ | ~1GB | 3x 超分辨率 |

## 节点包清单

| 包名 | 版本 | 提供的关键节点 |
|------|------|--------------|
| ComfyUI-WanVideoWrapper | 1.4.7 | InfiniteTalk/MultiTalk 全部节点 |
| comfyui-videohelpersuite | 1.7.9 | VHS_LoadAudio, VHS_VideoCombine |
| seedvr2_videoupscaler | 2.5.22 | FlashVSRInitPipe, FlashVSRNodeAdv |
| comfyui_layerstyle | - | LayerUtility: ImageScaleByAspectRatio V2 |
| audio-separation-nodes-comfyui | 1.4.1 | AudioCrop |
| set-soft/AudioSeparation | - | AudioSeparateDemucs |

## 常见问题

### Build 时节点安装卡住
`comfyui_layerstyle` 依赖很多（opencv-contrib-python 等），安装可能需要 30-60 分钟。用 `docker exec <container_id> ps aux` 确认容器内进程是否在工作。

### BuildKit 卡死
使用 `DOCKER_BUILDKIT=0` 强制用 legacy builder。

### 本机 Docker Desktop 不稳定
如果 Docker Desktop 崩溃/卡死：退出 → 重开。如果打不开：重装 Docker Desktop。

### 清理本机 Docker 磁盘
```bash
# 查看占用
du -sh ~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw

# 清理无用镜像和缓存
docker system prune -a
```
