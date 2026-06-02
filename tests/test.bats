#!/usr/bin/env bats

# Bats is a testing framework for Bash: https://bats-core.readthedocs.io/en/stable/
# Local run (install bats-core, bats-assert, bats-file, bats-support first):
#   bats ./tests/test.bats
#   bats ./tests/test.bats --filter-tags infra        # just the fast infra smoke test
#   bats ./tests/test.bats --print-output-on-failure --show-output-of-passing-tests --verbose-run

setup() {
  set -eu -o pipefail

  # Update this to your add-on's GitHub repository:
  export GITHUB_REPO=fluffydiscord/ddev-roadrunner

  TEST_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  export BATS_LIB_PATH="${BATS_LIB_PATH}:${TEST_BREW_PREFIX}/lib:/usr/lib/bats"
  bats_load_library bats-assert
  bats_load_library bats-file
  bats_load_library bats-support

  export DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." >/dev/null 2>&1 && pwd)"
  export PROJNAME="test-$(basename "${GITHUB_REPO}")"
  mkdir -p ~/tmp
  export TESTDIR=$(mktemp -d ~/tmp/${PROJNAME}.XXXXXX)
  export DDEV_NONINTERACTIVE=true
  export DDEV_NO_INSTRUMENTATION=true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  cd "${TESTDIR}"
}

teardown() {
  set -eu -o pipefail
  cd "${TESTDIR}" 2>/dev/null || true
  ddev delete -Oy "${PROJNAME}" >/dev/null 2>&1 || true
  if [ -n "${GITHUB_ENV:-}" ]; then
    [ -e "${GITHUB_ENV:-}" ] && echo "TESTDIR=${HOME}/tmp/${PROJNAME}" >> "${GITHUB_ENV}"
  else
    [ "${TESTDIR}" != "" ] && rm -rf "${TESTDIR}"
  fi
}

# bats test_tags=symfony
@test "PRIMARY: Symfony app served by RoadRunner via the bundle" {
  set -eu -o pipefail

  run ddev config --project-name="${PROJNAME}" --project-type=symfony --docroot=public --php-version=8.5
  assert_success
  run ddev start -y
  assert_success

  run ddev composer create-project "symfony/skeleton:^7.4"
  assert_success
  run ddev composer require fluffydiscord/roadrunner-symfony-bundle
  assert_success

  # Swap the kernel trait (the one app change that must be made by hand in real use).
  sed -i \
    -e 's|use Symfony\\Bundle\\FrameworkBundle\\Kernel\\MicroKernelTrait;|use FluffyDiscord\\RoadRunnerBundle\\Kernel\\RoadRunnerMicroKernelTrait;|' \
    -e 's|use MicroKernelTrait;|use RoadRunnerMicroKernelTrait;|' \
    src/Kernel.php
  echo 'RR_RPC=tcp://127.0.0.1:6001' >> .env

  # Simulate what the bundle's Flex contrib recipe does (composer ignores contrib recipes
  # non-interactively): register the bundle AND provide the project's own .rr.yaml. The add-on
  # does NOT copy .rr.yaml — it uses the project's bind-mounted file.
  cp "${DIR}/tests/testdata/bundles.php" config/bundles.php
  cp "${DIR}/example.rr.yaml" .rr.yaml

  mkdir -p src/Controller
  cp "${DIR}/tests/testdata/PingController.php" src/Controller/PingController.php
  cp "${DIR}/tests/testdata/routes.yaml" config/routes.yaml

  echo "# ddev add-on get ${DIR} with project ${PROJNAME} in $(pwd)" >&3
  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run curl -sf https://${PROJNAME}.ddev.site
  assert_success
  assert_output --partial "roadrunner-symfony-ok pid="

  run curl -sfI http://${PROJNAME}.ddev.site
  assert_success
  assert_output --partial "HTTP/1.1 200"

  # nginx (still nginx-fpm) forwards PHP to RoadRunner's FastCGI listener, not the php-fpm socket.
  run ddev exec grep -m1 'fastcgi_pass 127.0.0.1:9000;' /etc/nginx/sites-enabled/nginx-site.conf
  assert_success

  # The RoadRunner FastCGI backend daemon is running.
  run ddev exec supervisorctl status
  assert_output --regexp 'webextradaemons:roadrunner[[:space:]]+RUNNING'

  run ddev exec /usr/local/bin/rr --version
  assert_success
}

# bats test_tags=infra
@test "INFRA: raw PSR-7 worker served by RoadRunner; static assets served" {
  set -eu -o pipefail

  mkdir -p public
  run ddev config --project-name="${PROJNAME}" --docroot=public --php-version=8.5
  assert_success
  run ddev start -y
  assert_success

  run ddev composer init --no-interaction --name=test/infra
  assert_success
  run ddev composer require spiral/roadrunner-http nyholm/psr7
  assert_success

  cp "${DIR}/tests/testdata/psr7-index.php" public/index.php
  cp "${DIR}/tests/testdata/public-asset.txt" public/public-asset.txt

  # RoadRunner reads the project's OWN .rr.yaml (the add-on does not ship one). A raw PSR-7
  # worker needs FastCGI mode (http.fcgi) so DDEV's nginx can front it. Without this file
  # `rr serve` cannot start and nginx would fall back to php-fpm executing the worker as a
  # web script — which fatals on the goridge STDIN relay (CLI-only constant). Its presence is
  # what makes this test prove RoadRunner (not php-fpm) is serving.
  cat > .rr.yaml <<'YAML'
version: "3"
server:
  command: "php public/index.php"
http:
  fcgi:
    address: tcp://0.0.0.0:9000
  pool:
    debug: true
rpc:
  listen: tcp://127.0.0.1:6001
YAML

  run ddev add-on get "${DIR}"
  assert_success
  # The add-on installs a markerless nginx override that repoints PHP at RoadRunner.
  assert_file_exist .ddev/nginx_full/nginx-site.conf
  run ddev restart -y
  assert_success

  # nginx must forward PHP to RoadRunner (:9000), not the php-fpm socket.
  run ddev exec grep -m1 'fastcgi_pass 127.0.0.1:9000;' /etc/nginx/sites-enabled/nginx-site.conf
  assert_success

  # A raw PSR-7 worker can ONLY be served by RoadRunner — php-fpm would fatal on the STDIN
  # relay. So this 200 is proof RoadRunner is serving via FastCGI.
  run curl -sf https://${PROJNAME}.ddev.site
  assert_success
  assert_output --partial "RoadRunner OK pid="

  run curl -sf https://${PROJNAME}.ddev.site/public-asset.txt
  assert_success
  assert_output --partial "static-ok"

  run ddev rr reset
  assert_success
}

# bats test_tags=removal
@test "REMOVAL: removing the add-on cleans its own files and leaves the project's .rr.yaml intact" {
  set -eu -o pipefail

  mkdir -p public
  cp "${DIR}/example.rr.yaml" .rr.yaml          # the user's own config (not the add-on's)
  run ddev config --project-name="${PROJNAME}" --docroot=public --php-version=8.5
  assert_success
  run ddev start -y
  assert_success

  run ddev add-on get "${DIR}"
  assert_success
  assert_file_exist .ddev/config.roadrunner.yaml
  assert_file_exist .ddev/nginx_full/nginx-site.conf   # the markerless nginx override

  run ddev add-on remove roadrunner
  assert_success
  assert_file_not_exist .ddev/config.roadrunner.yaml      # add-on's #ddev-generated files are removed
  assert_file_not_exist .ddev/nginx_full/nginx-site.conf  # removal_actions delete the markerless override
  assert_file_exist .rr.yaml                              # the project's .rr.yaml is untouched

  run ddev restart -y
  assert_success
}

# bats test_tags=php-gate
@test "PHP-GATE: install is rejected on unsupported PHP" {
  set -eu -o pipefail

  run ddev config --project-name="${PROJNAME}" --docroot=public --php-version=8.0
  assert_success

  run ddev add-on get "${DIR}"
  assert_failure
  assert_output --partial "8.1"
}

# bats test_tags=config
@test "CONFIG: non-default docroot + RR_CONFIG_FILE knobs are honored" {
  set -eu -o pipefail

  # Non-default docroot (web) and a non-default RoadRunner config filename.
  mkdir -p web
  run ddev config --project-name="${PROJNAME}" --docroot=web --php-version=8.5
  assert_success
  # The config-file knob: RoadRunner should load .rr.fcgi.yaml, NOT .rr.yaml.
  run ddev dotenv set .ddev/.env.web --rr-config-file=.rr.fcgi.yaml
  assert_success
  run ddev start -y
  assert_success

  run ddev composer init --no-interaction --name=test/config
  assert_success
  run ddev composer require spiral/roadrunner-http nyholm/psr7
  assert_success
  cp "${DIR}/tests/testdata/psr7-index.php" web/index.php

  # Custom-named config (deliberately NOT .rr.yaml) referencing the web/ docroot.
  cat > .rr.fcgi.yaml <<'YAML'
version: "3"
server:
  command: "php web/index.php"
http:
  fcgi:
    address: tcp://0.0.0.0:9000
  pool:
    debug: true
rpc:
  listen: tcp://127.0.0.1:6001
YAML

  run ddev add-on get "${DIR}"
  assert_success
  # docroot knob: post_install set the override root to the project docroot (web).
  run grep -q 'root /var/www/html/web;' .ddev/nginx_full/nginx-site.conf
  assert_success
  run ddev restart -y
  assert_success

  # No .rr.yaml exists, so a 200 proves RoadRunner loaded .rr.fcgi.yaml via RR_CONFIG_FILE.
  assert_file_not_exist .rr.yaml
  run ddev exec grep -m1 'fastcgi_pass 127.0.0.1:9000;' /etc/nginx/sites-enabled/nginx-site.conf
  assert_success
  run curl -sf https://${PROJNAME}.ddev.site
  assert_success
  assert_output --partial "RoadRunner OK pid="
}
