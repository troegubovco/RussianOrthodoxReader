#!/usr/bin/env python3
"""
Quantize YandexGPT-5-Lite-8B from f16 to Q8 for 16GB Mac.

Memory budget:
  Q8 weights:  ~7 GB
  KV cache:    ~2 GB
  OS/overhead: ~3 GB
  Total:       ~12 GB  (fits in 16 GB unified memory)

Usage:
  /Users/andreyt/Developer/mlx_env/bin/python Tools/quantize_yandexgpt.py
"""

import subprocess
import sys
import os

MODEL_PATH = "/Users/andreyt/yandexgpt-mlx/mlx_models/YandexGPT-5-Lite-8B-instruct-f16"
OUTPUT_PATH = "/Users/andreyt/Developer/Models/YandexGPT-q8"
PYTHON = "/Users/andreyt/Developer/mlx_env/bin/python"

def main():
    if not os.path.isdir(MODEL_PATH):
        print(f"Error: source model not found at {MODEL_PATH}", file=sys.stderr)
        sys.exit(1)

    if os.path.isdir(OUTPUT_PATH):
        print(f"Output path already exists: {OUTPUT_PATH}")
        answer = input("Overwrite? [y/N] ").strip().lower()
        if answer != "y":
            print("Aborted.")
            sys.exit(0)

    print(f"Source: {MODEL_PATH}")
    print(f"Output: {OUTPUT_PATH}")
    print(f"Quant:  Q8, group_size=64, mode=affine")
    print(f"\nStarting conversion (this takes ~10–20 minutes)...\n")

    subprocess.run(
        [
            PYTHON, "-m", "mlx_lm", "convert",
            "--hf-path", MODEL_PATH,
            "--mlx-path", OUTPUT_PATH,
            "-q",
            "--q-bits", "8",
            "--q-group-size", "64",
        ],
        check=True,
    )

    print(f"\nDone. Model saved to: {OUTPUT_PATH}")
    print("\nNext step: update MODEL_PATH in Tools/enrich_church_slavonic.py:")
    print(f'  MODEL_PATH = "{OUTPUT_PATH}"')

if __name__ == "__main__":
    main()
