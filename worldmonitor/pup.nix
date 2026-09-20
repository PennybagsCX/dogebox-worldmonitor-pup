{ pkgs ? import <nixpkgs> {} }:

# WorldMonitor pup — real-time global intelligence dashboard (koala73/worldmonitor).
#
# One container, four services (same network namespace, loopback-only mesh):
#   web        /bin/wm-web          nginx  — static SPA + SPA fallback + /api/ proxy
#                                     on ''${DBX_PUP_IP}:9100 (the single webUI expose)
#   api        /bin/wm-api          node local-api-server.mjs on 127.0.0.1:46123
#                                     (default-deny: every route needs LOCAL_API_TOKEN,
#                                     injected by nginx as X-WorldMonitor-Local-Token)
#   redis      /bin/wm-redis        redis-server --requirepass on 127.0.0.1:6379
#   redisrest  /bin/wm-redis-rest   upstream docker/redis-rest-proxy.mjs (Upstash REST
#                                     protocol) on 127.0.0.1:8079, backed by redis
#
# Same-origin model: the browser only ever talks to the web expose; nginx proxies
# /api/* to loopback. No ports or URLs are baked into the built app (dogeboxd
# assigns the host proxy port at install time — drc20fun lesson).
#
# The app tree (html/ app/ conf/ redis-rest/) ships as a prebuilt tarball
# attached to a PennybagsCX/worldmonitor release, built by scripts/build-dist.sh
# in that repo — a verbatim transcription of upstream's root Dockerfile stages.
# Never build node_modules on the box.

let
  releaseTag = "v2.10.0-wm1";

  # The dist ships Brotli pre-compressed assets (*.br, >1KB) and no .gz, so
  # serve them with brotli_static (upstream's Alpine image only has gzip_static
  # and eats the 20–30% penalty; nixpkgs ships the module). If this module ever
  # fails to build on aarch64, drop the override AND the `brotli_static on;`
  # line in nginxConf — the app serves uncompressed either way.
  nginxPkg = pkgs.nginx.override { modules = [ pkgs.nginxModules.brotli ]; };

  releaseTarball = pkgs.fetchurl {
    # Prebuilt full-stack bundle — GitHub release asset on the fork.
    # Built from koala73/worldmonitor v2.10.0 by scripts/build-dist.sh.
    url = "https://github.com/PennybagsCX/worldmonitor/releases/download/${releaseTag}/worldmonitor-fullstack-${releaseTag}.tar.gz";
    sha256 = "c819f8be945b7f1e112a0c9529d00af28ddc6e990516f84483ef3f33ce5ab6c5";
  };

  # Absolute store paths everywhere — the minimal pup container has no /usr/bin
  # (library-pup v0.0.8 lesson).

  # ── First-boot bootstrap, sourced by every service script ─────────────────
  # Race-safe: 4 services boot concurrently, so both the secrets file and the
  # app extraction are guarded by atomic mkdir locks; losers poll for the
  # artifact. Secrets land in /storage/config/secrets.env (chmod 600) and are
  # sourced by each service. The optional operator-keys file
  # (/storage/config/worldmonitor.env) is created as a commented template;
  # values there feed the SERVER-side provider chain (compose-env equivalent).
  bootstrap = pkgs.writeText "wm-bootstrap.sh" ''
    CFG=/storage/config
    APP=/storage/wm
    mkdir -p "$CFG"

    if [ ! -f "$CFG/secrets.env" ]; then
      if mkdir "$CFG/.secrets-lock" 2>/dev/null; then
        umask 077
        {
          echo "RELAY_SHARED_SECRET=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
          echo "REDIS_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
          echo "REDIS_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
          echo "LOCAL_API_TOKEN=$(${pkgs.openssl}/bin/openssl rand -hex 32)"
        } > "$CFG/secrets.env.tmp"
        mv "$CFG/secrets.env.tmp" "$CFG/secrets.env"
        rmdir "$CFG/.secrets-lock"
      else
        while [ ! -f "$CFG/secrets.env" ]; do sleep 0.5; done
      fi
    fi

    if [ ! -f "$CFG/worldmonitor.env" ]; then
      {
        echo "# WorldMonitor operator keys (server-side chain — compose-env equivalent)."
        echo "# Uncomment and fill to enable key-gated layers for ALL users of this box."
        echo "# Per-user keys belong in the app's own Settings page instead."
        echo "# GROQ_API_KEY="
        echo "# OPENROUTER_API_KEY="
        echo "# LLM_API_URL=            # any OpenAI-compatible endpoint (Ollama: http://192.168.x.x:11434/v1/chat/completions)"
        echo "# LLM_API_KEY="
        echo "# LLM_MODEL="
        echo "# FINNHUB_API_KEY="
        echo "# EIA_API_KEY="
        echo "# FRED_API_KEY="
        echo "# ACLED_EMAIL="
        echo "# ACLED_PASSWORD="
        echo "# AISSTREAM_API_KEY="
        echo "# NASA_FIRMS_API_KEY="
        echo "# AVIATIONSTACK_API="
        echo "# CLOUDFLARE_API_TOKEN="
      } > "$CFG/worldmonitor.env"
    fi

    if [ ! -f "$APP/.release-${releaseTag}" ]; then
      if mkdir "$CFG/.app-lock" 2>/dev/null; then
        ${pkgs.coreutils}/bin/rm -rf "$APP"
        ${pkgs.coreutils}/bin/mkdir -p "$APP"
        # --exclude: the tarball was built on macOS; strip AppleDouble ._ junk.
        # --use-compress-program: no gzip on the minimal container PATH.
        ${pkgs.gnutar}/bin/tar --use-compress-program="${pkgs.gzip}/bin/gzip" -xf ${releaseTarball} -C "$APP" --exclude='./._*' --exclude='._*' --no-same-owner
        ${pkgs.coreutils}/bin/mv "$APP"/rootfs/* "$APP"/
        ${pkgs.coreutils}/bin/rmdir "$APP/rootfs"
        ${pkgs.coreutils}/bin/touch "$APP/.release-${releaseTag}"
        ${pkgs.coreutils}/bin/chmod -R u+w "$APP"
        rmdir "$CFG/.app-lock"
      else
        while [ ! -f "$APP/.release-${releaseTag}" ]; do sleep 0.5; done
      fi
    fi
  '';

  # ── nginx config: upstream docker/nginx.conf (v2.10.0) adapted for the pup.
  # Static paths resolved at build time; runtime secrets via envsubst (web-run).
  nginxConf = pkgs.writeText "worldmonitor-nginx.conf.template" ''
    worker_processes auto;
    error_log /dev/stderr warn;
    pid /tmp/nginx.pid;

    events {
      worker_connections 1024;
    }

    http {
      include       ${nginxPkg}/conf/mime.types;
      default_type  application/octet-stream;

      log_format main '$remote_addr - [$time_local] "$request" $status $body_bytes_sent';
      access_log /dev/stdout main;

      sendfile on;
      tcp_nopush on;
      keepalive_timeout 65;

      gzip_static on;
      brotli_static on;
      gzip on;
      gzip_comp_level 5;
      gzip_min_length 1024;
      gzip_vary on;
      gzip_types application/json application/javascript text/css text/plain application/xml text/xml image/svg+xml;

      client_body_temp_path /tmp/nginx-client-body;
      proxy_temp_path /tmp/nginx-proxy;
      fastcgi_temp_path /tmp/nginx-fastcgi;
      uwsgi_temp_path /tmp/nginx-uwsgi;
      scgi_temp_path /tmp/nginx-scgi;

      server {
        listen ''${WM_LISTEN_ADDR};
        root /storage/wm/html;
        # The Vite build renames the SPA entry index.html -> dashboard.html
        index dashboard.html;

        location /assets/ {
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          add_header Origin-Agent-Cluster "?1" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Cache-Control "public, max-age=31536000, immutable";
          try_files $uri =404;
        }

        location /map-styles/ {
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          add_header Origin-Agent-Cluster "?1" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Cache-Control "public, max-age=31536000, immutable";
          try_files $uri =404;
        }

        location /data/ {
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          add_header Origin-Agent-Cluster "?1" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Cache-Control "public, max-age=31536000, immutable";
          try_files $uri =404;
        }

        location /textures/ {
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          add_header Origin-Agent-Cluster "?1" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Cache-Control "public, max-age=31536000, immutable";
          try_files $uri =404;
        }

        # API proxy → Node.js local-api-server (loopback only)
        location /api/ {
          add_header Origin-Agent-Cluster "?1" always;
          proxy_pass http://127.0.0.1:''${LOCAL_API_PORT};
          proxy_http_version 1.1;
          proxy_set_header Host $host;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Origin http://localhost;
          # The sidecar is default-deny without this transport token.
          proxy_set_header X-WorldMonitor-Local-Token "''${LOCAL_API_TOKEN}";
          proxy_read_timeout 120s;
          proxy_send_timeout 120s;
        }

        # SPA fallback — all other routes serve dashboard.html (the renamed entry)
        location / {
          add_header X-Content-Type-Options "nosniff" always;
          add_header X-Frame-Options "SAMEORIGIN" always;
          add_header Referrer-Policy "strict-origin-when-cross-origin" always;
          add_header Origin-Agent-Cluster "?1" always;
          add_header X-XSS-Protection "1; mode=block" always;
          add_header Content-Security-Policy "default-src 'self'; connect-src 'self' https: wss: blob: data:; img-src 'self' data: blob: https:; style-src 'self' 'unsafe-inline'; script-src 'self' 'strict-dynamic' 'nonce-wm-static-bootstrap' 'sha256-+SFBjfmi2XfnyAT3POBxf6JIKYDcNXtllPclOcaNBI0=' 'sha256-8+wzVMOmlqUDa/kK12C8s5ulmSbmXZ1nd8SPraxR5w4=' 'sha256-Jgh3W4Qj3HWZPVSti0C073yuiaz611LO8OZRUCsN0x8=' 'sha256-poASOgCpDRg0EgCVs4OgMll/wGWeWV0hnPm8sbWfHn8=' 'sha256-lKs3SvF31U/ZDoqILsGd1YpSh0LSw9Xlo0hNHcX8Wqk=' 'sha256-IX5bYpcr65BhIu6axni7a0m22G+wVO6bX61f7JwIUFw=' 'sha256-qFSeUweakvZf90cHXTBJlSgrlZOixT+/ph7kpKeRYL0=' 'sha256-r9xS8+gjLrjT4DJU5lt/WJQe6pg5FjJc8ahnW7oDM54=' 'wasm-unsafe-eval'; worker-src 'self' blob:; font-src 'self' data:; media-src 'self' data: blob: https:; frame-src 'self' https://www.worldmonitor.app https://worldmonitor.app https://tech.worldmonitor.app https://finance.worldmonitor.app https://commodity.worldmonitor.app https://happy.worldmonitor.app https://energy.worldmonitor.app https://www.youtube.com https://www.youtube-nocookie.com https://www.google.com https://webcams.windy.com https://challenges.cloudflare.com https://*.clerk.accounts.dev https://clerk.worldmonitor.app https://vercel.live https://*.vercel.app https://*.dodopayments.com https://checkout.dodopayments.com https://test.checkout.dodopayments.com https://*.hs.dodopayments.com https://*.custom.hs.dodopayments.com https://pay.google.com https://hooks.stripe.com https://js.stripe.com; frame-ancestors 'self'; base-uri 'self'; object-src 'none'; form-action 'self' https://api.worldmonitor.app" always;
          add_header Cache-Control "no-cache, no-store, must-revalidate";
          add_header Permissions-Policy "storage-access=(self \"https://www.youtube.com\" \"https://youtube.com\"), tools=(self)";
          try_files $uri $uri/ /dashboard.html;
        }
      }
    }
  '';

  # ── Service scripts ─────────────────────────────────────────────────────────
  # Each: PATH export → bootstrap (secrets + app tree) → wait for deps →
  # foreground exec. dogeboxd is the supervisor (no ordering guarantees
  # between services, hence the wait loops).

  web = pkgs.writeScriptBin "wm-web" ''
    #!${pkgs.stdenv.shell}
    export PATH=${pkgs.coreutils}/bin:${pkgs.gettext}/bin:$PATH
    . ${bootstrap}
    . /storage/config/secrets.env
    export WM_LISTEN_ADDR="''${DBX_PUP_IP:-0.0.0.0}:9100"
    mkdir -p /tmp/nginx-client-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
    ${pkgs.gettext}/bin/envsubst '$WM_LISTEN_ADDR $LOCAL_API_PORT $LOCAL_API_TOKEN' < ${nginxConf} > /tmp/nginx.conf
    exec ${nginxPkg}/bin/nginx -c /tmp/nginx.conf -g "daemon off;"
  '';

  api = pkgs.writeScriptBin "wm-api" ''
    #!${pkgs.stdenv.shell}
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:$PATH
    . ${bootstrap}
    . /storage/config/secrets.env
    # Optional operator keys (server-side provider chain) — compose-env equivalent
    if [ -f /storage/config/worldmonitor.env ]; then
      set -a
      . /storage/config/worldmonitor.env
      set +a
    fi
    export UPSTASH_REDIS_REST_URL="http://127.0.0.1:8079"
    export UPSTASH_REDIS_REST_TOKEN="$REDIS_TOKEN"
    export LOCAL_API_PORT="46123"
    export LOCAL_API_MODE="docker"
    export LOCAL_API_CLOUD_FALLBACK="false"
    export WS_RELAY_URL="http://127.0.0.1:3004"
    export RELAY_SHARED_SECRET="$RELAY_SHARED_SECRET"
    # Wait for the REST proxy (any HTTP answer means it is up)
    until ${pkgs.curl}/bin/curl -s -o /dev/null http://127.0.0.1:8079; do sleep 1; done
    cd /storage/wm/app
    # Heap capped for the NanoPC-T6 (RK3588)
    exec ${pkgs.nodejs}/bin/node --max-old-space-size=384 local-api-server.mjs
  '';

  redis = pkgs.writeScriptBin "wm-redis" ''
    #!${pkgs.stdenv.shell}
    export PATH=${pkgs.coreutils}/bin:$PATH
    . ${bootstrap}
    . /storage/config/secrets.env
    mkdir -p /storage/redis
    exec ${pkgs.redis}/bin/redis-server \
      --bind 127.0.0.1 --port 6379 \
      --requirepass "$REDIS_PASSWORD" \
      --maxmemory 256mb --maxmemory-policy allkeys-lru \
      --dir /storage/redis --daemonize no
  '';

  redisrest = pkgs.writeScriptBin "wm-redis-rest" ''
    #!${pkgs.stdenv.shell}
    export PATH=${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:$PATH
    . ${bootstrap}
    . /storage/config/secrets.env
    until ${pkgs.redis}/bin/redis-cli -h 127.0.0.1 -p 6379 -a "$REDIS_PASSWORD" --no-auth-warning ping 2>/dev/null | grep -q PONG; do sleep 1; done
    export SRH_TOKEN="$REDIS_TOKEN"
    export SRH_CONNECTION_STRING="redis://:''${REDIS_PASSWORD}@127.0.0.1:6379"
    export PORT="8079"
    cd /storage/wm/redis-rest
    exec ${pkgs.nodejs}/bin/node redis-rest-proxy.mjs
  '';

in
{
  inherit web api redis redisrest;
}
