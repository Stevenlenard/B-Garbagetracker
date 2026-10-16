#!/usr/bin/env bash
# Read-only check that the release artifacts postdate the latest source change and
# contain the expected markers. Prints findings; changes nothing.
cd "$(dirname "$0")/.." || exit 1

newest_src=$(git ls-files -m -o --exclude-standard lib backend pubspec.yaml pubspec.lock 2>/dev/null \
  | xargs -r stat -c '%Y %n' 2>/dev/null | sort -rn | head -1)
echo "newest tracked-or-changed source: $newest_src"

apk=build/app/outputs/flutter-apk/app-release.apk
web=build/web/main.dart.js
for f in "$apk" "$web"; do
  [ -f "$f" ] || { echo "MISSING $f"; continue; }
  m=$(stat -c %Y "$f")
  src=${newest_src%% *}
  state=$([ "$m" -ge "$src" ] && echo "CURRENT" || echo "OUTDATED")
  echo "$state  $f  built $(date -d @"$m" '+%F %T')"
done

markers=("X-GT-Token" "collection_finalized" "AUTO_LOGIN" "gps_at" "complaint_resolved_" "indigo-bear-885857.hostingersite.com/backend/" "garbagesis-78d39")
echo "--- markers in web bundle:"
for k in "${markers[@]}"; do printf '%-60s %s\n' "$k" "$(grep -c -a -- "$k" "$web" 2>/dev/null)"; done
echo "--- test-mode leakage (must be 0):"
printf '%-60s %s\n' "GT_TEST_MODE true compiled" "$(grep -c -a '127.0.0.1:8080\|10.0.2.2' "$web" 2>/dev/null)"
