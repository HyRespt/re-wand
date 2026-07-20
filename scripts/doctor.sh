#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

HOUDINI_WEBSOCKETS_REF="${HOUDINI_WEBSOCKETS_REF:-8721758d4fa593ff3a19138e0cc3f89f9a96329b}"
PYTHON_WEBSOCKETS_REQUIREMENT="${PYTHON_WEBSOCKETS_REQUIREMENT:-websockets==15.0.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"
RUFFLE_VERSION="${RUFFLE_VERSION:-0.3.0}"
RUFFLE_SCRIPT_URL="${RUFFLE_SCRIPT_URL:-https://unpkg.com/@ruffle-rs/ruffle@${RUFFLE_VERSION}}"

compose_command() {
  if docker info >/dev/null 2>&1; then
    printf '%s\n' "docker"
  elif command -v sudo >/dev/null 2>&1 \
    && sudo docker info >/dev/null 2>&1; then
    printf '%s\n' "sudo docker"
  else
    return 1
  fi
}

failure=0

check() {
  local description="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    printf 'OK   %s\n' "$description"
  else
    printf 'FAIL %s\n' "$description"
    failure=1
  fi
}

option_value() {
  local key="$1"

  if [[ -f .wand-ruffle/options ]]; then
    sed -n "s/^${key}=//p" .wand-ruffle/options | tail -n1
  fi
}

ruffle_enabled="$(option_value RUFFLE)"
snow_enabled="$(option_value CARD_JITSU_SNOW)"
redis_persistence="$(option_value REDIS_PERSISTENCE)"

check "Wand Compose file" test -f docker-compose.yml
check "Compose override" test -f docker-compose.override.yml
check "Redis 7 Alpine image override" \
  grep -Fq "image: $REDIS_IMAGE" docker-compose.override.yml
check "Pinned Python websockets dependency" \
  grep -Fxq "$PYTHON_WEBSOCKETS_REQUIREMENT" houdini/requirements.txt
check "Houdini WebSocket plugin checkout" \
  test -f houdini/houdini/plugins/houdini-websockets/__init__.py
check "Pinned Houdini WebSocket plugin revision" bash -c \
  '[[ "$(git -C houdini/houdini/plugins/houdini-websockets rev-parse HEAD)" == "$1" ]]' \
  _ "$HOUDINI_WEBSOCKETS_REF"

if [[ "$ruffle_enabled" == true || -z "$ruffle_enabled" ]]; then
  check "Ruffle Vanilla marker" \
    grep -q 'WAND_RUFFLE_BEGIN' \
    templates/vanilla-media/play/index.html.template
  check "Pinned Ruffle URL" \
    grep -Fq "RUFFLE_SCRIPT_URL=$RUFFLE_SCRIPT_URL" .env
fi

if [[ "$snow_enabled" == true ]]; then
  check "Snowflake WebSocket port" \
    grep -q '8002:8002' docker-compose.override.yml
  check "Snow launch guard" \
    grep -Rqs 'WAND_RUFFLE_CJS_GUARD' \
    vanilla-media/play/sites/default/files/js
fi

if [[ "$redis_persistence" == true ]]; then
  check "Redis persistent volume configuration" \
    grep -q 'redis-data:/data' docker-compose.override.yml
fi

if DOCKER_TEXT="$(compose_command 2>/dev/null)"; then
  read -r -a DOCKER <<<"$DOCKER_TEXT"

  check "Compose configuration" "${DOCKER[@]}" compose config

  echo
  "${DOCKER[@]}" compose ps || true

  if "${DOCKER[@]}" compose ps --status running redis \
    >/dev/null 2>&1; then
    echo
    "${DOCKER[@]}" compose exec -T redis redis-server --version || true

    if [[ "$redis_persistence" == true ]]; then
      "${DOCKER[@]}" compose exec -T redis \
        redis-cli CONFIG GET appendonly || true
    fi
  fi
else
  echo "INFO Docker checks skipped: daemon unavailable or permission denied."
fi

exit "$failure"
