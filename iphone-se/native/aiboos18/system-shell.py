#!/usr/bin/env python3
"""Launch the original bundled AiboOS application, not a remote website.
Requires a non-root desktop session and GTK3/WebKitGTK 4.1.
No iOS bridge is advertised until real Linux implementations exist.
"""
import functools
import http.server
import os
from pathlib import Path
import threading

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("WebKit2", "4.1")
from gi.repository import Gtk, WebKit2

ROOT = Path(__file__).resolve().parent / "web"
PORT = 18781
URL = f"http://127.0.0.1:{PORT}/index.html"

class BundledResources(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Host") != f"127.0.0.1:{PORT}":
            self.send_error(400)
            return
        super().do_GET()
    def list_directory(self, path):
        self.send_error(403)
        return None

def main():
    if os.geteuid() == 0:
        raise SystemExit("Run AiboOS as a dedicated unprivileged session user")
    if not (ROOT / "index.html").is_file():
        raise SystemExit("Original AiboOS 1.8 release assets missing")
    os.umask(0o077)
    state = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "aiboos18"
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "aiboos18"
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    handler = functools.partial(BundledResources, directory=str(ROOT))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    manager = WebKit2.WebsiteDataManager(base_data_directory=str(state), base_cache_directory=str(cache))
    context = WebKit2.WebContext.new_with_website_data_manager(manager)
    view = WebKit2.WebView.new_with_context(context)
    view.get_settings().set_property("enable-developer-extras", False)
    window = Gtk.Window(title="AiboOS 1.8")
    window.set_decorated(False)
    window.add(view)
    window.connect("destroy", Gtk.main_quit)
    window.show_all()
    window.fullscreen()
    view.load_uri(URL)
    try:
        Gtk.main()
    finally:
        server.shutdown()
        server.server_close()

if __name__ == "__main__":
    main()
