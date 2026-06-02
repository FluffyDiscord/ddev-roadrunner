# DDEV RoadRunner Add-on — Implementation Spec (Implementation)

**Source pinned to:** 2026-06-01 · DDEV `v1.25.1` (constraint `>= v1.24.10`) · RoadRunner server `2025.1.14` · `fluffydiscord/roadrunner-symfony-bundle` `v5.0.0` (PHP 8.5+, Symfony 7.4/8).
**Document type:** Implementation. Strategy/ADRs live in [Strategic Blueprint](./01-strategic-blueprint.md).

Every claim about an *external* system carries a citation in [§9](#9-references-external-sources). Design decisions are governed by Assumptions ([§4](#4-assumptions)) and Open Questions ([§5](#5-open-questions)).

> **Architecture: FastCGI (final, Phase-3 verified 2026-06-01).** RoadRunner runs as a **FastCGI backend** on `tcp://0.0.0.0:9000`; **DDEV's nginx fronts it** (`fastcgi_pass 127.0.0.1:9000`), exactly as the user runs RoadRunner in their own projects. Verified end-to-end on local DDEV v1.25.1 + Docker (real Symfony skeleton 7.4 + bundle v5.0.0): RoadRunner's own HTTP-plugin log records the 200s and there are **zero** php-fpm-socket upstream hits — RoadRunner, not php-fpm, serves the app. Facts proven by running it:
> 1. nginx → RoadRunner over FastCGI on :9000 (chain: ddev-router → nginx (TLS, static) → fastcgi_pass → RR → worker → Symfony).
> 2. The daemon must invoke **`/usr/local/bin/rr`** — bare `rr` resolves to the bundle's `vendor/bin/rr` (spiral CLI, no `serve`).
> 3. The bundle must be **registered in `config/bundles.php`** (the Flex recipe does it; skipped non-interactively → 500 `…\WorkerRegistry`).
> 4. **The nginx override is a markerless `.ddev/nginx_full/nginx-site.conf` shipped as a `project_file`** — a copy of DDEV's own site config with the app's PHP `fastcgi_pass` pointed at `127.0.0.1:9000`. DDEV respects any `nginx_full/nginx-site.conf` that lacks its generated-file marker and never regenerates it, so the routing is stable across restarts with **no runtime patching** (verified to hold across the rebuild restart + repeated restarts). A `removal_action` deletes it on uninstall (markerless files are not auto-removed), after which DDEV regenerates its php-fpm default. *(An earlier iteration used a `post-start` sed-hook under the false belief that DDEV regenerates markerless overrides; that "regeneration" was actually our own override file carrying DDEV's marker **token inside a comment**, which trips DDEV's substring detection — never write that token into the override.)*
> 5. **The add-on does not copy or manage `.rr.yaml`** — RoadRunner reads the project's own bind-mounted `.rr.yaml`, which must use **`http.fcgi`** (not `http.address`). `example.rr.yaml` is the reference.

---

## 1. Scope & component model

Components: the manifest (`install.yaml`), the DDEV config overlay (`config.roadrunner.yaml`), the nginx override (`nginx_full/nginx-site.conf`), the image fragment (`web-build/Dockerfile.roadrunner`), and the custom command (`commands/web/rr`). `.rr.yaml` is **not** an add-on-managed file (the project owns it). The nginx override **is** add-on-managed but markerless (so DDEV won't regenerate it); a `removal_action` cleans it up. Phase-2 floors (≥5 anti-patterns; ≥5 "unit"/static + ≥3 integration tests) apply to the add-on as a whole.

## 2. Repository layout

```
ddev-roadrunner/
├── install.yaml                          # add-on manifest (NOT a project_file)
├── config.roadrunner.yaml                # project_file → .ddev/   (#ddev-generated): nginx-fpm + RR FastCGI daemon
├── nginx_full/nginx-site.conf            # project_file → .ddev/nginx_full/ (MARKERLESS): nginx → RoadRunner :9000 override
├── web-build/Dockerfile.roadrunner       # project_file → .ddev/web-build/ (#ddev-generated): installs the rr binary
├── commands/web/rr                       # project_file → .ddev/commands/web/ (#ddev-generated): `ddev rr <args>` passthrough
├── example.rr.yaml                        # FastCGI reference config users copy if not using the recipe (NOT installed)
├── README.md · LICENSE · .gitattributes
├── docs/                                 # this spec (export-ignored)
├── tests/{test.bats, testdata/*}         # bats suite + fixtures (export-ignored)
└── .github/workflows/tests.yml
```

Most installed files are `#ddev-generated`, so DDEV removes them on `ddev add-on remove`. The one exception is `nginx_full/nginx-site.conf`, which **must** be markerless (or DDEV would regenerate it back to the php-fpm socket on every start). Because DDEV does not auto-remove markerless files, a **`removal_action`** deletes it on uninstall; DDEV then regenerates its php-fpm default on the next start. Nothing is written outside `.ddev/`.

## 3. File-by-file specification

### 3.1 `install.yaml`

`project_files`: the four `.ddev/` files above. `ddev_version_constraint: '>= v1.24.10'`. `pre_install_actions`: the PHP-version gate (hard-fail < 8.1; warn 8.1–8.4 re bundle v5). `post_install_actions`: (1) set the override's `root` to `${DDEV_DOCROOT:-public}` (the **docroot knob** — patches the add-on's own override file, not user source, so ADR-6 holds); (2) read-only guidance — checks for a project `.rr.yaml` (warns if it lacks `fcgi`), bundle install, and registration in `config/bundles.php`. `removal_actions`: one host-side action deleting the markerless `nginx_full/nginx-site.conf` (DDEV won't auto-remove a markerless file). No file copied into the user's source tree.

```yaml
name: roadrunner
project_files:
  - config.roadrunner.yaml
  - nginx_full/nginx-site.conf
  - web-build/Dockerfile.roadrunner
  - commands/web/rr
ddev_version_constraint: '>= v1.24.10'
pre_install_actions:
  - |
    #ddev-description:Checking PHP version for RoadRunner
    UNSUPPORTED_PHP_VERSIONS=("5.6" "7.0" "7.1" "7.2" "7.3" "7.4" "8.0")
    if [[ " ${UNSUPPORTED_PHP_VERSIONS[*]} " == *" ${DDEV_PHP_VERSION} "* ]]; then
      echo "RoadRunner requires PHP 8.1 or newer (8.5 recommended for fluffydiscord/roadrunner-symfony-bundle v5)."
      echo "Run 'ddev config --php-version=8.5' and try again."; exit 2
    fi
    case "${DDEV_PHP_VERSION}" in 8.1|8.2|8.3|8.4) echo "NOTE: bundle v5 requires PHP 8.5+; you are on ${DDEV_PHP_VERSION}." ;; esac
post_install_actions:
  - |
    #ddev-description:Checking the RoadRunner / Symfony bundle setup
    RRYAML="${DDEV_APPROOT}/.rr.yaml"; BUNDLES="${DDEV_APPROOT}/config/bundles.php"
    if [ ! -f "${RRYAML}" ]; then
      echo "No .rr.yaml yet. Install the bundle (recipe creates one) or copy example.rr.yaml; it MUST use"
      echo "http.fcgi.address: tcp://0.0.0.0:9000 (this add-on fronts RoadRunner with nginx over FastCGI)."
    elif ! grep -q 'fcgi' "${RRYAML}"; then
      echo "Your .rr.yaml does not use http.fcgi — set http.fcgi.address: tcp://0.0.0.0:9000 (see example.rr.yaml)."
    fi
    if [ ! -d "${DDEV_APPROOT}/vendor/fluffydiscord/roadrunner-symfony-bundle" ]; then
      echo "Install + register the bundle (Flex recipe), swap the kernel trait in src/Kernel.php, then 'ddev restart'."
    elif [ -f "${BUNDLES}" ] && ! grep -q 'FluffyDiscordRoadRunnerBundle' "${BUNDLES}"; then
      echo "Bundle installed but not registered: add FluffyDiscord\\RoadRunnerBundle\\FluffyDiscordRoadRunnerBundle::class => ['all' => true] to config/bundles.php."
    fi
removal_actions:
  - |
    #ddev-description:Restoring php-fpm nginx routing
    OVERRIDE="${DDEV_APPROOT}/.ddev/nginx_full/nginx-site.conf"   # removal_actions run on the host
    if [ -f "${OVERRIDE}" ] && grep -q 'ddev-roadrunner-managed' "${OVERRIDE}"; then
      rm -f "${OVERRIDE}"; echo "Removed the RoadRunner nginx override; DDEV restores php-fpm routing on the next start."
    fi
```

### 3.2 `config.roadrunner.yaml`

```yaml
#ddev-generated
webserver_type: nginx-fpm
web_extra_daemons:
  - name: "roadrunner"
    # RR_CONFIG_FILE (default .rr.yaml) is honored via bash -c; set it in .ddev/.env.web.
    command: "bash -c 'exec /usr/local/bin/rr serve -w /var/www/html -c ${RR_CONFIG_FILE:-.rr.yaml}'"
    directory: /var/www/html
```

*Notes:* `webserver_type: nginx-fpm` keeps DDEV's nginx (it also resets a project left on `generic`). **Absolute `/usr/local/bin/rr`** (bare `rr` = the bundle's `vendor/bin/rr`, no `serve`). The command is wrapped in **`bash -c '… exec …'`** so the shell expands `${RR_CONFIG_FILE:-.rr.yaml}` — the **config-path knob** (`-c`), adjustable via `ddev dotenv set .ddev/.env.web --rr-config-file=<file>` (`.env.web` is injected into the web container, so the supervisord-spawned daemon sees it — Phase-3 verified). `exec` keeps rr in the foreground for supervisord. nginx is repointed at RoadRunner by the markerless `nginx_full/nginx-site.conf` override (§3.2a), **not** a runtime hook — so there is no per-start patching and no startup window where traffic could hit php-fpm.

### 3.2a `nginx_full/nginx-site.conf` (the nginx override)

A copy of DDEV's default site config with **one** change: the app's PHP `fastcgi_pass` is `127.0.0.1:9000` (RoadRunner) instead of the php-fpm socket. It carries **no** `#ddev-generated` marker — so DDEV treats it as a user override and never regenerates it (verified to hold across the rebuild restart and repeated restarts). The `/phpstatus` healthcheck (`monitoring.conf`) and `/xhprof` (`common.d/xhprof.conf`) are pulled in via `include` directives that keep their own php-fpm socket, so php-fpm idles but stays healthy.

```nginx
# ddev-roadrunner-managed   ← sentinel for the removal_action; do NOT write the literal generated-file marker token anywhere in this file
server {
    listen 80 default_server; listen 443 ssl default_server;
    root /var/www/html/public;                       # shipped default; post_install sets it to ${DDEV_DOCROOT} (the docroot knob)
    ssl_certificate /etc/ssl/certs/master.crt; ssl_certificate_key /etc/ssl/certs/master.key;
    include /etc/nginx/monitoring.conf;              # /phpstatus → php-fpm socket (unchanged)
    location / { try_files $uri $uri/ /index.php?$query_string; }
    location ~ \.php$ {
        try_files $uri =404;
        fastcgi_pass 127.0.0.1:9000;                 # ← the one change vs. DDEV's default (was the php-fpm socket)
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        # …remaining params identical to DDEV's template…
    }
    include /etc/nginx/common.d/*.conf;              # /xhprof → php-fpm socket (unchanged)
    include /mnt/ddev_config/nginx/*.conf;
}
```

*Critical gotcha:* DDEV decides whether it owns this file by searching for its generated-file marker as a **substring anywhere** in the file. If that token appears even inside a comment, DDEV regenerates the file (reverting to the php-fpm socket). The override must therefore never contain that literal token — describe it indirectly (as this file does). Because the file is markerless, `ddev add-on remove` will **not** auto-delete it; the `removal_action` in §3.1 does (host-side, guarded by the `ddev-roadrunner-managed` sentinel), and DDEV regenerates its php-fpm default on the next start.

### 3.3 `.rr.yaml` (owned by the project) & `example.rr.yaml`

The add-on installs no `.rr.yaml`. RoadRunner reads the project's own (recipe-created or copied from `example.rr.yaml`), bind-mounted live. It **must** use `http.fcgi` (the bundle recipe's default is `http.address` — HTTP mode — which this add-on does **not** use). `example.rr.yaml` (shipped at the add-on root, not installed):

```yaml
version: "3"
server:
  command: "php public/index.php"
  env:
    - APP_RUNTIME: FluffyDiscord\RoadRunnerBundle\Runtime\Runtime
http:
  fcgi:
    address: tcp://0.0.0.0:9000   # nginx connects here; no http.address (nginx serves HTTP + static)
  pool:
    debug: true                   # dev: fresh worker per request → edited PHP picked up immediately
logs:
  mode: development
  channels:
    http: { level: info }
    server: { level: info, mode: raw }
rpc:
  listen: tcp://127.0.0.1:6001     # must match the app's .env RR_RPC
```

### 3.4 `web-build/Dockerfile.roadrunner`

```dockerfile
#ddev-generated
COPY --from=ghcr.io/roadrunner-server/roadrunner:2025.1.14 /usr/bin/rr /usr/local/bin/rr
RUN chmod +x /usr/local/bin/rr && rr --version
```

*Phase-3 verified:* static Go binary runs on the Debian web image; `rr --version` → `rr version 2025.1.14`.

### 3.5 `commands/web/rr`

```bash
#!/usr/bin/env bash
#ddev-generated
## Description: Run the RoadRunner CLI (rr) in the web container against your project's .rr.yaml
## Usage: rr [subcommand] [flags...]
## Example: "ddev rr reset", "ddev rr workers", "ddev rr --version"
## ExecRaw: true
cd /var/www/html || exit 1
exec /usr/local/bin/rr "$@"
```

*Phase-3 verified:* `ddev rr --version`, `ddev rr reset`, `ddev rr workers` all work (flags pass via `ExecRaw`).

### 3.6 Fixtures / README / CI

`example.rr.yaml` (§3.3). `tests/testdata/`: `bundles.php` (registers the bundle), `PingController.php` (`/` → `roadrunner-symfony-ok pid=<pid>`), `routes.yaml`, `psr7-index.php` (infra worker), `public-asset.txt`. README per §README. `.github/workflows/tests.yml` matrix `[stable, HEAD] × [symfony, infra, removal, php-gate, config]`. `.gitattributes` export-ignores `tests/ docs/ .github/ .idea/` (keeps `example.rr.yaml`).

## 4. Assumptions

| # | Assumption | If wrong, then… |
|---|------------|-----------------|
| A1 | Target PHP 8.5 (bundle v5); add-on infra works on 8.1+ | Pin a bundle version for the project's PHP |
| A2 | Override's `root` defaults to `public` but **post_install sets it to `${DDEV_DOCROOT}`** (the docroot knob), so any docroot works (DDEV's symfony & php configs are byte-identical here) — **VERIFIED** with `--docroot=web` | If `DDEV_DOCROOT` is unavailable to actions, fall back to grepping `.ddev/config.yaml` |
| A3 | **VERIFIED:** nginx → FastCGI → RoadRunner:9000 serves the app (nginx terminates TLS, serves static) | — |
| A4 | **VERIFIED:** a markerless `.ddev/nginx_full/nginx-site.conf` is respected by DDEV and held across the rebuild restart + repeated restarts (no runtime patching) | If a DDEV change starts overwriting markerless overrides, fall back to a `post-start` hook |
| A5 | **VERIFIED:** the static `rr` binary runs on the Debian web image | — |
| A6 | Infra-only; no app/`.rr.yaml` mutation (ADR-3/6); the only nginx change is the markerless override file the add-on owns | — |
| A7 | **VERIFIED:** RR `2025.1.14` is protocol-compatible with the bundle | — |
| A8 | php-fpm idling under `nginx-fpm` is harmless and required (healthcheck `/phpstatus`, `/xhprof`) — do not disable it | — |
| A9 | The project's `.rr.yaml` uses `http.fcgi:9000` (recipe default is `http.address` → user switches it, or copies `example.rr.yaml`) | nginx FastCGI → an HTTP-mode RR fails; post_install warns; user sets `http.fcgi` |

## 5. Open Questions

| # | Question | Blocks | Default |
|---|----------|--------|---------|
| OQ-1 | *(Resolved)* "RR_RELAY / tcp / 0.0.0.0" = the `http.fcgi` listen address, not the goridge relay. Relay stays **pipes** (RR default; fastest). | No | Resolved |
| OQ-2 | Auto-register the bundle / switch `.rr.yaml` to fcgi for the user, vs. document it (ADR-3/6)? | No | Document |
| OQ-3 | Pin RR to `2025.1.14` or track latest? | No | Pin |
| OQ-4 | *(Resolved)* Non-`public` docroots: post_install sets the override's `root` to `${DDEV_DOCROOT}` (default `public`); `RR_CONFIG_FILE` (default `.rr.yaml`) selects the rr config. Both **VERIFIED**. | No | Resolved |
| OQ-5 | Stop php-fpm entirely (vs. let it idle)? | No | Let it idle (healthcheck depends on it) |

## 6. Anti-Patterns (DO NOT)

| Don't | Do instead | Why |
|-------|-----------|-----|
| Write DDEV's generated-file marker token into the override (even in a comment) | Ship a **markerless** `nginx_full/nginx-site.conf`; describe the marker indirectly | DDEV matches that token as a **substring anywhere** in the file → regenerates it back to the php-fpm socket *(Phase-3 — this exact bug bit the override's own comment)* |
| Rely on `ddev add-on remove` to delete the markerless override | Add a host-side `removal_action` (`${DDEV_APPROOT}/.ddev/...`) | DDEV refuses to auto-remove files without its marker ("Unwilling to remove…") *(Phase-3)* |
| Put removal cleanup at the container path `/var/www/html/.ddev/…` | Use `${DDEV_APPROOT}/.ddev/…` | `removal_actions` run on the **host**, not in the web container *(Phase-3)* |
| Disable php-fpm under `nginx-fpm` | Let it idle | DDEV's healthcheck `/phpstatus` and the `/xhprof` UI fastcgi_pass to the php-fpm socket |
| Use `http.address` in the project's `.rr.yaml` | Use `http.fcgi.address: tcp://0.0.0.0:9000` | This add-on fronts RoadRunner with nginx over FastCGI; HTTP mode won't be reached |
| Invoke bare `rr` in the daemon / `rr` command | Absolute `/usr/local/bin/rr` | The bundle's `vendor/bin/rr` (spiral CLI) is first on PATH; no `serve`/`reset` *(Phase-3)* |
| Assume `composer require` registers the bundle | Ensure it's in `config/bundles.php` (recipe or manual) | Composer skips contrib recipes non-interactively → 500 `…\WorkerRegistry` *(Phase-3)* |
| Background the daemon (`rr serve … &`) | Foreground (rr default) | supervisord manages it; backgrounding → restart loop |
| `echo`/`dd()` to STDOUT in the worker | STDERR (`display_errors=stderr`) / Buggregator | STDOUT is the goridge pipe relay → "CRC verification failed" |
| `composer install` the project in the Dockerfile | Install only the `rr` binary | Project code isn't mounted at build time |
| Assume RoadRunner serves a plain `index.php` | Require a PSR-7 worker (the bundle's runtime) | RR's HTTP/FastCGI plugin only talks to a worker loop |
| Auto-edit `src/Kernel.php` / `.env` / `.rr.yaml` | Document the changes (ADR-3/6) | User source is fragile to rewrite, not cleanly reversible |

## 7. Test Case Specifications

### "Unit" / static (≥5)
TC-001 YAML validity (`config.roadrunner.yaml`, `example.rr.yaml`); TC-002 `#ddev-generated` on each installed file **except `nginx_full/nginx-site.conf`, which must NOT contain the marker token** (assert its absence); TC-003 shellcheck (`commands/web/rr`, action bodies); TC-004 Dockerfile builds + `rr --version`; TC-005 `install.yaml` schema; TC-006 PHP gate (8.0→exit2; 8.4→warn; 8.5→silent); TC-007 the override's `fastcgi_pass` is `127.0.0.1:9000` and it carries the `ddev-roadrunner-managed` sentinel.

### Integration (bats, ≥3) — all Phase-3-proven
| ID | Flow | Key verification |
|----|------|------------------|
| **IT-001 (`symfony`, PRIMARY)** | config symfony/public/8.5; start; `composer create-project symfony/skeleton:^7.4`; `composer require` bundle; kernel-trait `sed`; `RR_RPC`→`.env`; copy `bundles.php`(register) + `example.rr.yaml`→`.rr.yaml`(fcgi) + `PingController.php` + `routes.yaml`; `ddev add-on get`; `ddev restart` | `ddev exec grep 'fastcgi_pass 127.0.0.1:9000' /etc/nginx/sites-enabled/nginx-site.conf` (override applied); `curl https` → `roadrunner-symfony-ok pid=`; `curl -I http` → `200`; `supervisorctl status` → `webextradaemons:roadrunner RUNNING`; `ddev exec /usr/local/bin/rr --version` |
| IT-002 (`infra`) | docroot public; `composer init`+`require spiral/roadrunner-http nyholm/psr7`; **write a FastCGI `.rr.yaml`**; `psr7-index.php`→`public/index.php`; `add-on get` (assert `.ddev/nginx_full/nginx-site.conf` exists); restart | `fastcgi_pass 127.0.0.1:9000`; `curl` → `RoadRunner OK pid=` (a raw PSR-7 worker **only** RoadRunner can serve — php-fpm would STDIN-fatal, so this is the strongest RR-serves proof); static asset served; `ddev rr reset` ok |
| IT-003 (`removal`) | install (assert override present); `ddev add-on remove roadrunner`; restart | `config.roadrunner.yaml` gone; **`.ddev/nginx_full/nginx-site.conf` deleted by the removal_action**; nginx reverts to php-fpm; project `.rr.yaml` untouched |
| IT-004 (`php-gate`) | `ddev config --php-version=8.0`; `ddev add-on get` | fails; output mentions PHP 8.1 |
| IT-005 (`config`) | docroot **`web`**; `ddev dotenv set .ddev/.env.web --rr-config-file=.rr.fcgi.yaml`; raw worker + a custom-named `.rr.fcgi.yaml` (**no `.rr.yaml`**); `add-on get`; restart | override `root` is `/var/www/html/web` (docroot knob); `curl` → `RoadRunner OK pid=` with no `.rr.yaml` present proves RR loaded `.rr.fcgi.yaml` (config-path knob) |

*IT-002 (`infra`) is the strongest RoadRunner-serves proof: a raw PSR-7 worker fatals under php-fpm (the goridge STDIN relay is a CLI-only constant), so a `RoadRunner OK pid=` 200 can only come from RoadRunner. IT-001 (`symfony`, the primary gate) proves it via the `fastcgi_pass 127.0.0.1:9000` override check + the `roadrunner` daemon RUNNING — a 200 alone would false-pass through php-fpm.*

## 8. Error Handling Matrix

| Error | Detection | Recovery |
|-------|-----------|----------|
| PHP < 8.1 | `pre_install` | `exit 2`; `ddev config --php-version=8.5` |
| `rr` wrong arch/tag | `rr --version` in Dockerfile build | bump tag |
| `Command "serve" is not defined` | daemon crash loop in `ddev logs` | use `/usr/local/bin/rr` (fixed §3.2) |
| 500 `…\WorkerRegistry` | curl 500 | register the bundle in `config/bundles.php` |
| 200 served by php-fpm, not RR (override not applied) | `fastcgi_pass` still socket after restart | confirm `.ddev/nginx_full/nginx-site.conf` exists and is **markerless** — if it contains DDEV's generated-file marker token (even in a comment) DDEV regenerates it back to the socket |
| 502 (nginx → :9000, RR down) | curl 502 | check RR daemon (`supervisorctl status`), `.rr.yaml` uses `http.fcgi:9000`, RR_RPC matches |
| `.rr.yaml` uses `http.address` not `fcgi` | RR not reachable via FastCGI | set `http.fcgi.address: tcp://0.0.0.0:9000` (post_install warns) |
| STDOUT corruption ("CRC verification failed") | `ddev logs` | output → STDERR; ensure `APP_RUNTIME`; `display_errors=stderr` |
| Code edit not reflected (pool mode) | stale response | `pool.debug:true` avoids it; else `ddev rr reset` |
| Xdebug/xhprof toggled but RR unaffected | no debug session | `pool.debug` fresh worker reads new ini next request; else `ddev rr reset` |

## 9. References (external sources)

| Topic | Location |
|-------|----------|
| Bundle config / README / composer (PHP 8.5, Symfony 7.4/8, RR_RPC, kernel trait) | https://github.com/FluffyDiscord/roadrunner-symfony-bundle |
| Bundle Flex contrib recipe (registers bundle, sets RR_RPC, copies install/.rr.yaml) | https://github.com/symfony/recipes-contrib/tree/main/fluffydiscord/roadrunner-symfony-bundle |
| RR `http.fcgi` (FastCGI mode) + `.rr.yaml` reference | https://github.com/roadrunner-server/roadrunner/blob/master/.rr.yaml |
| RR relay (pipes default; env vars) | https://docs.roadrunner.dev/docs/plugins/server · https://docs.roadrunner.dev/docs/php-worker/environment |
| RR `pool.debug` | https://docs.roadrunner.dev/docs/php-worker/pool |
| RR STDOUT-CRC gotcha | https://docs.roadrunner.dev/docs/error-codes/stdout-crc |
| RR CLI (`serve -w`, `reset`, `workers`) | https://docs.roadrunner.dev/docs/app-server/cli |
| RR official image (alpine, static `/usr/bin/rr`) | https://github.com/roadrunner-server/roadrunner/pkgs/container/roadrunner |
| DDEV `webserver_type`, custom nginx, hooks, `web_extra_daemons` | https://docs.ddev.com/en/stable/users/extend/customization-extendibility/ · https://docs.ddev.com/en/stable/users/configuration/hooks/ |
| DDEV creating add-ons / `#ddev-generated` / custom commands / customizing images | https://docs.ddev.com/en/stable/users/extend/creating-add-ons/ · https://docs.ddev.com/en/stable/users/extend/custom-commands/ · https://docs.ddev.com/en/stable/users/extend/customizing-images/ |
