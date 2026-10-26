"""Local fixture server for the baseline web tasks.

Serves fixtures/web on 127.0.0.1:8899 and appends every interesting request
(form submissions, /ref/N and /inline/N clicks, /result pings) to state/web.log
as JSON lines, so task checks can verify what the agent actually did.
"""

import html
import json
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).parent
WEB = ROOT / "fixtures" / "web"
LOG = ROOT / "state" / "web.log"


def record(kind: str, **data) -> None:
    with LOG.open("a") as f:
        f.write(json.dumps({"t": time.time(), "kind": kind, **data}) + "\n")


# Eval task L10: a small orders app behind a login, 3 pages of 8 orders. Deterministic, so checks can recompute.
APP_USER, APP_PASSWORD, APP_SESSION = "ada", "lovelace-1815", "s-7f3a91"
_names = ["Ana", "Ben", "Cho", "Dev", "Eli", "Fay", "Gus", "Hal"]
ORDERS = [{"id": 1000 + i, "customer": _names[i % 8] + " " + "XYZW"[i % 4] + ".",
           "status": ["paid", "refunded", "pending", "paid", "refunded", "paid"][(i * 5) % 6],
           "amount": round(12.5 + (i * 37 % 91) + (i % 3) * 0.25, 2)} for i in range(24)]
PAGE_SIZE = 8


def refunded_total() -> float:
    return round(sum(o["amount"] for o in ORDERS if o["status"] == "refunded"), 2)


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(WEB), **kwargs)

    def _page(self, body: str) -> None:
        data = f"<!doctype html><html><body>{body}</body></html>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    WIZARD = {
        1: ("Step 1 of 3: Contact", [("name", "Full name"), ("email", "E-mail")]),
        2: ("Step 2 of 3: Address", [("address", "Street address"), ("city", "City"), ("zip", "ZIP code"), ("country", None)]),
        3: ("Step 3 of 3: Plan", [("plan", None), ("newsletter", None), ("comments", None)]),
    }

    def _wizard(self, step: int, carried: dict) -> None:
        title, fields = self.WIZARD[step]
        hidden = "".join(f'<input type="hidden" name="{k}" value="{html.escape(v[0], quote=True)}">' for k, v in carried.items())
        inputs = []
        for name, label in fields:
            if name == "country":
                opts = "".join(f"<option>{c}</option>" for c in ["Canada", "Mexico", "United Kingdom", "United States"])
                inputs.append(f'<p><label>Country <select name="country"><option value="">Choose…</option>{opts}</select></label></p>')
            elif name == "plan":
                inputs.append("<fieldset><legend>Plan</legend>" + "".join(
                    f'<p><label><input type="radio" name="plan" value="{p.lower()}"> {p}</label></p>' for p in ["Basic", "Pro", "Team"]) + "</fieldset>")
            elif name == "newsletter":
                inputs.append('<p><label><input type="checkbox" name="newsletter" value="yes"> Send me the newsletter</label></p>')
            elif name == "comments":
                inputs.append('<p><label>Comments <textarea name="comments"></textarea></label></p>')
            else:
                inputs.append(f'<p><label>{label} <input name="{name}"></label></p>')
        action = f"/wizard/{step + 1}" if step < 3 else "/wizard/done"
        button = "Next" if step < 3 else "Finish signup"
        self._page(f"<h1>Signup</h1><h2>{title}</h2><form method='post' action='{action}'>{hidden}{''.join(inputs)}"
                   f"<p><button>{button}</button></p></form>")

    @property
    def ua(self) -> str:
        return self.headers.get("User-Agent", "")

    def _logged_in(self) -> bool:
        return f"session={APP_SESSION}" in (self.headers.get("Cookie") or "")

    def _orders(self, page: int) -> None:
        pages = (len(ORDERS) + PAGE_SIZE - 1) // PAGE_SIZE
        page = max(1, min(page, pages))
        rows = "".join(f"<tr><td>{o['id']}</td><td>{html.escape(o['customer'])}</td><td>{o['status']}</td>"
                       f"<td>${o['amount']:.2f}</td></tr>" for o in ORDERS[(page - 1) * PAGE_SIZE:page * PAGE_SIZE])
        nav = (f"<a href='/app/orders?page={page - 1}'>Previous</a> " if page > 1 else "") + f"Page {page} of {pages}" + \
              (f" <a href='/app/orders?page={page + 1}'>Next</a>" if page < pages else "")
        record("orders", page=page, ua=self.ua)
        self._page(f"<h1>Orders</h1><table border='1'><tr><th>Order</th><th>Customer</th><th>Status</th><th>Amount</th></tr>"
                   f"{rows}</table><p>{nav}</p>")

    def end_headers(self):
        # Every page view must reach this server (tasks check which browser fetched it), never a browser's cache.
        self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/app/login":
            return self._page("<h1>Sign in</h1><form method='post' action='/app/login'>"
                              "<p><label>Username <input name='user'></label></p>"
                              "<p><label>Password <input name='password' type='password'></label></p>"
                              "<p><button>Sign in</button></p></form>")
        if url.path == "/app/orders":
            if not self._logged_in():
                self.send_response(302)
                self.send_header("Location", "/app/login")
                self.end_headers()
                return
            return self._orders(int(parse_qs(url.query).get("page", ["1"])[0] or 1))
        if url.path.endswith(".html"):
            record("page", path=url.path, ua=self.ua)
        if url.path == "/wizard/1":
            return self._wizard(1, {})
        if url.path.startswith(("/ref/", "/inline/")):
            record("link", path=url.path, ua=self.ua)
            return self._page(f"<h1>You opened {url.path}</h1>")
        if url.path == "/result":
            record("result", ua=self.ua, **{k: v[0] for k, v in parse_qs(url.query).items()})
            return self._page("ok")
        return super().do_GET()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        fields = parse_qs(self.rfile.read(length).decode(), keep_blank_values=True)
        url = urlparse(self.path)
        if url.path == "/app/login":
            ok = fields.get("user", [""])[0] == APP_USER and fields.get("password", [""])[0] == APP_PASSWORD
            record("login", ok=ok, ua=self.ua)
            if not ok:
                return self._page("<h1>Sign in</h1><p>Wrong username or password.</p><p><a href='/app/login'>Try again</a></p>")
            self.send_response(302)
            self.send_header("Set-Cookie", f"session={APP_SESSION}; Path=/")
            self.send_header("Location", "/app/orders?page=1")
            self.end_headers()
            return
        if url.path in ("/wizard/2", "/wizard/3"):
            return self._wizard(int(url.path[-1]), fields)
        if url.path == "/wizard/done":
            record("wizard", fields=fields, ua=self.ua)
            return self._page("<h1>Thanks!</h1><p>Your signup is complete.</p>")
        record("submit", path=self.path, fields=fields, ua=self.ua)
        self._page("<h1>Order received</h1><pre>" + json.dumps(fields, indent=2) + "</pre>")

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    LOG.parent.mkdir(exist_ok=True)
    ThreadingHTTPServer(("127.0.0.1", 8899), Handler).serve_forever()
