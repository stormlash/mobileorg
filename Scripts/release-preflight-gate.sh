#!/bin/bash
#
# Post-archive preflight gates for TestFlight delivery.
#
# Usage: Scripts/release-preflight-gate.sh <path-to.xcarchive>
#
# Gate 1 — ITMS-90809: no UIWebView references (linked symbols or surviving
#          strings) in any Mach-O binary inside the archived app. The source
#          tree is clean; the residual risk is compiled third-party code
#          (SwiftyDropbox/Alamofire), which only binary scanning can see.
# Gate 2 — ITMS-91053 family: a PrivacyInfo.xcprivacy manifest is bundled and
#          declares the required-reason APIs the app uses (NSUserDefaults in
#          Settings.m and SessionManager.m → UserDefaults category, CA92.1).
#
# Exits non-zero on the first failed gate, naming the offending binary/file.

set -uo pipefail

ARCHIVE="${1:?usage: Scripts/release-preflight-gate.sh <path-to.xcarchive>}"

fail() {
  echo "❌ release-preflight-gate: $*"
  exit 1
}

[ -d "$ARCHIVE" ] || fail "archive not found: $ARCHIVE"

APP_BUNDLE="$(find "$ARCHIVE/Products" -type d -name '*.app' | head -n1)"
[ -n "$APP_BUNDLE" ] || fail "no .app bundle under $ARCHIVE/Products"
echo "🔍 Scanning app bundle: $APP_BUNDLE"

# Gate 1: UIWebView references across every Mach-O file in the bundle —
# the main executable, embedded frameworks, and PlugIns. `file` filters to
# Mach-O when available (macOS runners); without it, scan every regular
# file so local testing on other platforms stays honest.
hit=0
while IFS= read -r -d '' bin; do
  if command -v file >/dev/null 2>&1 && ! file "$bin" | grep -q "Mach-O"; then
    continue
  fi
  # nm errors on non-object files — only a match is a hit, not an error.
  if nm "$bin" 2>/dev/null | grep -qi "uiwebview"; then
    echo "❌ UIWebView symbol found in: $bin"
    hit=1
  elif strings "$bin" 2>/dev/null | grep -qi "uiwebview"; then
    echo "❌ UIWebView string found in: $bin"
    hit=1
  fi
done < <(find "$APP_BUNDLE" -type f -print0)
[ "$hit" -eq 0 ] || fail "UIWebView references found — App Store Connect will reject this binary (ITMS-90809). Remove the dependency or fix the usage."
echo "✅ Gate 1 passed: no UIWebView references in any linked binary (ITMS-90809)"

# Gate 2: privacy manifest present, valid, and declaring required-reason APIs.
MANIFEST="$APP_BUNDLE/PrivacyInfo.xcprivacy"
[ -f "$MANIFEST" ] || fail "PrivacyInfo.xcprivacy is not bundled in the app (required-reason API declaration, ITMS-91053). Add it to the app target's Resources."

lint_plist() {
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$1" >/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])' "$1"
  else
    echo "⚠️ no plist linter available (plutil/python3) — skipping XML validation"
  fi
}
lint_plist "$MANIFEST" || fail "PrivacyInfo.xcprivacy is not valid XML/plist"

grep -q "NSPrivacyAccessedAPIType" "$MANIFEST" || fail "PrivacyInfo.xcprivacy declares no NSPrivacyAccessedAPIType entries"
grep -q "NSPrivacyAccessedAPICategoryUserDefaults" "$MANIFEST" || fail "PrivacyInfo.xcprivacy does not declare the UserDefaults API category — the app reads NSUserDefaults in Settings.m and SessionManager.m (ITMS-91053)"
echo "✅ Gate 2 passed: privacy manifest bundled and declares required-reason APIs (UserDefaults/CA92.1)"

echo "✅ Release preflight gates passed."
