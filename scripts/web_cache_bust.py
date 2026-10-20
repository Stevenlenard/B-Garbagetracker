"""Post-build step for the web app (called by build_release.ps1 after `flutter build web`).

Browsers and old Flutter service workers could keep serving an outdated app (old main.dart.js /
flutter_bootstrap.js) after a deploy. This makes every build impossible to confuse with an
older one:
  1. main.dart.js and flutter_bootstrap.js are loaded with ?v=<hash of this build>;
  2. index.html removes any old service worker + its caches (then reloads once);
  3. no new service worker is registered (the app does not need offline caching).

usage: python scripts/web_cache_bust.py <build/web dir>
"""
import hashlib
import os
import re
import sys

web = sys.argv[1] if len(sys.argv) > 1 else os.path.join('build', 'web')
main_js = os.path.join(web, 'main.dart.js')
boot_js = os.path.join(web, 'flutter_bootstrap.js')
index = os.path.join(web, 'index.html')

v = hashlib.sha256(open(main_js, 'rb').read()).hexdigest()[:12]

boot = open(boot_js, encoding='utf-8').read()
n_main = boot.count('"mainJsPath":"main.dart.js"')
if n_main != 1:
    sys.exit('web_cache_bust: mainJsPath not found exactly once in flutter_bootstrap.js')
boot = boot.replace('"mainJsPath":"main.dart.js"', '"mainJsPath":"main.dart.js?v=%s"' % v)
boot, n_sw = re.subn(r'_flutter\.loader\.load\(\{\s*serviceWorkerSettings:\s*\{[^{}]*\}\s*\}\);', '_flutter.loader.load();', boot)
if n_sw != 1:
    sys.exit('web_cache_bust: service worker block not found in flutter_bootstrap.js')
open(boot_js, 'w', encoding='utf-8', newline='').write(boot)

CLEANUP = """<script>
    // Remove service workers / caches left by older builds, so nobody keeps an outdated app.
    (function () {
      try {
        if (!('serviceWorker' in navigator)) return;
        navigator.serviceWorker.getRegistrations().then(function (rs) {
          if (!rs.length) return;
          Promise.all(rs.map(function (r) { return r.unregister(); }))
            .then(function () {
              return window.caches ? caches.keys().then(function (k) { return Promise.all(k.map(function (x) { return caches.delete(x); })); }) : null;
            })
            .then(function () {
              try {
                if (!sessionStorage.getItem('gt_sw_reset')) { sessionStorage.setItem('gt_sw_reset', '1'); location.reload(); }
              } catch (e) {}
            });
        });
      } catch (e) {}
    })();
  </script>
  """
html = open(index, encoding='utf-8').read()
tag = '<script src="flutter_bootstrap.js" async></script>'
if html.count(tag) != 1:
    sys.exit('web_cache_bust: bootstrap <script> tag not found in index.html')
UPDATE = """<script>
    // An open page reloads itself once a newer build is deployed (checked every 5 minutes and when the tab is shown).
    (function () {
      var current = '%s';
      function check() {
        fetch('flutter_bootstrap.js?check=' + Date.now(), { cache: 'no-store' })
          .then(function (r) { return r.ok ? r.text() : ''; })
          .then(function (t) {
            var m = /main\\.dart\\.js\\?v=([0-9a-f]+)/.exec(t);
            if (m && m[1] !== current) location.reload();
          })
          .catch(function () {});
      }
      setInterval(check, 5 * 60 * 1000);
      document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });
    })();
  </script>
  """ % v
html = html.replace(tag, CLEANUP + UPDATE + '<script src="flutter_bootstrap.js?v=%s" async></script>' % v)
open(index, 'w', encoding='utf-8', newline='').write(html)
print('web_cache_bust: build %s (main.dart.js + flutter_bootstrap.js versioned, service worker off)' % v)
