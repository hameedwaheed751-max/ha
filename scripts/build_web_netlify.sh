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

# Source assets only belong in web/. Generated files here can overwrite the
# fresh compiler output when Flutter copies web assets into build/web.
rm -f \
  web/.last_build_id \
  web/flutter.js \
  web/flutter_service_worker.js \
  web/main.dart.js \
  web/version.json \
  web/canvaskit.js web/canvaskit.js.symbols web/canvaskit.wasm \
  web/skwasm.js web/skwasm.js.symbols web/skwasm.wasm \
  web/skwasm_heavy.js web/skwasm_heavy.js.symbols web/skwasm_heavy.wasm \
  web/wimp.js web/wimp.js.symbols web/wimp.wasm

echo "Netlify SAS_PROXY_TOKEN present: ${SAS_PROXY_TOKEN:+yes}"
echo "Netlify SAS_WEB_PROXY_URL present: ${SAS_WEB_PROXY_URL:+yes}"

if [ -z "${SAS_PROXY_TOKEN:-}" ] || [ -z "${SAS_WEB_PROXY_URL:-}" ]; then
  echo "Missing required Netlify env vars for Flutter build: SAS_PROXY_TOKEN and SAS_WEB_PROXY_URL" >&2
  exit 1
fi

if [[ "$SAS_WEB_PROXY_URL" == *".onreder.com"* ]]; then
  echo "Correcting misspelled Render hostname in SAS_WEB_PROXY_URL"
  SAS_WEB_PROXY_URL="${SAS_WEB_PROXY_URL/.onreder.com/.onrender.com}"
  export SAS_WEB_PROXY_URL
fi

mkdir -p web
cat > web/runtime_config.js <<EOF
window.__APP_CONFIG__ = {
  sasProxyToken: "${SAS_PROXY_TOKEN}",
  sasWebProxyUrl: "${SAS_WEB_PROXY_URL}"
};
EOF

flutter build web --release --pwa-strategy=none \
  --dart-define=SAS_PROXY_TOKEN="${SAS_PROXY_TOKEN}" \
  --dart-define=SAS_WEB_PROXY_URL="${SAS_WEB_PROXY_URL}"

mkdir -p build/web
cp web/runtime_config.js build/web/runtime_config.js
