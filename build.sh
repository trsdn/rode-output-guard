#!/usr/bin/env bash
# Compile rode-output-guard into a standalone arm64 binary.
# Output goes to ./rode-output-guard (same dir).

set -euo pipefail
cd "$(dirname "$0")"

swiftc -O \
    -framework CoreAudio \
    -framework Foundation \
    -o rode-output-guard \
    main.swift

echo "Built: $(pwd)/rode-output-guard"
