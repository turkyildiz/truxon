#!/bin/bash
# Forest wake-word training (phase 2: generate -> augment -> train)
set -euo pipefail
export PATH=~/.local/bin:$PATH
cd ~/forest-wakeword
source .venv/bin/activate

python - <<'PY'
import yaml
config = yaml.load(open("openWakeWord/examples/custom_model.yml").read(), yaml.Loader)
config["target_phrase"] = ["hey forest"]
config["model_name"] = "hey_forest"
config["custom_negative_phrases"] = ["forest", "hey ford", "hey for us", "hey florist", "hey forrest gump", "the forest"]
config["n_samples"] = 30000
config["n_samples_val"] = 2000
config["tts_batch_size"] = 64
config["augmentation_batch_size"] = 16
config["piper_sample_generator_path"] = "./piper-sample-generator"
config["output_dir"] = "./hey_forest_model"
config["rir_paths"] = ["./mit_rirs"]
config["background_paths"] = ["./audioset_16k", "./fma"]
config["background_paths_duplication_rate"] = [1, 1]
config["false_positive_validation_data_path"] = "validation_set_features.npy"
config["feature_data_files"] = {"ACAV100M_sample": "openwakeword_features_ACAV100M_2000_hrs_16bit.npy"}
config["steps"] = 25000
config["target_accuracy"] = 0.7
config["target_recall"] = 0.5
config["batch_n_per_class"] = {"ACAV100M_sample": 1024, "adversarial_negative": 512, "positive": 512}
yaml.dump(config, open("hey_forest.yaml", "w"))
print("config written")
PY

echo "=== STEP 1: generate synthetic clips ==="
python openWakeWord/openwakeword/train.py --training_config hey_forest.yaml --generate_clips

echo "=== STEP 2: augment clips ==="
python openWakeWord/openwakeword/train.py --training_config hey_forest.yaml --augment_clips

echo "=== STEP 3: train model ==="
python openWakeWord/openwakeword/train.py --training_config hey_forest.yaml --train_model

echo "=== ARTIFACTS ==="
ls -la hey_forest_model/*.onnx hey_forest_model/*.tflite 2>/dev/null
echo "TRAINING DONE"
