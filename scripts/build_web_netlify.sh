#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/flutter/bin:$HOME/flutter/bin/cache/dart-sdk/bin:$PATH"

if [ ! -d "$HOME/flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
fi

flutter --version
flutter config --enable-web
flutter config --no-analytics

flutter clean
flutter pub get

if [ -z "${SAS_PROXY_TOKEN:-}" ] || [ -z "${SAS_WEB_PROXY_URL:-}" ]; then
  echo "Missing SAS_PROXY_TOKEN or SAS_WEB_PROXY_URL in Netlify environment variables." >&2
  exit 1
fi

WAHA_GATEWAY_URL="${WAHA_GATEWAY_URL:-https://netagentiraq.duckdns.org}"
WHATSAPP_SERVICE_URL="${WHATSAPP_SERVICE_URL:-https://ha-0cs7.onrender.com}"

case "$WAHA_GATEWAY_URL" in
  https://*) ;;
  *)
    echo "WAHA_GATEWAY_URL must use HTTPS." >&2
    exit 1
    ;;
esac

cat > web/runtime_config.js <<EOF
window.__APP_CONFIG__ = {
  whatsappServiceUrl: "${WHATSAPP_SERVICE_URL}",
  sasProxyToken: "${SAS_PROXY_TOKEN}",
  sasWebProxyUrl: "${SAS_WEB_PROXY_URL}"
};
EOF

flutter build web --release --pwa-strategy=none \
  --base-href / \
  --dart-define=SAS_PROXY_TOKEN="${SAS_PROXY_TOKEN}" \
  --dart-define=SAS_WEB_PROXY_URL="${SAS_WEB_PROXY_URL}" \
  --dart-define=NETAGENT_WHATSAPP_PROVIDER=meta \
  --dart-define=WAHA_GATEWAY_URL="${WAHA_GATEWAY_URL}"

cp web/runtime_config.js build/web/runtime_config.js

if [ ! -s build/web/index.html ] ||
  [ ! -s build/web/flutter_bootstrap.js ] ||
  [ ! -s build/web/runtime_config.js ] ||
  [ ! -s build/web/main.dart.js ]; then
  echo "ERROR: Required Flutter web build output is missing or empty." >&2
  exit 1
fi

if grep -Eq '\{\{flutter_js\}\}|\{\{flutter_build_config\}\}' \
  build/web/flutter_bootstrap.js; then
  echo "ERROR: Flutter bootstrap contains unprocessed placeholders." >&2
  exit 1
fi

if ! grep -Fq '<base href="/">' build/web/index.html ||
  ! grep -Fq 'src="runtime_config.js"' build/web/index.html ||
  ! grep -Fq 'src="flutter_bootstrap.js"' build/web/index.html; then
  echo "ERROR: Built index.html does not reference the expected root assets." >&2
  exit 1
fi

runtime_config=build/web/runtime_config.js
for config_key in whatsappServiceUrl sasProxyToken sasWebProxyUrl; do
  if ! grep -Fq "$config_key" "$runtime_config"; then
    echo "ERROR: Built runtime config is missing a required setting." >&2
    exit 1
  fi
done

runtime_line=$(grep -nF 'src="runtime_config.js"' build/web/index.html | cut -d: -f1)
bootstrap_line=$(grep -nF 'src="flutter_bootstrap.js"' build/web/index.html | cut -d: -f1)
if [ "$runtime_line" -ge "$bootstrap_line" ]; then
  echo "ERROR: runtime_config.js must load before flutter_bootstrap.js." >&2
  exit 1
fi

echo "SUCCESS: Verified Netlify deployment output: $(cd build/web && pwd -P)"