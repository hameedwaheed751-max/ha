#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/flutter/bin:$HOME/flutter/bin/cache/dart-sdk/bin:$PATH"

if [ ! -d "$HOME/flutter" ]; then
  git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
fi

flutter --version
flutter config --enable-web
flutter config --no-analytics
flutter pub get

WAHA_GATEWAY_URL="${WAHA_GATEWAY_URL:-https://netagentiraq.duckdns.org}"

case "$WAHA_GATEWAY_URL" in
  https://*) ;;
  *)
    echo "WAHA_GATEWAY_URL must use HTTPS." >&2
    exit 1
    ;;
esac

flutter build web --release --pwa-strategy=none \
  --base-href / \
  --dart-define=NETAGENT_WHATSAPP_PROVIDER=meta \
  --dart-define=WAHA_GATEWAY_URL="${WAHA_GATEWAY_URL}"

if [ -z "${SAS_PROXY_TOKEN:-}" ]; then
  echo "SAS_PROXY_TOKEN must be set in the Render environment." >&2
  exit 1
fi

case "$SAS_PROXY_TOKEN" in
  *\"* | *\\*)
    echo "SAS_PROXY_TOKEN must not contain quotes or backslashes." >&2
    exit 1
    ;;
esac

escaped_token=$(printf '%s' "$SAS_PROXY_TOKEN" | sed -e 's/[&|]/\\&/g')
sed "s|sasProxyToken: \"[^\"]*\"|sasProxyToken: \"${escaped_token}\"|" \
  web/runtime_config.js > build/web/runtime_config.js

if ! grep -Fq "sasProxyToken: \"${SAS_PROXY_TOKEN}\"" build/web/runtime_config.js; then
  echo "SAS_PROXY_TOKEN was not written to runtime_config.js." >&2
  exit 1
fi

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

echo "SUCCESS: Verified Render deployment output: $(cd build/web && pwd -P)"
