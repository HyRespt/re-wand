#!/usr/bin/env bash
set -Eeuo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RUFFLE_VERSION="${RUFFLE_VERSION:-0.3.0}"
RUFFLE_SCRIPT_URL="${RUFFLE_SCRIPT_URL:-https://unpkg.com/@ruffle-rs/ruffle@${RUFFLE_VERSION}}"
HOUDINI_WEBSOCKETS_REPOSITORY="${HOUDINI_WEBSOCKETS_REPOSITORY:-https://github.com/Lekuruu/houdini-websockets.git}"
HOUDINI_WEBSOCKETS_REF="${HOUDINI_WEBSOCKETS_REF:-8721758d4fa593ff3a19138e0cc3f89f9a96329b}"
PYTHON_WEBSOCKETS_REQUIREMENT="${PYTHON_WEBSOCKETS_REQUIREMENT:-websockets==15.0.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

ask_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local answer

  if [[ "$default" == "y" ]]; then
    read -r -p "$prompt [Y/n]: " answer
    answer="${answer:-y}"
  else
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-n}"
  fi

  [[ "$answer" =~ ^[Yy]$ ]]
}

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

root="${1:-$PWD}"
root="$(cd "$root" && pwd)"

[[ -f "$root/docker-compose.yml" ]] || {
  echo "Not a Wand checkout: $root" >&2
  exit 1
}

[[ -f "$root/.env" ]] || {
  echo "Missing $root/.env; configure the installation first." >&2
  exit 1
}

if ask_yes_no "Install browser Ruffle support?" y; then
  ruffle=true
else
  ruffle=false
fi

if [[ "$ruffle" == true ]] \
  && ask_yes_no "Enable Card-Jitsu Snow WebSocket support?" y; then
  snow=true
else
  snow=false
fi

if ask_yes_no "Enable Spanish, Portuguese, and French worlds?" n; then
  multilang=true
else
  multilang=false
fi

if ask_yes_no "Persist Redis-backed game progress?" y; then
  redis_persistence=true
else
  redis_persistence=false
fi

if [[ "$ruffle" == true ]]; then
  read -r -p "Ruffle script URL [$RUFFLE_SCRIPT_URL]: " ruffle_url
  ruffle_url="${ruffle_url:-$RUFFLE_SCRIPT_URL}"
else
  ruffle_url="$RUFFLE_SCRIPT_URL"
fi

mkdir -p "$root/scripts"
for script in create_moderator.py create-moderator.sh doctor.sh; do
  cp "$KIT_ROOT/scripts/$script" "$root/scripts/$script"
done
chmod +x "$root/scripts/create-moderator.sh" "$root/scripts/doctor.sh"

python3 "$KIT_ROOT/scripts/patch_wand.py" \
  --root "$root" \
  --ruffle "$ruffle" \
  --multilang "$multilang" \
  --redis-persistence "$redis_persistence" \
  --card-jitsu-snow "$snow" \
  --ruffle-script-url "$ruffle_url" \
  --houdini-websockets-repository "$HOUDINI_WEBSOCKETS_REPOSITORY" \
  --houdini-websockets-ref "$HOUDINI_WEBSOCKETS_REF" \
  --python-websockets-requirement "$PYTHON_WEBSOCKETS_REQUIREMENT" \
  --redis-image "$REDIS_IMAGE"

mkdir -p "$root/.wand-ruffle"
cat > "$root/.wand-ruffle/options" <<EOF_OPTIONS
RUFFLE=$ruffle
CARD_JITSU_SNOW=$snow
MULTILANGUAGE=$multilang
REDIS_PERSISTENCE=$redis_persistence
RUFFLE_SCRIPT_URL=$ruffle_url
HOUDINI_WEBSOCKETS_REF=$HOUDINI_WEBSOCKETS_REF
PYTHON_WEBSOCKETS_REQUIREMENT=$PYTHON_WEBSOCKETS_REQUIREMENT
REDIS_IMAGE=$REDIS_IMAGE
EOF_OPTIONS

if ask_yes_no "Rebuild and restart the changed services now?" y; then
  DOCKER_TEXT="$(compose_command)" || {
    echo "Docker is unavailable or permission was denied." >&2
    exit 1
  }
  read -r -a DOCKER <<<"$DOCKER_TEXT"

  cd "$root"

  profile_args=()
  [[ "$multilang" == true ]] && profile_args=(--profile multilang)

  services=(web redis houdini_login houdini_blizzard)
  [[ "$snow" == true ]] && services+=(snowflake)

  if [[ "$multilang" == true ]]; then
    services+=(houdini_glaciar houdini_avalanche houdini_yeti)
  fi

  "${DOCKER[@]}" compose "${profile_args[@]}" up \
    -d --build --force-recreate "${services[@]}"
fi

if ask_yes_no "Create or promote a moderator penguin now?" n; then
  "$root/scripts/create-moderator.sh"
fi
