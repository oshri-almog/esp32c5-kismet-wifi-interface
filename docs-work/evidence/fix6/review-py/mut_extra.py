import sys
sys.argv = [sys.argv[0]] + sys.argv[1:]
exec(open("/tmp/rvpy/mut.py").read().split("only = sys.argv[1:]")[0])
OLD8 = ('                self.capturing = True\n'
        '                self._status("%s capturing" % self.current_port, "capturing")\n'
        '            for record in records:\n'
        '                self.packets += 1\n'
        '                self.on_packet(*record)\n')
NEW8 = ('                self.capturing = True\n'
        '            for record in records:\n'
        '                self.packets += 1\n'
        '                self.on_packet(*record)\n'
        '            if self.capturing and self._last_status != "%s capturing" % self.current_port:\n'
        '                self._status("%s capturing" % self.current_port, "capturing")\n')
MUTS[:] = [("B8", "esp32c5_kismet/board.py", OLD8, NEW8, ["board", "v3"])]
exec("only = sys.argv[1:]" + open("/tmp/rvpy/mut.py").read().split("only = sys.argv[1:]")[1])
