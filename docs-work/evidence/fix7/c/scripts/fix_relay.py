p = r"C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface\tests\kismet_e2e.sh"
s = open(p, encoding="utf-8", newline="").read()
start = s.index("def serve(client):\n")
end = s.index("    upstream = socket.create_connection((\"127.0.0.1\", 2501))\n")
new = r'''def serve(client):
    head = b""
    while b"\r\n\r\n" not in head:
        data = client.recv(65536)
        if not data:
            return client.close()
        head += data
    count[0] += 1
    with open(log, "ab") as f:
        f.write(b"== connection %d\n" % count[0] + head.split(b"\r\n\r\n")[0].replace(b"\r", b"") + b"\n")
'''
s = s[:start] + new + s[end:]
open(p, "w", encoding="utf-8", newline="").write(s)
print("ok")
