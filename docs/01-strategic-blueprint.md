# DDEV RoadRunner Add-on — Strategic Blueprint (Strategic)

**Status:** Draft for gate review · **Date pinned:** 2026-06-01 · **Author:** Rostislav Kaleta (FluffyDiscord)

This is the *strategic* document (WHAT / WHY). All implementation detail (file contents, anti-patterns, test cases, error matrix) lives in the Implementation Spec — see [References](#references).

---

## 1. The problem

DDEV ships three web server types — `nginx-fpm` (default), `apache-fpm`, and `generic` — but there is **no** way for a Symfony developer on DDEV to run their application under **RoadRunner**, the Go-based PHP application server. (Verified: no `ddev-roadrunner` repo, not in the add-on registry, no built-in support — see Implementation Spec §References.)

**Exact problem statement:** Enable a Symfony developer using DDEV to serve their application with RoadRunner — via `fluffydiscord/roadrunner-symfony-bundle` — through a single `ddev add-on get` plus a short, documented app-adoption step, yielding a working `https://<project>.ddev.site` served by RoadRunner in development (debug-pool) mode.

**Implementation Implication:** The deliverable is a DDEV add-on (a git repo of declarative config + Dockerfile fragment + scripts + tests), **not** a custom Docker image and **not** changes to DDEV core.

## 2. Why this is the right shape

A DDEV add-on can swap the PHP runtime via `web_extra_daemons`. RoadRunner runs as a **FastCGI backend** and DDEV's existing nginx fronts it (`fastcgi_pass` → RoadRunner:9000), exactly as nginx fronts php-fpm — matching how it's run in production. One decisive difference from php-fpm drives the worker side:

> **Unlike php-fpm, RoadRunner cannot serve a plain `index.php`.** It spawns long-running PHP **worker** processes and its HTTP/FastCGI plugin requires a PSR-7 worker loop. For Symfony, that loop is provided by `fluffydiscord/roadrunner-symfony-bundle`, which turns `public/index.php` into a worker via the Symfony Runtime component (`APP_RUNTIME`).

**Implementation Implication:** "Fully working" splits cleanly into two halves. The add-on owns the **infrastructure** half (binary, nginx FastCGI wiring, the `ddev rr` command) and makes it work end-to-end. The **application** half — installing the bundle, swapping the kernel trait, setting `RR_RPC` — is the user's Symfony code and is *documented*, not mutated (see ADR-6). This boundary is honest and is stated up front in the README.

## 3. Success criteria (acceptance, not market metrics)

This is a developer tool, not a product with conversion funnels; the methodology's "users/timeline" metric framing is overridden here with a one-line rationale: success is **functional acceptance**, verified by the bats suite on DDEV `stable` and `HEAD`.

| # | Criterion | How verified |
|---|-----------|--------------|
| S1 | After add-on install + documented app setup + `ddev restart`, `https://<project>.ddev.site` returns **HTTP 200** served by RoadRunner | `curl -sfI` asserts `200` + RoadRunner-style response; bats |
| S2 | `ddev php -v` reports the configured PHP (target **8.5**) | bats |
| S3 | Editing a `.php` file is reflected on the next request (debug pool) | bats / manual |
| S4 | `ddev logs` surfaces RoadRunner output | manual + bats best-effort |
| S5 | `ddev add-on remove` removes the add-on's `#ddev-generated` `.ddev/` files and **leaves the project's own `.rr.yaml` intact** | bats (IT-003) |
| S6 | bats suite green on DDEV `stable` **and** `HEAD` | CI |

## 4. Core architecture decision

Keep DDEV's nginx and run RoadRunner as a FastCGI backend behind it — the way the bundle author runs RoadRunner in production:

```
ddev-router ──TLS──► nginx  (webserver_type: nginx-fpm)
                       ├─ serves static files from public/
                       └─ fastcgi_pass 127.0.0.1:9000 ──► RoadRunner (http.fcgi :9000)
                                                            ├─ server.command: php public/index.php
                                                            │   (PSR-7 worker via the bundle's runtime)
                                                            └─ http.pool.debug: true (fresh worker/request)
  web container also runs:
    • web_extra_daemon "roadrunner": /usr/local/bin/rr serve -w /var/www/html  (reads the project's OWN .rr.yaml)
    • a post-start hook: repoints nginx fastcgi_pass → 127.0.0.1:9000 and reloads nginx (every start)
    • php-fpm — idle, kept for DDEV's /phpstatus healthcheck and the /xhprof UI
```

nginx terminates TLS, serves static files, and proxies PHP to RoadRunner over FastCGI — the same role it plays for php-fpm, so main-URL routing is the platform's proven path. RoadRunner exposes `http.fcgi.address: tcp://0.0.0.0:9000`; a `post-start` hook re-points nginx at it because DDEV regenerates the nginx config (back to the php-fpm socket) on every start. **Phase-3 verified** end-to-end: RoadRunner's own HTTP-plugin log records the 200s with **zero** php-fpm-socket hits. The detailed ADRs are below; exact file contents are in the Implementation Spec.

## 5. Tech-stack rationale

| Component | Choice | Rationale (tied to constraints) |
|-----------|--------|---------------------------------|
| App server | RoadRunner server binary, pinned `2025.1.14` | Compatible with the bundle's `spiral/roadrunner ^v2025\|\|^3`; Go static binary → portable from the official Alpine image into Debian web image |
| Binary delivery | Multi-stage `COPY --from=ghcr.io/roadrunner-server/roadrunner:<tag>` | Reproducible + pinned + arch-correct (buildx resolves host arch); no build-time download script |
| PHP | DDEV web image, **NTS**, target 8.5 | RoadRunner needs no ZTS (standard NTS PHP); bundle v5 requires 8.5+; `ext-sockets` already present |
| Symfony↔RR bridge | `fluffydiscord/roadrunner-symfony-bundle` | The user's own bundle; canonical for this integration |
| Front / TLS / static | DDEV's **nginx** (`webserver_type: nginx-fpm`) terminates TLS, serves static, `fastcgi_pass` → RoadRunner:9000 | Matches the user's prod wiring; reuses nginx's mature TLS/static/front-controller config |
| CI / tests | `bats` + `ddev/github-action-add-on-test` | The DDEV add-on testing standard |

## 6. MVP features (in scope)

1. `rr` binary baked into the web image (pinned, verified at build via `rr --version`).
2. DDEV wiring: `webserver_type: nginx-fpm` + `web_extra_daemons` (RoadRunner) + a `post-start` hook re-pointing nginx `fastcgi_pass` at RoadRunner:9000.
3. `example.rr.yaml` shipped as a **FastCGI** reference (`http.fcgi`, debug pool); the add-on installs **no** project `.rr.yaml` — RoadRunner reads the project's own bind-mounted file (ADR-3).
4. `ddev rr <args>` custom command (generic RoadRunner CLI passthrough: `reset`, `workers`, …).
5. `pre_install` PHP-version check (hard-fail < 8.1, warn < 8.5).
6. `post_install` guidance that **prints** the app-setup steps (bundle install/register, `http.fcgi` `.rr.yaml`) if missing — no mutation.
7. README: install + app adoption + FastCGI `.rr.yaml` + trusted-proxy + dev/prod + Xdebug/xhprof.
8. bats test suite + GitHub Actions workflow + `.gitattributes` export-ignore.

## 7. Explicitly NOT building (with rationale)

| Excluded | Why | Where addressed instead |
|----------|-----|--------------------------|
| Auto-installing the bundle / editing `src/Kernel.php` / `.env` | Editing user source is fragile and hard to reverse (ADR-6); no Flex recipe exists to lean on | README "App setup" (3 steps) + post-install guidance |
| Production-tuned config (`num_workers`, `max_jobs`, `max_worker_memory`) | This is a *dev* image; debug pool is the dev-correct default | README "Going to production" pointer |
| Non-Symfony framework presets (Laravel Octane, Spiral) shipped as defaults | Scope; the default targets Symfony per your direction | README may carry brief pointers only |
| RoadRunner serving HTTP/TLS directly (the `generic` model) | nginx fronts RoadRunner via FastCGI, matching the user's prod setup (ADR-1/ADR-4) | — |
| Disabling the idle php-fpm | DDEV's `/phpstatus` healthcheck + `/xhprof` UI depend on it; idling is harmless | Open Question OQ-5 |
| Wiring bundle extras (Centrifugo, KV, metrics, Sentry) | Out of MVP scope | README pointer to bundle docs |

## 8. Architecture Decision Records

**ADR-1 — Keep `webserver_type: nginx-fpm`; run RoadRunner as a FastCGI `web_extra_daemon` behind nginx.** *(Revised from the earlier `generic`/HTTP-direct iteration, per the bundle author — RoadRunner runs as a FastCGI backend in their projects.)*
*Decision:* Keep DDEV's nginx + php-fpm container; run `rr serve` as a supervisord-managed `web_extra_daemon`; install the `rr` binary via a web-build Dockerfile fragment; re-point nginx's `fastcgi_pass` at RoadRunner via a `post-start` hook.
*Why:* nginx (TLS, static, the symfony front-controller config, `/phpstatus`, `/xhprof`) is reused as-is; only the PHP backend changes (php-fpm → RoadRunner), matching how the user runs RR in prod. *Trade-off:* php-fpm idles, and the nginx override must be applied at runtime via a hook (DDEV regenerates the nginx config each start — see ADR-4).

**ADR-2 — Deliver the `rr` binary via multi-stage `COPY --from` from the official image.**
*Decision:* `COPY --from=ghcr.io/roadrunner-server/roadrunner:2025.1.14 /usr/bin/rr /usr/local/bin/rr`.
*Why:* Reproducible and pinned; buildx pulls the host-arch variant; RR is a static Go binary so the Alpine-built binary runs on the Debian web image. *Alternatives rejected:* `composer ... get-binary` (needs ext-curl/zip + network at the right moment, ties version to the project) and the `download-latest.sh` script (writes to CWD, no pin). *Verification:* the Dockerfile runs `rr --version`, so a bad/incompatible binary fails the build immediately.

**ADR-3 — The add-on does NOT manage `.rr.yaml`; RoadRunner uses the project's own bind-mounted file.** *(Revised per bundle-author direction; supersedes the earlier "copy it into the project root" approach.)*
*Decision:* The add-on ships **no** `.rr.yaml` and copies nothing into the project. The daemon runs `rr serve` from the project root (`directory: /var/www/html`), so RoadRunner reads the project's **own** `.rr.yaml` by default — created by the bundle's Flex recipe, or by the user (the add-on provides `example.rr.yaml` as a reference). DDEV bind-mounts the project, so that file is live-editable and entirely the user's.
*Why:* A copied, `#ddev-generated` file is fragile — DDEV overwrites it on re-install and deletes it on remove, putting user edits at risk. Using the project's own file makes the config stable, owned, and editable, and removes any port/content conflict with the recipe (which also creates `.rr.yaml`). *Trade-off:* the project must contain a `.rr.yaml` (recipe or copied `example.rr.yaml`); if absent the daemon errors (documented). *Verified in Phase 3 — the daemon reads the project's mounted `.rr.yaml` and serves 200.*

**ADR-4 — nginx → RoadRunner over FastCGI; a `post-start` hook applies the override.**
*Decision:* RoadRunner listens `http.fcgi.address: tcp://0.0.0.0:9000`. A `post-start` hook rewrites `sites-enabled/nginx-site.conf`'s `fastcgi_pass` from the php-fpm socket to `127.0.0.1:9000` and reloads nginx, on every start.
*Why a hook (not a shipped file):* DDEV **regenerates** `nginx-site.conf` (php-fpm socket) on every start, discarding a `project_files` replacement — even one without `#ddev-generated` (**Phase-3-verified failure**, caught as a php-fpm false-pass). The hook runs *after* generation, is idempotent (socket-grep-guarded), edits only the main site config (so `/phpstatus` + `/xhprof` keep their php-fpm socket), and reverts cleanly when the add-on (and its hook) is removed.
*Why FastCGI:* matches how the bundle author runs RoadRunner; nginx handles TLS + static + HTTP/2. *Trade-off:* php-fpm idles (kept for the healthcheck); a brief startup window before the hook reloads nginx routes to php-fpm (harmless — no traffic during `ddev start`). The goridge worker **relay stays pipes** (the user's "tcp/0.0.0.0" referred to the FastCGI listen address, not the relay).

**ADR-5 — Default to `http.pool.debug: true` (not a warm worker pool).**
*Decision:* Ship debug pool in the default `.rr.yaml`.
*Why:* For a dev image, "edit a file → see it on next request" beats raw throughput; matches the bundle's shipped dev config and your direction. *Trade-off:* no persistent-worker speedup by default; the README documents switching to `num_workers` + `ddev rr reset`.

**ADR-6 — Do not mutate the user's Symfony application.**
*Decision:* The add-on installs infrastructure only; it does not `composer require` the bundle, edit `src/Kernel.php`, or edit `.env`. It detects and *guides* instead.
*Why:* Editing tracked user source is fragile (kernel may be customized/renamed) and not cleanly reversible in `removal_actions`; no Flex recipe exists to make `composer require` self-configuring. *Trade-off:* not 100% turnkey — the user runs 3 documented steps. **This is flaggable** (Open Question OQ-2): the bundle author may prefer an opt-in automation path.

## References

### Implementation detail lives here
| Content | Location |
|---------|----------|
| File-by-file specs (exact contents) | [Implementation Spec §3](./02-implementation-spec.md#3-file-by-file-specification) |
| Anti-patterns | [Implementation Spec §6](./02-implementation-spec.md#6-anti-patterns-do-not) |
| Test cases | [Implementation Spec §7](./02-implementation-spec.md#7-test-case-specifications) |
| Error handling matrix | [Implementation Spec §8](./02-implementation-spec.md#8-error-handling-matrix) |
| Assumptions & Open Questions | [Implementation Spec §4–5](./02-implementation-spec.md#4-assumptions) |
| External sources (cited) | [Implementation Spec §9](./02-implementation-spec.md#9-references-external-sources) |

*Strategic overview only. Implementation specs live in the linked document.*
