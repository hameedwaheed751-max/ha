#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/flutter/bin:$PATH"
export PATH="$HOME/flutter/bin/cache/dart-sdk/bin:$PATH"

if [ ! -d "$HOME/flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
fi

flutter --version
flutter config --enable-web
flutter config --no-analytics
flutter pub get

flutter build web --release \
  --dart-define=SAS_PROXY_TOKEN="${SAS_PROXY_TOKEN:-}" \
  --dart-define=SAS_WEB_PROXY_URL="${SAS_WEB_PROXY_URL:-}"
