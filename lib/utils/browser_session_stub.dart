/// Non-web stand-in for [browser_session_web.dart]. On Android there is no browser tab, so
/// this only matters for tests, which use the in-memory flag.
bool _marked = false;

/// Whether this browser tab session already holds a sign-in (survives a page reload, not a
/// closed browser or a new tab).
bool browserSessionMarked() => _marked;

void markBrowserSession() => _marked = true;

void clearBrowserSessionMark() => _marked = false;
