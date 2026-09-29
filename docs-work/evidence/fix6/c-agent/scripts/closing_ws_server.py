# closing_ws_server.py PORT: accepts one websocket (the kismet-remote protocol), sends a CLOSE
# frame a second later, and then keeps the TCP connection open without a word, so that the
# client's close handshake can only end by its own timeout. Prints what it does, with times.
import base64, hashlib, socket, sys, time
port = int(sys.argv[1])
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port)); srv.listen(4)
def say(t): print("%s server: %s" % (time.strftime("%H:%M:%S"), t), flush=True)
conns = []
while True:
    c, a = srv.accept(); conns.append(c)
    req = b""
    while b"\r\n\r\n" not in req:
        req += c.recv(4096)
    key = [l.split(b":", 1)[1].strip() for l in req.split(b"\r\n") if l.lower().startswith(b"sec-websocket-key")][0]
    acc = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
    c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              b"Sec-WebSocket-Accept: " + acc + b"\r\nSec-WebSocket-Protocol: kismet-remote\r\n\r\n")
    say("websocket accepted from %s:%d" % a)
    time.sleep(1)
    c.sendall(b"\x88\x02\x03\xe8")
    say("sent CLOSE (1000); the TCP connection stays open, and nothing more is sent")
