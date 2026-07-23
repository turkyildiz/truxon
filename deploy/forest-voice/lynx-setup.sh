#!/bin/bash
# Forest wake-word training environment setup on Lynx (phase 1: deps + data)
set -euo pipefail
export PATH=~/.local/bin:$PATH
cd ~/forest-wakeword

echo "=== venv (python 3.10) ==="
uv python install 3.10
rm -rf .venv
uv venv --python 3.10 .venv
source .venv/bin/activate

echo "=== torch (cu128 for Blackwell sm_120) ==="
uv pip install torch torchaudio --index-url https://download.pytorch.org/whl/cu128

echo "=== training deps (notebook pins) ==="
uv pip install -e ./openWakeWord
uv pip install piper-phonemize-cross webrtcvad mutagen==1.47.0 torchinfo==1.8.0 \
  torchmetrics==1.2.0 speechbrain==0.5.14 audiomentations==0.33.0 \
  torch-audiomentations==0.11.0 acoustics==0.2.6 pronouncing==0.2.0 \
  datasets==2.14.6 deep-phonemizer==0.0.19 soundfile scipy tqdm pyyaml
uv pip install "pyarrow==15.0.2" tensorflow-cpu==2.8.1 tensorflow_probability==0.16.0 onnx_tf==1.10.0 \
  "protobuf<3.20" "numpy<2"

echo "=== piper sample generator model ==="
mkdir -p piper-sample-generator/models
[ -f piper-sample-generator/models/en_US-libritts_r-medium.pt ] || \
  wget -q -O piper-sample-generator/models/en_US-libritts_r-medium.pt \
  'https://github.com/rhasspy/piper-sample-generator/releases/download/v2.0.0/en_US-libritts_r-medium.pt'

echo "=== openwakeword base models ==="
mkdir -p openWakeWord/openwakeword/resources/models
cd openWakeWord/openwakeword/resources/models
for f in embedding_model.onnx embedding_model.tflite melspectrogram.onnx melspectrogram.tflite; do
  [ -f $f ] || wget -q "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/$f" -O $f
done
cd ~/forest-wakeword

echo "=== precomputed negative features (~2GB) ==="
[ -f openwakeword_features_ACAV100M_2000_hrs_16bit.npy ] || \
  wget -q https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/openwakeword_features_ACAV100M_2000_hrs_16bit.npy
[ -f validation_set_features.npy ] || \
  wget -q https://huggingface.co/datasets/davidscripka/openwakeword_features/resolve/main/validation_set_features.npy

echo "=== MIT RIRs ==="
python - <<'PY'
import os, numpy as np, scipy.io.wavfile, datasets
from tqdm import tqdm
out = "./mit_rirs"
if not os.path.exists(out) or len(os.listdir(out)) < 200:
    os.makedirs(out, exist_ok=True)
    ds = datasets.load_dataset("davidscripka/MIT_environmental_impulse_responses", split="train", streaming=True)
    for row in tqdm(ds):
        name = row['audio']['path'].split('/')[-1]
        scipy.io.wavfile.write(os.path.join(out, name), 16000, (row['audio']['array']*32767).astype(np.int16))
PY

echo "=== AudioSet background (one shard) ==="
if [ ! -d audioset_16k ] || [ $(ls audioset_16k | wc -l) -lt 500 ]; then
  mkdir -p audioset audioset_16k
  [ -f audioset/bal_train09.tar ] || wget -q -O audioset/bal_train09.tar \
    'https://huggingface.co/datasets/agkphysics/AudioSet/resolve/main/data/bal_train09.tar'
  (cd audioset && tar -xf bal_train09.tar)
  python - <<'PY'
import os, numpy as np, scipy.io.wavfile, datasets
from pathlib import Path
from tqdm import tqdm
files = [str(i) for i in Path("audioset/audio").glob("**/*.flac")]
ds = datasets.Dataset.from_dict({"audio": files}).cast_column("audio", datasets.Audio(sampling_rate=16000))
for row in tqdm(ds):
    name = row['audio']['path'].split('/')[-1].replace(".flac", ".wav")
    scipy.io.wavfile.write(os.path.join("audioset_16k", name), 16000, (row['audio']['array']*32767).astype(np.int16))
PY
fi

echo "=== FMA music background (2 hours) ==="
python - <<'PY'
import os, numpy as np, scipy.io.wavfile, datasets
from tqdm import tqdm
out = "./fma"
os.makedirs(out, exist_ok=True)
if len(os.listdir(out)) < 200:
    ds = iter(datasets.load_dataset("rudraml/fma", name="small", split="train", streaming=True)
              .cast_column("audio", datasets.Audio(sampling_rate=16000)))
    for i in tqdm(range(2*3600//30)):
        row = next(ds)
        name = row['audio']['path'].split('/')[-1].replace(".mp3", ".wav")
        scipy.io.wavfile.write(os.path.join(out, name), 16000, (row['audio']['array']*32767).astype(np.int16))
PY

echo "SETUP DONE"
