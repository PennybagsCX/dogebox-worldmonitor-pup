# WorldMonitor — DogeBox pup

[WorldMonitor](https://github.com/koala73/worldmonitor) (AGPL-3.0) packaged as a DogeBox pup: a real-time global intelligence dashboard — news aggregation, geopolitical monitoring, markets, infrastructure tracking — served from your own box.

**Free and open source. Works with zero API keys.** Optional keys are always user-supplied and never bundled.

## Install (dashboard, ~5 min)

1. Dashboard → **Pup Store** → **Manage Sources** → **Add Source** → paste `https://github.com/PennybagsCX/dogebox-worldmonitor-pup.git`
2. Refresh the store → find **WorldMonitor** → **Install**
3. Wait for the nix build (~5–15 min first install: downloads the prebuilt app tarball + nix deps; nothing is compiled from source on the box)
4. Note the mapped host port (10000-range) on the new pup card → open it

## What works with zero keys

News feeds, live news video, earthquakes, weather alerts, natural events, conflict data (GDELT), prediction markets, crypto, US spending, submarine cables, cyber threats, country instability index, browser-local AI briefs (ONNX model runs in your browser — enable **Browser Local Model** in Settings).

Hidden until a key is added: Finnhub equities, EIA oil, ACLED conflict, AISStream vessels, NASA FIRMS fires, Cloudflare Radar outages, AviationStack flights.

## Bringing your own keys

Two paths, pick per need:

| Path | Where | Applies to | Best for |
|---|---|---|---|
| **Per-user (recommended)** | App **Settings** page, in your browser | AI providers: Groq / OpenRouter / any OpenAI-compatible endpoint (Ollama, vLLM, llama.cpp) | Personal keys stay in your browser (localStorage), never on the box; each household member uses their own |
| **Box-wide operator keys** | `worldmonitor.env` on the box | Server-side provider chain + data-source layers (see below) | One config for the whole household; enables key-gated panels for everyone |

**Box-wide operator keys**: SSH in, edit `/opt/dogebox/pups/storage/<pup-hash>/config/worldmonitor.env` (a commented template is created on first boot), then restart the pup (disable → enable on the pup card). Available keys:

```
GROQ_API_KEY, OPENROUTER_API_KEY, LLM_API_URL, LLM_API_KEY, LLM_MODEL
FINNHUB_API_KEY, EIA_API_KEY, FRED_API_KEY, ACLED_EMAIL, ACLED_PASSWORD,
AISSTREAM_API_KEY, NASA_FIRMS_API_KEY, AVIATIONSTACK_API, CLOUDFLARE_API_TOKEN
```

**Ollama users**: point the custom-URL field (per-user) or `LLM_API_URL` (operator) at `http://<lan-host>:11434/v1/chat/completions`; on the Ollama host set `OLLAMA_HOST=0.0.0.0` and `OLLAMA_ORIGINS` to include the pup's origin (`http://10.0.0.98:<port>`) so browser-direct calls pass CORS.

**Key-gated layers** (operator path) appear in the dashboard once the corresponding key is set; without keys those layers are hidden — that is by design, not a fault.

## Architecture (one container, 4 services)

| Service | What | Binds |
|---|---|---|
| web | nginx — static SPA + SPA fallback + `/api/` proxy | `$DBX_PUP_IP:9100` (the single webUI expose) |
| api | Node `local-api-server.mjs` (upstream sidecar, 50+ routes) | 127.0.0.1:46123 |
| redis | redis-server (requirepass, 256MB LRU cap) | 127.0.0.1:6379 |
| redisrest | upstream redis-rest proxy (Upstash REST protocol) | 127.0.0.1:8079 |

- Same-origin model: the browser only ever talks to the web expose; dogeboxd assigns the host proxy port at install — nothing is baked into the build.
- First boot generates `secrets.env` (RELAY_SHARED_SECRET, REDIS_PASSWORD, REDIS_TOKEN, LOCAL_API_TOKEN) into `/storage/config/` (chmod 600, race-safe across the 4 services). Deleting `secrets.env` regenerates on next start.
- The app tree ships as a prebuilt tarball (built on the Mac by `scripts/build-dist.sh` in [the fork](https://github.com/PennybagsCX/worldmonitor), a verbatim transcription of upstream's root Dockerfile) — nothing compiled on the box.
- RAM: ~600–750MB resident (node heap capped at 384MB, redis at 256MB). First-load data warms up over the first minutes; some layers populate as caches fill.

## Operations

```bash
# service state (host):
sudo systemctl status <svc> --machine pup-<hash>
# logs:
sudo journalctl -u <svc> -M pup-<hash> -f     # svc: api | redis | redisrest
# nginx logs are FILES (journald sockets break nginx's /dev/stderr reopen):
sudo less /opt/dogebox/pups/storage/<hash>/config/nginx-error.log
sudo tail -f /opt/dogebox/pups/storage/<hash>/config/nginx-access.log
# wipe config (keeps nothing): rm /storage/config/* — regenerated on restart
```

If the API dies, nginx serves 502s until dogeboxd restarts it; the page recovers on its own. After any reinstall, `sudo chown -R 420:69 /opt/dogebox/pups/storage/<hash>` if the services cannot write their config.

## Releases / development

- Fork: https://github.com/PennybagsCX/worldmonitor (AGPL-3.0; changes vs upstream documented in its README). Release tarballs are attached to fork tags `v<upstream>-wm<N>`.
- Pup version = this manifest's semver, independent of upstream. **Release order matters**: bump `manifest.json` version → commit → THEN tag (the store reads the version from the manifest inside the tag).
- `nixFileSha256` = `shasum -a 256 pup.nix` (plain hex), recomputed on every pup.nix change.
- Release recipe: run `worldmonitor/scripts/build-dist.sh <tag>` on a Mac (node 22+) → `gh release create <tag> <tarball>` on the fork → paste the printed sha256 into `pup.nix` → recompute manifest `nixFileSha256` → bump manifest → commit → tag.

## License

Upstream AGPL-3.0, preserved. The pup wrapper (manifest, pup.nix, nginx adaptation, bootstrap scripts) is published under AGPL-3.0 as well. Source for the exact build: https://github.com/PennybagsCX/worldmonitor
