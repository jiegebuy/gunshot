#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${THEOS:?Set THEOS to your Theos checkout}"
scheme=${1:-rootless}
case "$scheme" in rootless) args=(THEOS_PACKAGE_SCHEME=rootless);; rootful) args=(THEOS_PACKAGE_SCHEME=);; jailed) args=(THEOS_PACKAGE_SCHEME=);; *) echo 'Expected rootless, rootful or jailed' >&2; exit 1;; esac
bash scripts/build-go.sh
python3 scripts/third-party-notices.py
if [[ "$scheme" == jailed ]]; then
  make -C Jailed clean
  make -C Jailed package FINALPACKAGE=1 "${args[@]}"
  python3 scripts/export-jailed.py
  bash scripts/build-live-activity.sh
else
  make clean
  make -k package FINALPACKAGE=1 "${args[@]}"
fi
