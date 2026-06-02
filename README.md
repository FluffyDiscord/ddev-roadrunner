[![add-on registry](https://img.shields.io/badge/DDEV-Add--on_Registry-blue)](https://addons.ddev.com)
[![tests](https://github.com/fluffydiscord/ddev-roadrunner/actions/workflows/tests.yml/badge.svg?branch=master)](https://github.com/fluffydiscord/ddev-roadrunner/actions/workflows/tests.yml?query=branch%3Amaster)
[![last commit](https://img.shields.io/github/last-commit/fluffydiscord/ddev-roadrunner)](https://github.com/fluffydiscord/ddev-roadrunner/commits)
[![release](https://img.shields.io/github/v/release/fluffydiscord/ddev-roadrunner)](https://github.com/fluffydiscord/ddev-roadrunner/releases/latest)

# DDEV RoadRunner

Run your **Symfony** app on [RoadRunner](https://roadrunner.dev/) in [DDEV](https://ddev.com/) — with DDEV's nginx in front, exactly like you'd run it in production.

## Overview

RoadRunner is a high-performance PHP application server written in Go: it keeps long-running PHP **worker** processes warm between requests instead of booting per request (php-fpm). This add-on runs RoadRunner as a **FastCGI backend** and points DDEV's nginx at it, using [`fluffydiscord/roadrunner-symfony-bundle`](https://github.com/FluffyDiscord/roadrunner-symfony-bundle).

> [!IMPORTANT]
> Unlike php-fpm, RoadRunner **cannot serve a plain `index.php`** — it needs a PSR-7 worker loop. The bundle provides it by turning `public/index.php` into a worker via the Symfony Runtime component. This add-on installs the RoadRunner **infrastructure** (the `rr` binary + DDEV wiring); you do a short, one-time **app setup** to adopt the bundle.

## How it works

```
ddev-router ──TLS──► nginx ──fastcgi_pass 127.0.0.1:9000──► RoadRunner (http.fcgi) ──► PHP worker ──► Symfony
                      └─ serves static files directly
```

- `webserver_type` stays **`nginx-fpm`**: nginx terminates TLS, serves static files, and proxies PHP over FastCGI to RoadRunner — the same role it plays for php-fpm.
- The add-on installs `.ddev/nginx_full/nginx-site.conf` — a copy of DDEV's own site config with just the app's PHP `fastcgi_pass` pointed at RoadRunner (`127.0.0.1:9000`). It carries no DDEV generated-file marker, so DDEV treats it as a user override and never regenerates it: the routing is stable across restarts with no runtime patching. `ddev add-on remove roadrunner` deletes it and DDEV restores the php-fpm default. (Assumes docroot `public`; edit `root` in that file if yours differs.)
- php-fpm stays running but **idle** — DDEV's container healthcheck (`/phpstatus`) and the `/xhprof` UI keep using it; your app traffic goes to RoadRunner.

## Requirements

- DDEV `v1.24.10`+
- PHP **8.5** (`fluffydiscord/roadrunner-symfony-bundle` v5 requires it): `ddev config --php-version=8.5`
- A Symfony project (docroot `public`)

## Installation

```bash
ddev add-on get fluffydiscord/ddev-roadrunner
```

Then complete **App setup** below and `ddev restart`. Commit the `.ddev` directory — and, after setup, your project's `.rr.yaml` — to version control.

## App setup (required, one time)

**1. Install the bundle** (its Flex recipe registers it and sets `RR_RPC`):

```bash
ddev composer config extra.symfony.allow-contrib true
ddev composer require fluffydiscord/roadrunner-symfony-bundle
```

**2. Swap the kernel trait** in `src/Kernel.php` (the recipe can't do this for you):

```diff
- use Symfony\Bundle\FrameworkBundle\Kernel\MicroKernelTrait;
+ use FluffyDiscord\RoadRunnerBundle\Kernel\RoadRunnerMicroKernelTrait;

  class Kernel extends BaseKernel
  {
-     use MicroKernelTrait;
+     use RoadRunnerMicroKernelTrait;
```

**3. Make `.rr.yaml` use FastCGI.** The recipe creates an HTTP-mode `.rr.yaml` (`http.address`). Because this add-on fronts RoadRunner with nginx over FastCGI, switch it to `http.fcgi`:

```yaml
# .rr.yaml
http:
  fcgi:
    address: tcp://0.0.0.0:9000   # nginx connects here
  pool:
    debug: true                   # dev: fresh worker per request (edits are picked up immediately)
```

(Or copy the add-on's [`example.rr.yaml`](./example.rr.yaml) to your project root.)

**4. Restart:**

```bash
ddev restart
```

Your Symfony app is now served at `https://<project>.ddev.site` by RoadRunner.

<details>
<summary>Installed non-interactively (the recipe didn't run)?</summary>

Composer skips third-party (contrib) Flex recipes in non-interactive mode. Do the recipe's work manually:

- **Register the bundle** in `config/bundles.php`: `FluffyDiscord\RoadRunnerBundle\FluffyDiscordRoadRunnerBundle::class => ['all' => true],`
- **Add** `RR_RPC=tcp://127.0.0.1:6001` to `.env`.
- Copy [`example.rr.yaml`](./example.rr.yaml) to your project root as `.rr.yaml`.

Then do steps 2 and 4 above. *(Symptom of a missing registration: a 500 with `non-existent service "FluffyDiscord\RoadRunnerBundle\Worker\WorkerRegistry"`.)*
</details>

## Usage

| Command | Description |
|---|---|
| `ddev rr <args>` | Run the RoadRunner CLI — e.g. `ddev rr reset`, `ddev rr workers`, `ddev rr jobs` |
| `ddev exec /usr/local/bin/rr --version` | RoadRunner **server** version (bare `rr` is the project's `vendor/bin/rr` CLI tool) |
| `ddev logs -f` | Follow RoadRunner / web logs |
| `ddev php -v` | Check the PHP version |

## The `.rr.yaml` file

RoadRunner reads **your project's own `.rr.yaml`** (project root). DDEV bind-mounts it, so it's **live and editable** — change it and `ddev restart` (or `ddev rr reset`). **The add-on does not copy or manage it** (no `#ddev-generated` marker) — it's entirely yours. For this add-on it must expose `http.fcgi.address: tcp://0.0.0.0:9000` (see step 3).

## Development vs. production

`pool.debug: true` gives a **fresh worker per request**, so edited PHP is picked up immediately (php-fpm-like) — ideal for dev, but no persistent-worker speed. For production-like behavior, use a worker pool and reload after edits:

```yaml
http:
  pool:
    num_workers: 4
    # max_jobs: 64           # recycle a worker after N requests
    # max_worker_memory: 128 # MB
```

```bash
ddev rr reset   # reload workers after editing PHP, in pool mode
```

## Xdebug & xhprof

`ddev xdebug on` / `ddev xhprof on` are DDEV built-ins and work here. Under `nginx-fpm` these toggles reload **php-fpm** (not RoadRunner), but with `pool.debug` each request spawns a **fresh worker that reads the updated `php.ini`**, so the change takes effect on the next request. In worker-pool mode, run `ddev rr reset` after toggling. The xhprof UI is at `https://<project>.ddev.site/xhprof`.

> [!NOTE]
> On macOS with Mutagen, file-sync latency can briefly delay the "edit → next request" reload. Give it a moment, or `ddev rr reset`.

## Trusted proxies

RoadRunner is behind nginx and `ddev-router`. If you need correct client IPs or HTTPS detection in Symfony, trust the proxy:

```yaml
# config/packages/framework.yaml
framework:
    trusted_proxies: 'private_ranges'
    trusted_headers: ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'x-forwarded-port', 'x-forwarded-prefix']
```

## Other frameworks

This add-on targets Symfony via `fluffydiscord/roadrunner-symfony-bundle`. RoadRunner also runs **Laravel** (via [Octane](https://laravel.com/docs/octane)), **Spiral** (natively), and **plain PSR-7** workers — each needs a different `.rr.yaml` `server.command` and worker; adapt your `.rr.yaml` accordingly.

## Resources

- [RoadRunner documentation](https://docs.roadrunner.dev/)
- [`fluffydiscord/roadrunner-symfony-bundle`](https://github.com/FluffyDiscord/roadrunner-symfony-bundle)
- [DDEV custom nginx / webserver](https://docs.ddev.com/en/stable/users/extend/customization-extendibility/)

## Credits

**Contributed by [@FluffyDiscord](https://github.com/FluffyDiscord)** — author of `fluffydiscord/roadrunner-symfony-bundle`.
