#!/usr/bin/env bash
# One-time, local-only setup for Quill Hebrew's MLX transcription engine.
# Review before running. It installs Python packages in a dedicated venv and
# downloads model weights directly from Hugging Face; it never uploads audio.
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
  echo "This setup requires an Apple-silicon Mac (arm64 macOS)." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required to install ffmpeg: https://brew.sh" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required. Install Xcode Command Line Tools, then retry." >&2
  exit 1
fi

readonly quill_venv="$HOME/.local/share/quill-hebrew/mlx-whisper"
readonly model_dir="$HOME/Library/Application Support/quill-hebrew/models/ivrit-ai-whisper-large-v3-turbo-mlx"
readonly config_dir="$HOME/.config/quill"
readonly config_file="$config_dir/config.json"
readonly model_repo="mlx-community/ivrit-ai-whisper-large-v3-turbo-mlx"

brew install ffmpeg
mkdir -p "$(dirname "$quill_venv")" "$model_dir" "$config_dir"

if [[ ! -x "$quill_venv/bin/python" ]]; then
  python3 -m venv "$quill_venv"
fi

"$quill_venv/bin/python" -m pip install --upgrade pip
"$quill_venv/bin/python" -m pip install --upgrade "mlx-whisper" "huggingface_hub[hf_xet]"
"$quill_venv/bin/hf" download --local-dir "$model_dir" "$model_repo"

"$quill_venv/bin/python" - "$config_file" "$quill_venv/bin/python" "$model_dir" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
python_path = sys.argv[2]
model_path = sys.argv[3]

try:
    config = json.loads(config_path.read_text()) if config_path.exists() else {}
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"Refusing to overwrite invalid config at {config_path}: {exc}")

transcription = config.setdefault("transcription", {})
if not isinstance(transcription, dict):
    raise SystemExit(f"Refusing to replace non-object transcription setting in {config_path}")

transcription.update({
    "enabled": True,
    "engine": "mlx-hebrew",
    "language": "hebrew",
    "mlx_python": python_path,
    "mlx_model_dir": model_path,
})
config_path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
PY

echo "Hebrew MLX setup complete. Run: quill doctor"
