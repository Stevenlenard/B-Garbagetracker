library browser_session_web;

import 'dart:html' as html;

const String _key = 'gt_signed_in_this_tab';

/// Whether this browser tab session already holds a sign-in (sessionStorage: survives a page
/// reload, not a closed browser or a new tab).
bool browserSessionMarked() {
  try {
    return html.window.sessionStorage[_key] == '1';
  } catch (_) {
    return false;
  }
}

void markBrowserSession() {
  try {
    html.window.sessionStorage[_key] = '1';
  } catch (_) {}
}

void clearBrowserSessionMark() {
  try {
    html.window.sessionStorage.remove(_key);
  } catch (_) {}
}
