#!/usr/bin/env bash
# بناء نسخة الويب بأمان: دائماً flutter clean أولاً، وإلا ينتج بناء ناقص
# (مجلّد الأصول فارغ) فتظهر شاشة بيضاء على الويب. يتحقّق من اكتمال الأصول.
#
# الاستخدام:
#   bash tool/build_web.sh            # بناء فقط
#   bash tool/build_web.sh --deploy   # بناء ثم نشر على Firebase Hosting الحيّ
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> flutter clean"
flutter clean

echo "==> flutter build web --release"
flutter build web --release

# تحقّق إلزامي: حزمة الأصول يجب أن تكون مكتملة.
MANIFEST="build/web/assets/AssetManifest.bin.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "خطأ: $MANIFEST مفقود — البناء ناقص. لا تنشر." >&2
  exit 1
fi
ASSET_FILES=$(find build/web/assets -type f | wc -l)
if [[ "$ASSET_FILES" -lt 1 ]]; then
  echo "خطأ: مجلّد build/web/assets فارغ — البناء ناقص. لا تنشر." >&2
  exit 1
fi
echo "==> البناء مكتمل ($ASSET_FILES ملف أصول)."

if [[ "${1:-}" == "--deploy" ]]; then
  echo "==> firebase deploy --only hosting"
  firebase deploy --only hosting --project wakeiq-4b97b
  echo "==> نُشر على https://wakeiq-4b97b.web.app"
fi
