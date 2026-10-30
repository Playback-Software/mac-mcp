#!/usr/bin/env python3
import json, socket, os, sys
SOCK = os.path.expanduser("~/Library/Application Support/MacMCP/mcp.sock")
def session(lines, expect):
    s = socket.socket(socket.AF_UNIX); s.connect(SOCK); s.settimeout(10)
    f = s.makefile("rwb")
    out = []
    for l in lines:
        f.write((l if isinstance(l, str) else json.dumps(l)).encode() + b"\n"); f.flush()
    for _ in range(expect):
        try: out.append(json.loads(f.readline()))
        except Exception as e: out.append({"_error": str(e)}); break
    s.close(); return out
init = {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"golden","version":"1"}}}
cases = {
 "initialize_2025-11-25": ([init], 1),
 "initialize_2024-11-05": ([{**init, "params": {**init["params"], "protocolVersion": "2024-11-05"}}], 1),
 "initialize_unknown_version": ([{**init, "params": {**init["params"], "protocolVersion": "1999-01-01"}}], 1),
 "tools_list": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"tools/list"}], 2),
 "ping": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"ping"}], 2),
 "unknown_method": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"no/such"}], 2),
 "unknown_tool": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"nope","arguments":{}}}], 2),
 "call_doctor": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":"str-id","method":"tools/call","params":{"name":"mac_doctor","arguments":{}}}], 2),
 "parse_error": ([init, "{not json"], 2),
 "call_before_initialize": ([{"jsonrpc":"2.0","id":5,"method":"tools/list"}], 1),
 "missing_params": ([init, {"jsonrpc":"2.0","method":"notifications/initialized"}, {"jsonrpc":"2.0","id":2,"method":"tools/call"}], 2),
}
res = {k: session(*v) for k, v in cases.items()}
json.dump(res, open(sys.argv[1], "w"), indent=1)
for k, v in res.items():
    last = v[-1]
    print(f"{k:28s}", json.dumps(last)[:230])
