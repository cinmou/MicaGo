# Remote Access with Cloudflare Tunnel

This guide shows how to reach your Mac from **outside your home network** using
your **own domain** and **Cloudflare Tunnel**.

> ℹ️ **Cloudflare Tunnel is external and optional.** MicaGo does **not** bundle,
> install, or manage Cloudflare. You set up and run the tunnel yourself with
> your own Cloudflare account and domain. If you prefer a different reverse
> proxy or tunnel, the same idea applies — MicaGo just needs a public HTTPS URL
> that forwards to the local server.

## Why a tunnel?

Your Mac's server normally listens only on your home network. A tunnel gives you
a stable public HTTPS address (e.g. `https://go.example.com`) that securely
forwards traffic to the server running on your Mac — without opening ports on
your router.

## Recommended architecture

```
Android client
  -> https://go.example.com            (your domain, HTTPS)
  -> Cloudflare Tunnel                 (Cloudflare's edge)
  -> cloudflared on your Mac           (the tunnel client you run)
  -> http://127.0.0.1:<PORT>           (the MicaGo server on your Mac)
```

Your token still protects every request, end to end. The tunnel only moves
traffic; it does not replace authentication.

## Step 1 — Get a domain

Use a domain you own, or buy one (from Cloudflare Registrar or any registrar).
In the examples below, replace `go.example.com` with your own hostname.

## Step 2 — Add the domain to Cloudflare

1. Create a free Cloudflare account.
2. Add your domain as a **site** in the Cloudflare dashboard.
3. Update your domain's nameservers to the ones Cloudflare gives you (if your
   domain is registered elsewhere). Wait until Cloudflare shows the domain as
   **Active**.

## Step 3 — Install cloudflared on macOS

The easiest way is Homebrew:

```bash
brew install cloudflared
```

(You can also download `cloudflared` from Cloudflare's website.)

## Step 4 — Log in

```bash
cloudflared tunnel login
```

A browser opens; pick the domain you added. This authorizes `cloudflared` and
stores a certificate under `~/.cloudflared/`.

## Step 5 — Create a named tunnel

```bash
cloudflared tunnel create micago-server
```

This prints a **tunnel ID** and writes a credentials file to
`~/.cloudflared/<tunnel-id>.json`. Note the tunnel ID; you'll reference it next.

## Step 6 — Route your hostname to the tunnel

```bash
cloudflared tunnel route dns micago-server go.example.com
```

This creates the DNS record that points `go.example.com` at your tunnel.

## Step 7 — Write the config file

Create `~/.cloudflared/config.yml`. Replace `<you>`, `<tunnel-id>`, and
`<PORT>` with your values (the default MicaGo port is `3000`, but use whatever
the Mac app shows):

```yaml
tunnel: micago-server
credentials-file: /Users/<you>/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: go.example.com
    service: http://127.0.0.1:<PORT>
  - service: http_status:404
```

The first `ingress` rule forwards your hostname to the local MicaGo server. The
final `http_status:404` rule is required as a catch‑all.

## Step 8 — Run the tunnel

```bash
cloudflared tunnel run micago-server
```

Leave this running while you test. You should see it connect to Cloudflare's
edge.

### Optional: install as a background service

If you want the tunnel to start automatically and keep running, you can install
it as a service. **This is optional** — running it manually (Step 8) is fine for
testing:

```bash
cloudflared service install
```

## Step 9 — Enter the public URL in the MicaGo Mac app

1. In the Mac app, find the **Connections** / connection‑endpoints area.
2. Set the **Public URL** to the bare origin:

   ```
   https://go.example.com
   ```

   Use the **origin only** — no trailing path, no `/api`, no `/ws`.

## Step 10 — Validate the public URL

In the Mac app, run **Validate Public URL** (the "check" action). MicaGo asks
its own server to confirm that the public URL reaches **this** Mac and that the
token works.

### What success looks like

- The public URL is **reachable**.
- The **auth check passes** (the token is accepted).
- The connection details may show a **provider hint** of Cloudflare.
- Your **Android client can connect over mobile data** using
  `https://go.example.com`.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Validate fails, but local works | Tunnel not forwarding to the right place | Check `service:` in `config.yml` points to `http://127.0.0.1:<PORT>` with the **correct port** shown in the Mac app. |
| Connection refused / 502 from the tunnel | Server bound to the wrong address, or not running | Make sure the MicaGo server is running and listening on the port your `config.yml` forwards to. |
| `go.example.com` does not resolve | Hostname not routed in Cloudflare | Re‑run `cloudflared tunnel route dns micago-server go.example.com` and confirm the DNS record exists. |
| Everything 401 (Unauthorized) | Wrong or stale token | Re‑copy the token from the Mac app; make sure devices use the same token. |
| Validate fails right after starting | Tunnel not running | Run `cloudflared tunnel run micago-server` and try again. |
| Works locally, fails publicly with a path error | You pasted a URL **with a path** | Use the bare origin `https://go.example.com`, not `https://go.example.com/api` or `.../ws`. |
| WebSocket won't connect but REST works | Proxy not passing WebSocket upgrades, or wrong scheme | Cloudflare passes WebSockets by default; confirm the client uses `wss://go.example.com/ws` (HTTPS → `wss`). Make sure the tunnel is running. |
| Random outside testers could reach it | Public URL + token is all that's needed | Keep the token secret; rotate it if exposed. Consider Cloudflare Access for an extra gate (optional, advanced). |

> ⚠️ Once your server is public, anyone with the URL **and** the token can reach
> it. Treat the token like a password and rotate it if you suspect a leak.
