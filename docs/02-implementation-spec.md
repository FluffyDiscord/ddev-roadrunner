# DDEV RoadRunner Add-on — Implementation Spec (Implementation)

**Source pinned to:** 2026-06-01 · DDEV `v1.25.1` (constraint `>= v1.24.10`) · RoadRunner server `2025.1.14` · `fluffydiscord/roadrunner-symfony-bundle` `v5.0.0` (PHP 8.5+, Symfony 7.4/8).
**Document type:** Implementation. Strategy/ADRs live in [Strategic Blueprint](./01-strategic-blueprint.md).

Every claim about an *external* system carries a citation in [§9](#9-references-external-sources). Design decisions are governed by Assumptions ([§4](#4-assumptions)) and Open Questions ([§5](#5-open-questions)).

> **Architecture: FastCGI (final, Phase-3 verified 2026-06-01).** RoadRunner runs as a **FastCGI backend** on `tcp://0.0.0.0:9000`; **DDEV's nginx fronts it** (`fastcgi_pass 127.0.0.1:9000`), exactly as the user runs RoadRunner in their own projects. Verified end-to-end on local DDEV v1.25.1 + Docker (real Symfony skeleton 7.4 + bundle v5.0.0): RoadRunner's own HTTP-plugin log records the 200s and there are **zero** php-fpm-socket upstream hits — RoadRunner, not php-fpm, serves the app. Facts proven by running it:
> 1. nginx → RoadRunner over FastCGI on :9000 (chain: ddev-router → nginx (TLS, static) → fastcgi_pass → RR → worker → Symfony).
> 2. The daemon must invoke **`/usr/local/bin/rr`** — bare `rr` resolves to the bundle's `vendor/bin/rr` (spiral CLI, no `serve`).
> 3. The bundle must be **registered in `config/bundles.php`** (the Flex recipe does it; skipped non-interactively → 500 `…\WorkerRegistry`).
> 4. **The nginx override must be applied by a `post-start` hook, not `project_files`.** DDEV regenerates `.ddev/nginx_full/nginx-site.conf` (back to the php-fpm socket) on every start, discarding a shipped replacement — even a no-`#ddev-generated` one. A `post-start` hook re-points `fastcgi_pass` and reloads nginx on every start (proven to stick).
> 5. **The add-on does not copy or manage `.rr.yaml`** — RoadRunner reads the project's own bind-mounted `.rr.yaml`, which must use **`http.fcgi`** (not `http.address`). `example.rr.yaml` is the reference.

---

## 1. Scope & component model

Components: the manifest (`install.yaml`), the DDEV config overlay (`config.roadrunner.yaml`, which also carries the nginx `post-start` hook), the image fragment (`web-build/Dockerfile.roadrunner`), and the custom command (`commands/web/rr`). `.rr.yaml` and the nginx site config are **not** add-on-managed files (the project owns `.rr.yaml`; DDEV owns the nginx config, which the hook patches at runtime). Phase-2 floors (≥5 anti-patterns; ≥5 "unit"/static + ≥3 integration tests) apply to the add-on as a whole.

## 2. Repository layout

```
ddev-roadrunner/
├── install.yaml                          # add-on manifest (NOT a project_file)
├── config.roadrunner.yaml                # project_file → .ddev/   (#ddev-generated): nginx-fpm + RR daemon + post-start hook
├── web-build/Dockerfile.roadrunner       # project_file → .ddev/web-build/ (#ddev-generated): installs the rr binary
├── commands/web/rr                       # project_file → .ddev/commands/web/ (#ddev-generated): `ddev rr <args>` passthrough
├── example.rr.yaml                        # FastCGI reference config users copy if not using the recipe (NOT installed)
├── README.md · LICENSE · .gitattributes
├── docs/                                 # this spec (export-ignored)
├── tests/{test.bats, testdata/*}         # bats suite + fixtures (export-ignored)
└── .github/workflows/tests.yml
```

All installed files are `#ddev-generated` under `.ddev/`, so DDEV removes them on `ddev add-on remove` and the nginx override reverts automatically (the hook is gone, so DDEV's next-start config points back at php-fpm). **No `removal_actions` needed; nothing is written outside `.ddev/`.**

## 3. File-by-file specification

### 3.1 `install.yaml`

`project_files`: the three `.ddev/` files above. `ddev_version_constraint: '>= v1.24.10'`. `pre_install_actions`: the PHP-version gate (hard-fail < 8.1; warn 8.1–8.4 re bundle v5). `post_install_actions`: read-only guidance only (ADR-6) — it checks for a project `.rr.yaml` (and warns if it lacks `fcgi`), bundle install, and bundle registration in `config/bundles.php`, pointing at the recipe or the manual steps. No file copied into the project; no `removal_actions`.

```yaml
name: roadrunner
project_files:
  - config.roadrunner.yaml
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
```

### 3.2 `config.roadrunner.yaml`

```yaml
#ddev-generated
webserver_type: nginx-fpm
web_extra_daemons:
  - name: "roadrunner"
    command: "/usr/local/bin/rr serve -w /var/www/html"
    directory: /var/www/html
hooks:
  post-start:
    - exec: "if grep -q 'fastcgi_pass unix:/run/php-fpm.sock;' /etc/nginx/sites-enabled/nginx-site.conf; then sudo sed -i 's|fastcgi_pass unix:/run/php-fpm.sock;|fastcgi_pass 127.0.0.1:9000;|g' /etc/nginx/sites-enabled/nginx-site.conf && sudo nginx -s reload; fi"
```

*Notes:* `webserver_type: nginx-fpm` keeps DDEV's nginx (it also resets a project left on `generic`). `rr serve` runs in the **foreground** (supervisord daemonizes it); **absolute `/usr/local/bin/rr`** (bare `rr` = the bundle's `vendor/bin/rr`, no `serve`); no `-c` (rr reads the project's own `.rr.yaml` from the working dir). The **`post-start` hook** is the only reliable way to apply the nginx override — DDEV regenerates `nginx-site.conf` (php-fpm socket) on every start, so the hook re-points `fastcgi_pass` at RoadRunner and reloads nginx each start. The hook is **idempotent** (guarded by the socket grep) and edits only `sites-enabled/nginx-site.conf` — the `/phpstatus` healthcheck (`monitoring.conf`) and `/xhprof` (`common.d/xhprof.conf`) keep their php-fpm socket, so php-fpm idles but stays healthy. `sudo` is used because the hook runs as the web user and nginx's master is root (Phase-3-verified working). Removing the add-on removes this file → the hook is gone → DDEV's next start reverts nginx to php-fpm.

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

`example.rr.yaml` (§3.3). `tests/testdata/`: `bundles.php` (registers the bundle), `PingController.php` (`/` → `roadrunner-symfony-ok pid=<pid>`), `routes.yaml`, `psr7-index.php` (infra worker), `public-asset.txt`. README per §README. `.github/workflows/tests.yml` matrix `[stable, HEAD] × [symfony, infra, removal, php-gate]`. `.gitattributes` export-ignores `tests/ docs/ .github/ .idea/` (keeps `example.rr.yaml`).

## 4. Assumptions

| # | Assumption | If wrong, then… |
|---|------------|-----------------|
| A1 | Target PHP 8.5 (bundle v5); add-on infra works on 8.1+ | Pin a bundle version for the project's PHP |
| A2 | Symfony **docroot `public`**; DDEV's symfony nginx config is what the hook patches | Non-`public` docroots use a different nginx root — verify the generated `nginx-site.conf` (OQ-4) |
| A3 | **VERIFIED:** nginx → FastCGI → RoadRunner:9000 serves the app (nginx terminates TLS, serves static) | — |
| A4 | **VERIFIED:** the `post-start` hook (in a config partial) merges, runs, and `sudo nginx -s reload` works each start | If a DDEV change breaks hook-merge, move the hook to the project's `config.yaml` |
| A5 | **VERIFIED:** the static `rr` binary runs on the Debian web image | — |
| A6 | Infra-only; no app/`.rr.yaml`/nginx-file mutation (ADR-3/6); nginx patched at runtime via the hook | — |
| A7 | **VERIFIED:** RR `2025.1.14` is protocol-compatible with the bundle | — |
| A8 | php-fpm idling under `nginx-fpm` is harmless and required (healthcheck `/phpstatus`, `/xhprof`) — do not disable it | — |
| A9 | The project's `.rr.yaml` uses `http.fcgi:9000` (recipe default is `http.address` → user switches it, or copies `example.rr.yaml`) | nginx FastCGI → an HTTP-mode RR fails; post_install warns; user sets `http.fcgi` |

## 5. Open Questions

| # | Question | Blocks | Default |
|---|----------|--------|---------|
| OQ-1 | *(Resolved)* "RR_RELAY / tcp / 0.0.0.0" = the `http.fcgi` listen address, not the goridge relay. Relay stays **pipes** (RR default; fastest). | No | Resolved |
| OQ-2 | Auto-register the bundle / switch `.rr.yaml` to fcgi for the user, vs. document it (ADR-3/6)? | No | Document |
| OQ-3 | Pin RR to `2025.1.14` or track latest? | No | Pin |
| OQ-4 | Support non-`public` docroots (the hook + nginx root assume `public`)? | No | Assume `public` |
| OQ-5 | Stop php-fpm entirely (vs. let it idle)? | No | Let it idle (healthcheck depends on it) |

## 6. Anti-Patterns (DO NOT)

| Don't | Do instead | Why |
|-------|-----------|-----|
| Ship the nginx config via `project_files` (`.ddev/nginx_full/nginx-site.conf`) | Re-point `fastcgi_pass` via a **`post-start` hook** + `nginx -s reload` | DDEV **regenerates** `nginx-site.conf` (php-fpm socket) on every start, discarding the shipped file — even without `#ddev-generated` *(Phase-3)* |
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
TC-001 YAML validity (`config.roadrunner.yaml`, `example.rr.yaml`); TC-002 `#ddev-generated` on each installed file; TC-003 shellcheck (`commands/web/rr`, action bodies, the hook one-liner); TC-004 Dockerfile builds + `rr --version`; TC-005 `install.yaml` schema; TC-006 PHP gate (8.0→exit2; 8.4→warn; 8.5→silent).

### Integration (bats, ≥3) — all Phase-3-proven
| ID | Flow | Key verification |
|----|------|------------------|
| **IT-001 (`symfony`, PRIMARY)** | config symfony/public/8.5; start; `composer create-project symfony/skeleton:^7.4`; `composer require` bundle; kernel-trait `sed`; `RR_RPC`→`.env`; copy `bundles.php`(register) + `example.rr.yaml`→`.rr.yaml`(fcgi) + `PingController.php` + `routes.yaml`; `ddev add-on get`; `ddev restart` | `ddev exec grep 'fastcgi_pass 127.0.0.1:9000' /etc/nginx/sites-enabled/nginx-site.conf` (hook applied); `curl https` → `roadrunner-symfony-ok pid=`; `curl -I http` → `200`; **RR's http log shows the request + zero php-fpm-socket upstream hits** (RR served, not php-fpm); `supervisorctl status` → `webextradaemons:roadrunner RUNNING`; `ddev exec /usr/local/bin/rr --version` |
| IT-002 (`infra`) | docroot public; `composer init`+`require spiral/roadrunner-http nyholm/psr7`; `example.rr.yaml`→`.rr.yaml`; `psr7-index.php`→`public/index.php`; `add-on get`; restart | nginx→9000; `curl` → `RoadRunner OK pid=`; `ddev rr reset` ok |
| IT-003 (`removal`) | install; `ddev add-on remove roadrunner`; restart | `config.roadrunner.yaml` gone; nginx reverts to php-fpm; project `.rr.yaml` untouched |
| IT-004 (`php-gate`) | `ddev config --php-version=8.0`; `ddev add-on get` | fails; output mentions PHP 8.1 |

*IT-001 is the non-skippable gate for S1. The `fastcgi_pass 9000` check + RR's own http-log + zero php-fpm-socket hits together prove RoadRunner (not idle php-fpm) serves the app — a 200 alone would false-pass through php-fpm.*

## 8. Error Handling Matrix

| Error | Detection | Recovery |
|-------|-----------|----------|
| PHP < 8.1 | `pre_install` | `exit 2`; `ddev config --php-version=8.5` |
| `rr` wrong arch/tag | `rr --version` in Dockerfile build | bump tag |
| `Command "serve" is not defined` | daemon crash loop in `ddev logs` | use `/usr/local/bin/rr` (fixed §3.2) |
| 500 `…\WorkerRegistry` | curl 500 | register the bundle in `config/bundles.php` |
| 200 served by php-fpm, not RR (hook didn't apply) | `fastcgi_pass` still socket; RR http-log empty; php-fpm-socket upstream in `ddev logs` | confirm the `post-start` hook ran (config-partial merge) + `sudo nginx -s reload` succeeded |
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
