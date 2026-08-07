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
flutter clean
flutter pub get

echo "Netlify SAS_PROXY_TOKEN present: ${SAS_PROXY_TOKEN:+yes}"
echo "Netlify SAS_WEB_PROXY_URL present: ${SAS_WEB_PROXY_URL:+yes}"

if [ -z "${SAS_PROXY_TOKEN:-}" ] || [ -z "${SAS_WEB_PROXY_URL:-}" ]; then
  echo "Missing required Netlify env vars for Flutter build: SAS_PROXY_TOKEN and SAS_WEB_PROXY_URL" >&2
  exit 1
fi

cat > web/runtime_config.js <<EOF
window.__APP_CONFIG__ = {
  sasProxyToken: "${SAS_PROXY_TOKEN}",
  sasWebProxyUrl: "${SAS_WEB_PROXY_URL}"
};
EOF

flutter build web --release \
  --dart-define=SAS_PROXY_TOKEN="${SAS_PROXY_TOKEN}" \
  --dart-define=SAS_WEB_PROXY_URL="${SAS_WEB_PROXY_URL}"
