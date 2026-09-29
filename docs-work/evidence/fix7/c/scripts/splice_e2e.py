p = r"C:\Users\oshria\OneDrive\Documents\GitHub\esp32c5-kismet-wifi-interface\tests\kismet_e2e.sh"
sec = open("e2e_remote_section.sh", encoding="utf-8").read()
old_routes = '''echo "   this machine has $(cat /proc/net/route 2>/dev/null | tail -n +2 | wc -l) IPv4 routes in its main table; libwebsockets warned when all its tables held more than 40"'''
new_routes = '''echo "   routes here, all tables: $(ip route show table all 2>/dev/null | wc -l) IPv4, $(ip -6 route show table all 2>/dev/null | wc -l) IPv6 (the warnings came with more than 40)"'''
assert old_routes in sec
sec = sec.replace(old_routes, new_routes)
sec = sec.replace('''finish_case remote
report remote
sed 's/^/   helper: /' "$WORK/helper-remote.log"
''', '''finish_case remote
kill "$RPID" 2>/dev/null; wait "$RPID" 2>/dev/null; RPID=
report remote
sed 's/^/   helper: /' "$WORK/helper-remote.log"
''')
s = open(p, encoding="utf-8", newline="").read()
start = s.index('echo "== remote capture: kismet_cap_esp32c5 --connect over the websocket')
endmark = '''grep -v "_lws_smd_msg_send" "$WORK/helper-remote.log" | sed 's/^/   helper: /'
'''
end = s.index(endmark) + len(endmark)
s = s[:start] + sec + s[end:]
open(p, "w", encoding="utf-8", newline="").write(s)
print("ok")
