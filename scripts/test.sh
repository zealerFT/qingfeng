#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift run QingfengCoreChecks
python3 scripts/test-ai-transport.py
