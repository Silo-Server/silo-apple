# Temporary Silo invitation site

Development hostname used by this prototype:

`res-driving-prospect-thru.trycloudflare.com`

The hostname is an ephemeral Cloudflare Quick Tunnel and is intentionally
referenced only by `Silo.debug.entitlements`. If the tunnel expires, start the
static server and a new tunnel, then update that one debug entitlement value.

```sh
python3 prototypes/server-invitation-site/serve.py
cloudflared tunnel --url http://127.0.0.1:8765 --no-autoupdate
```

Example invitation:

`https://res-driving-prospect-thru.trycloudflare.com/#v=1&action=signup&server=https%3A%2F%2Fmedia.example.com&invite=TESTCODE`

The site contains no analytics, cookies, external scripts, or storage. Its
server process only supplies the required `application/json` MIME type for the
extensionless AASA file.
