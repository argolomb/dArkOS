#!/bin/bash
set -e

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tools/r43/build-image.sh
