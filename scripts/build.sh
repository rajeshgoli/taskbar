#!/bin/bash
set -euo pipefail
swift build -c release
echo "Build complete: .build/release/DeskBar"
