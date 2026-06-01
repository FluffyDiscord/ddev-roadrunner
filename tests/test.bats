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

  # Proves RoadRunner (not nginx/php-fpm, which `generic` does not run) is serving.
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

  run ddev add-on get "${DIR}"
  assert_success
  run ddev restart -y
  assert_success

  run curl -sf https://${PROJNAME}.ddev.site
  assert_success
  assert_output --partial "RoadRunner OK pid="

  run curl -sf https://${PROJNAME}.ddev.site/public-asset.txt
  assert_success
  assert_output --partial "static-ok"

  run ddev rr-reset
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

  run ddev add-on remove roadrunner
  assert_success
  assert_file_not_exist .ddev/config.roadrunner.yaml   # add-on's #ddev-generated files are removed
  assert_file_exist .rr.yaml                            # the project's .rr.yaml is untouched

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
