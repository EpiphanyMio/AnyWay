#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
"$(xcrun --find python3)" -m venv .build/iphone-venv
.build/iphone-venv/bin/python -m pip install -U 'pymobiledevice3==11.50.0'
printf 'Installed iPhone support in %s\n' "$PWD/.build/iphone-venv"
