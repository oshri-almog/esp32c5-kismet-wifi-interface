# 127.0.0.1:2621 answers every request with a 302 to 127.0.0.2:3621; 127.0.0.2:3621 logs what
# arrives there. Each request head goes to LOG with who saw it.
import socket, sys, threading
log = sys.argv[1]
def head_of(c):
    h = b""
    c.settimeout(5)
    try:
        while b"\r\n\r\n" not in h:
            d = c.recv(65536)
            if not d:
                break
            h += d
    except OSError:
        pass
    return h.split(b"\r\n\r\n")[0].replace(b"\r", b"")
def write(tag, h):
    with open(log, "ab") as f:
        f.write(b"== " + tag + b"\n" + h + b"\n")
def redirector():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", 2621)); s.listen(8)
    while True:
        c, _ = s.accept()
        write(b"2621 (Kismet's address, answers 302)", head_of(c))
        c.sendall(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.2:3621/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        c.close()
def other():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.2", 3621)); s.listen(8)
    while True:
        c, _ = s.accept()
        write(b"127.0.0.2:3621 (the redirect's target, another host)", head_of(c))
        c.close()
threading.Thread(target=redirector, daemon=True).start()
other()
