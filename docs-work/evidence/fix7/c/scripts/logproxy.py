"""A TCP relay that logs the head of each HTTP request it passes on (request line and headers),
and the first line of the answer.

    python3 logproxy.py LISTEN_PORT TARGET_PORT LOGFILE

Each connection: the bytes up to the first blank line are written to LOGFILE (one block per
connection, "== connection N" first), then everything is relayed both ways as it is; the first
line that comes back is logged as "<- connection N: ...".
"""
import socket
import sys
import threading

listen_port, target_port, logfile = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
lock = threading.Lock()
count = [0]


def log(data):
    with lock:
        with open(logfile, "ab") as f:
            f.write(data)


def pipe(a, b, n=None):
    """a to b; with n, the first line of what comes (the server's status line) is logged"""
    try:
        while True:
            data = a.recv(65536)
            if not data:
                break
            if n is not None:
                log(b"<- connection %d: " % n + data.split(b"\r\n", 1)[0] + b"\n")
                n = None
            b.sendall(data)
    except OSError:
        pass
    for s in (a, b):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def serve(client):
    head = b""
    while b"\r\n\r\n" not in head:
        data = client.recv(65536)
        if not data:
            client.close()
            return
        head += data
    with lock:
        count[0] += 1
        n = count[0]
    log(b"== connection %d\n" % n + head.split(b"\r\n\r\n", 1)[0] + b"\n")
    upstream = socket.create_connection(("127.0.0.1", target_port))
    upstream.sendall(head)
    threading.Thread(target=pipe, args=(upstream, client, n), daemon=True).start()
    pipe(client, upstream)


server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", listen_port))
server.listen(16)
while True:
    conn, _ = server.accept()
    threading.Thread(target=serve, args=(conn,), daemon=True).start()
