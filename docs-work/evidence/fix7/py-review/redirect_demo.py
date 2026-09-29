"""Does the helper hand its API key to whatever host a redirect points at?

    python redirect_demo.py CODE_DIR
CODE_DIR holds esp32c5_kismet/ (the new code, or the saved old one). Server A (127.0.0.1:2731) stands for
a proxy in front of Kismet that answers the websocket upgrade with a 302 to another host; server B
(127.0.0.2:3731) is that other host and logs what it is sent.
"""
import argparse
import socket
import sys
import threading

sys.path.insert(0, sys.argv[1])
from esp32c5_kismet import remote  # noqa: E402
import websocket  # noqa: E402

seen = {}


def serve(addr, name, answer):
    ls = socket.socket()
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(addr)
    ls.listen(1)

    def run():
        c, _ = ls.accept()
        head = b""
        while b"\r\n\r\n" not in head:
            data = c.recv(4096)
            if not data:
                break
            head += data
        seen[name] = head.decode("latin-1").split("\r\n\r\n")[0]
        c.sendall(answer)
        c.close()
        ls.close()
    t = threading.Thread(target=run, daemon=True)
    t.start()
    return t


ta = serve(("127.0.0.1", 2731), "A (Kismet's proxy)",
           b"HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.2:3731/login\r\nContent-Length: 0\r\n\r\n")
tb = serve(("127.0.0.2", 3731), "B (the redirect's target, another host)",
           b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
args = argparse.Namespace(tcp=False, user=None, password=None, apikey="SECRET-API-KEY", ssl=False,
                          ssl_certificate=None, endpoint=remote.WS_ENDPOINT)
try:
    remote.make_connector(args, "127.0.0.1", 2731)()
except Exception as e:
    print("helper: %s: %s" % (type(e).__name__, e))
ta.join(3)
tb.join(3)
print("websocket-client", websocket.__version__)
for name in sorted(seen):
    print("--- %s got:" % name)
    print(seen[name])
leaked = "SECRET-API-KEY" in seen.get("B (the redirect's target, another host)", "")
print("=== the API key reached the other host:", leaked)
