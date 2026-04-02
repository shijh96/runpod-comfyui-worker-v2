#!/usr/bin/env python3
"""
Custom RunPod Handler for InfiniteTalk + FlashVSR Workflow

Responsibilities:
1. Download image/audio from R2 to /comfyui/input/
2. Execute the workflow (already configured with local nodes)
3. Upload raw FlashVSR output video from /comfyui/output/ to R2
4. Cleanup temporary files

The workflow is passed from the API with local nodes already configured:
- LoadImage (210) - loads from /comfyui/input/
- VHS_LoadAudio (206) - loads from /comfyui/input/
- VHS_VideoCombine (131) - raw FlashVSR output (~2496px longest side)

Output:
- Raw FlashVSR: {prefix}_00001-audio.mp4 (~2496px, for Modal FFmpeg post-processing)

Post-processing (done in Modal worker via FFmpeg):
- 720p preview: scale + crop to target aspect ratio
- 1440p HD: crop to target aspect ratio
"""

import os
import time
import uuid
import requests
import runpod
import boto3
from botocore.config import Config

# ============================================================================
# Configuration
# ============================================================================

COMFYUI_API_URL = "http://127.0.0.1:8188"
COMFYUI_INPUT_DIR = "/comfyui/input"
COMFYUI_OUTPUT_DIR = "/comfyui/output"

# R2/S3 Configuration (from environment variables)
R2_ENDPOINT = os.environ.get("BUCKET_ENDPOINT_URL")
R2_ACCESS_KEY = os.environ.get("BUCKET_ACCESS_KEY_ID")
R2_SECRET_KEY = os.environ.get("BUCKET_SECRET_ACCESS_KEY")
R2_BUCKET_NAME = os.environ.get("BUCKET_NAME", "vibemv")
R2_PUBLIC_URL = os.environ.get("BUCKET_PUBLIC_URL")  # Public access URL prefix

# ============================================================================
# Helper Functions
# ============================================================================


def get_s3_client():
    """Create boto3 S3 client for R2"""
    return boto3.client(
        's3',
        endpoint_url=R2_ENDPOINT,
        aws_access_key_id=R2_ACCESS_KEY,
        aws_secret_access_key=R2_SECRET_KEY,
        config=Config(signature_version='s3v4')
    )


def download_from_r2(object_key: str, save_path: str) -> str:
    """Download file from R2 using object key"""
    print(f"[Download] r2://{R2_BUCKET_NAME}/{object_key} -> {save_path}")

    s3_client = get_s3_client()
    s3_client.download_file(R2_BUCKET_NAME, object_key, save_path)

    file_size = os.path.getsize(save_path)
    print(f"[Download] Complete: {file_size / 1024 / 1024:.2f} MB")
    return save_path


def upload_to_r2(file_path: str, object_key: str) -> str:
    """Upload file to R2/S3 and return public URL"""
    print(f"[Upload] {file_path} -> {object_key}")

    s3_client = get_s3_client()

    # Determine content type
    content_type = 'video/mp4' if file_path.endswith('.mp4') else 'application/octet-stream'

    s3_client.upload_file(
        file_path,
        R2_BUCKET_NAME,
        object_key,
        ExtraArgs={'ContentType': content_type}
    )

    # Return public URL
    if R2_PUBLIC_URL:
        url = f"{R2_PUBLIC_URL}/{object_key}"
    else:
        url = f"{R2_ENDPOINT}/{R2_BUCKET_NAME}/{object_key}"

    print(f"[Upload] Complete: {url}")
    return url


def wait_for_comfyui(max_retries: int = 30, retry_delay: int = 2):
    """Wait for ComfyUI to be ready"""
    for i in range(max_retries):
        try:
            response = requests.get(f"{COMFYUI_API_URL}/system_stats", timeout=5)
            if response.status_code == 200:
                print("[ComfyUI] Ready")
                return True
        except Exception:
            pass
        print(f"[ComfyUI] Waiting... ({i + 1}/{max_retries})")
        time.sleep(retry_delay)

    raise Exception("ComfyUI failed to start")


def queue_workflow(workflow: dict) -> str:
    """Queue workflow and return prompt_id"""
    response = requests.post(
        f"{COMFYUI_API_URL}/prompt",
        json={"prompt": workflow},
        timeout=30
    )
    response.raise_for_status()
    result = response.json()
    prompt_id = result.get("prompt_id")
    print(f"[ComfyUI] Queued: {prompt_id}")
    return prompt_id


def wait_for_completion(prompt_id: str, timeout: int = 600) -> dict:
    """Wait for workflow to complete"""
    print("[ComfyUI] Waiting for completion...")
    start_time = time.time()

    while time.time() - start_time < timeout:
        try:
            response = requests.get(
                f"{COMFYUI_API_URL}/history/{prompt_id}",
                timeout=10
            )

            if response.status_code == 200:
                history = response.json()
                if prompt_id in history:
                    status = history[prompt_id].get("status", {})
                    if status.get("completed", False):
                        print("[ComfyUI] Completed")
                        return history[prompt_id]
                    if status.get("status_str") == "error":
                        raise Exception(f"Workflow error: {status}")
        except requests.exceptions.RequestException:
            pass

        time.sleep(2)

    raise Exception(f"Workflow timeout after {timeout}s")


def find_output_video(output_prefix: str = "infinitetalk_flashvsr") -> str:
    """
    Find the raw FlashVSR output video file in /comfyui/output/

    Uses exact prefix matching to avoid selecting files from other jobs.
    Selects the most recent file (by mtime) if multiple matches exist.

    VHS_VideoCombine output format:
    - {prefix}_00001.mp4 (video only)
    - {prefix}_00001-audio.mp4 (video + audio) <- we want this one

    Returns:
        Path to the raw FlashVSR output video
    """
    import re

    print(f"[Output] Searching for video in {COMFYUI_OUTPUT_DIR}")
    print(f"[Output] Looking for prefix: {output_prefix}")

    # Exact prefix matching pattern for VHS_VideoCombine output
    # VHS outputs two files when audio is provided - we want the -audio.mp4 one
    escaped_prefix = re.escape(output_prefix)
    pattern = re.compile(rf'^{escaped_prefix}_\d+-audio\.mp4$')

    candidates = []

    for filename in os.listdir(COMFYUI_OUTPUT_DIR):
        filepath = os.path.join(COMFYUI_OUTPUT_DIR, filename)

        if pattern.match(filename):
            mtime = os.path.getmtime(filepath)
            candidates.append((filepath, filename, mtime))
            print(f"[Output] Found candidate: {filename}")

    if not candidates:
        # List all files for debugging
        all_files = os.listdir(COMFYUI_OUTPUT_DIR)
        print(f"[Output] All files in output dir: {all_files}")
        raise Exception(f"No output video found matching prefix '{output_prefix}'")

    # Select the most recent file (by mtime)
    candidates.sort(key=lambda x: x[2], reverse=True)
    output_path, filename, _ = candidates[0]
    print(f"[Output] Selected: {filename}")

    return output_path


def cleanup_files(*paths):
    """Remove temporary files"""
    for path in paths:
        try:
            if path and os.path.exists(path):
                os.remove(path)
                print(f"[Cleanup] Removed: {path}")
        except Exception as e:
            print(f"[Cleanup] Error removing {path}: {e}")


# ============================================================================
# Main Handler
# ============================================================================

def handler(event: dict) -> dict:
    """
    RunPod Serverless Handler

    Input:
        event["input"]: {
            "workflow": dict,   # ComfyUI workflow JSON (already configured with local nodes)
            "imageKey": str,    # R2 object key for image
            "audioKey": str,    # R2 object key for audio
        }

    The workflow is passed from the API with local nodes already configured:
    - LoadImage (210) - loads from /comfyui/input/, filename extracted from workflow
    - VHS_LoadAudio (206) - loads from /comfyui/input/, filename extracted from workflow
    - VHS_VideoCombine (131) - raw FlashVSR output

    Handler extracts filenames from the workflow and uses them for download/upload.
    This ensures consistency between workflow node inputs and actual file paths.

    Output:
        {
            "status": "success" | "error",
            "video_raw_key": str,       # Raw FlashVSR video R2 key (~2496px)
            "execution_time": float,
            "error": str (if error),
        }
    """
    start_time = time.time()
    job_id = event.get("id", str(uuid.uuid4()))
    input_data = event.get("input", {})

    print(f"[Handler] Job started: {job_id}")

    image_path = None
    audio_path = None
    output_path = None

    try:
        # ===== Validate Input =====
        workflow = input_data.get("workflow")
        image_key = input_data.get("imageKey")
        audio_key = input_data.get("audioKey")

        if not workflow:
            raise ValueError("workflow is required")
        if not image_key:
            raise ValueError("imageKey is required")
        if not audio_key:
            raise ValueError("audioKey is required")

        # ===== Step 1: Extract filenames from workflow =====
        # The workflow already contains the correct filenames set by the caller
        print("[Handler] Step 1: Extracting filenames from workflow...")

        try:
            image_filename = workflow["210"]["inputs"]["image"]
            audio_filename = workflow["206"]["inputs"]["audio_file"]
            output_prefix = workflow["131"]["inputs"]["filename_prefix"]
        except KeyError as e:
            raise ValueError(f"Workflow missing required node/input: {e}")

        print(f"[Handler] Image filename: {image_filename}")
        print(f"[Handler] Audio filename: {audio_filename}")
        print(f"[Handler] Output prefix: {output_prefix}")

        # ===== Step 2: Download Input Files from R2 =====
        print("[Handler] Step 2: Downloading input files from R2...")

        # Extract basename from path (handles both relative and absolute paths)
        image_basename = os.path.basename(image_filename)
        audio_basename = os.path.basename(audio_filename)

        image_path = os.path.join(COMFYUI_INPUT_DIR, image_basename)
        audio_path = os.path.join(COMFYUI_INPUT_DIR, audio_basename)

        download_from_r2(image_key, image_path)
        download_from_r2(audio_key, audio_path)

        # ===== Step 3: Wait for ComfyUI =====
        print("[Handler] Step 3: Waiting for ComfyUI...")
        wait_for_comfyui()

        # ===== Step 4: Queue Workflow =====
        print("[Handler] Step 4: Queueing workflow...")
        prompt_id = queue_workflow(workflow)

        # ===== Step 5: Wait for Completion =====
        print("[Handler] Step 5: Waiting for completion...")
        wait_for_completion(prompt_id, timeout=600)

        # ===== Step 6: Find and Upload Output =====
        print("[Handler] Step 6: Uploading raw FlashVSR video...")
        output_path = find_output_video(output_prefix)

        # Use consistent path format with server-side expectations
        output_folder = os.environ.get("RUNPOD_OUTPUT_FOLDER", "generated-videos")
        filename = os.path.basename(output_path)
        object_key = f"{output_folder}/{filename}"
        upload_to_r2(output_path, object_key)

        # ===== Done =====
        execution_time = time.time() - start_time
        print(f"[Handler] Completed in {execution_time:.2f}s")

        return {
            "status": "success",
            "video_raw_key": object_key,
            "execution_time": execution_time,
        }

    except Exception as e:
        execution_time = time.time() - start_time
        error_msg = str(e)
        print(f"[Handler] Error: {error_msg}")

        return {
            "status": "error",
            "error": error_msg,
            "execution_time": execution_time,
        }

    finally:
        # ===== Cleanup =====
        print("[Handler] Cleaning up...")
        cleanup_files(image_path, audio_path, output_path)


# ============================================================================
# Entry Point
# ============================================================================

if __name__ == "__main__":
    runpod.serverless.start({"handler": handler})
