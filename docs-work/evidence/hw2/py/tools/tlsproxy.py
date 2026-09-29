#!/usr/bin/env python3
"""tlsproxy.py LISTEN_PORT CERT KEY [PREFIX]: TLS on 127.0.0.1:LISTEN_PORT, plain TCP to Kismet on 127.0.0.1:2501.

With PREFIX (such as /kismet), a request line whose path starts with it has it removed, as a reverse proxy
that publishes Kismet under a path would; the helpers then need --endpoint PREFIX/datasource/remote/remotesource.ws.
Logs one line per connection with the request line it forwarded.
"""
import asyncio
import ssl
import sys
import time

PORT, CERT, KEY = int(sys.argv[1]), sys.argv[2], sys.argv[3]
PREFIX = sys.argv[4].encode() if len(sys.argv) > 4 else b""


async def pipe(r, w):
    try:
        while True:
            data = await r.read(65536)
            if not data:
                break
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def handle(cr, cw):
    try:
        head = await cr.readuntil(b"\r\n\r\n")
    except Exception as e:
        print("%.3f handshake/headers failed: %r" % (time.time(), e), flush=True)
        cw.close()
        return
    line, rest = head.split(b"\r\n", 1)
    method, path, ver = line.split(b" ", 2)
    if PREFIX:
        if path.startswith(PREFIX + b"/"):
            path = path[len(PREFIX):]
        else:
            print("%.3f 404 for %r" % (time.time(), line[:120]), flush=True)
            cw.write(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            await cw.drain()
            cw.close()
            return
    print("%.3f forward %s %s" % (time.time(), method.decode(), path.decode()[:80].split("?")[0]), flush=True)
    kr, kw = await asyncio.open_connection("127.0.0.1", 2501)
    kw.write(b" ".join((method, path, ver)) + b"\r\n" + rest)
    await kw.drain()
    await asyncio.gather(pipe(cr, kw), pipe(kr, cw))


async def main():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    srv = await asyncio.start_server(handle, "127.0.0.1", PORT, ssl=ctx)
    print("%.3f listening on 127.0.0.1:%d prefix %r" % (time.time(), PORT, PREFIX), flush=True)
    async with srv:
        await srv.serve_forever()


asyncio.run(main())
