#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Re-Wand standalone installer
#
# This file is intentionally self-contained so it can be executed directly:
#
#   bash <(curl -fsSL \
#     https://raw.githubusercontent.com/HyRespt/re-wand/master/install.sh)
#
# The cloned Re-Wand repository contains the patcher and moderator helper used
# after checkout. No files next to this downloaded installer are required.
# ==============================================================================

RE_WAND_REPOSITORY="${WAND_REPOSITORY:-https://github.com/HyRespt/re-wand.git}"

RE_WAND_REF="${WAND_REF:-master}"

RUFFLE_VERSION="${RUFFLE_VERSION:-0.3.0}"
RUFFLE_SCRIPT_URL="${RUFFLE_SCRIPT_URL:-https://unpkg.com/@ruffle-rs/ruffle@${RUFFLE_VERSION}}"

HOUDINI_WEBSOCKETS_REPOSITORY="${HOUDINI_WEBSOCKETS_REPOSITORY:-https://github.com/Lekuruu/houdini-websockets.git}"
HOUDINI_WEBSOCKETS_REF="${HOUDINI_WEBSOCKETS_REF:-8721758d4fa593ff3a19138e0cc3f89f9a96329b}"
PYTHON_WEBSOCKETS_REQUIREMENT="${PYTHON_WEBSOCKETS_REQUIREMENT:-websockets==15.0.1}"
REDIS_IMAGE="${REDIS_IMAGE:-redis:7-alpine}"

INSTALLER_VERSION="0.2.6"
SKIP_MEDIA_DOWNLOAD=false

usage() {
  cat <<'EOF'
Usage:
  install.sh [options]

Options:
  -media, --skip-media-download
      Avoid downloading the large Vanilla and Legacy media Git objects again.
      An initialized local Re-Wand checkout is used as a Git reference when
      available. Set RE_WAND_MEDIA_SOURCE=/path/to/re-wand to select it.

  -h, --help
      Show this message.
EOF
}

parse_arguments() {
  while (($#)); do
    case "$1" in
      -media|--skip-media-download)
        SKIP_MEDIA_DOWNLOAD=true
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done
}

installer_source_directory() {
  local source="${BASH_SOURCE[0]}"
  if [[ "$source" != /dev/fd/* && "$source" != /proc/self/fd/* && -e "$source" ]]; then
    cd "$(dirname "$source")" && pwd
  else
    pwd
  fi
}

is_initialized_git_checkout() {
  local path="$1"
  [[ -d "$path" && -e "$path/.git" ]] \
    && git -C "$path" rev-parse --git-dir >/dev/null 2>&1
}

find_local_media_source() {
  local candidate script_root
  script_root="$(installer_source_directory)"
  for candidate in "${RE_WAND_MEDIA_SOURCE:-}" "$script_root" "$PWD"; do
    [[ -n "$candidate" ]] || continue
    if is_initialized_git_checkout "$candidate/vanilla-media" \
      && is_initialized_git_checkout "$candidate/legacy-media"; then
      cd "$candidate" && pwd
      return 0
    fi
  done
  return 1
}

on_error() {
  local exit_code=$?
  local line="${1:-unknown}"
  printf '\nInstallation failed near line %s (exit code %s).\n' "$line" "$exit_code" >&2
  printf 'Fix the reported error and run the installer again.\n' >&2
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

print_banner() {
  cat <<'BANNER'

  ____           __        __              _
 |  _ \ ___      \ \      / /_ _ _ __   __| |
 | |_) / _ \ _____\ \ /\ / / _` | '_ \ / _` |
 |  _ <  __/_____/ \ V  V / (_| | | | | (_| |
 |_| \_\___|        \_/\_/ \__,_|_| |_|\__,_|

 Re-Wand standalone installer
BANNER
  printf ' Version: %s\n\n' "$INSTALLER_VERSION"
}

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

require_linux() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    cat >&2 <<'EOF'
This standalone installer currently supports Linux and Linux under WSL.
On macOS or Windows, install Docker Desktop and clone Re-Wand manually.
EOF
    exit 1
  fi
}

configure_privilege_command() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=()
  elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
  else
    echo "This installer needs root privileges, but sudo is unavailable." >&2
    exit 1
  fi
}

install_host_dependencies() {
  local missing=()
  local command

  for command in git curl openssl python3; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done

  if ((${#missing[@]} == 0)); then
    return
  fi

  printf 'Installing required host tools: %s\n' "${missing[*]}"

  if command -v apt-get >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y \
      ca-certificates curl git openssl python3
  elif command -v dnf >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install -y \
      ca-certificates curl git openssl python3
  elif command -v yum >/dev/null 2>&1; then
    "${SUDO[@]}" yum install -y \
      ca-certificates curl git openssl python3
  elif command -v pacman >/dev/null 2>&1; then
    "${SUDO[@]}" pacman -Syu --noconfirm
    "${SUDO[@]}" pacman -S --needed --noconfirm \
      ca-certificates curl git openssl python
  else
    echo "Unsupported package manager. Install git, curl, openssl, and Python 3 manually." >&2
    exit 1
  fi
}

start_docker_service_if_possible() {
  if command -v systemctl >/dev/null 2>&1; then
    "${SUDO[@]}" systemctl enable --now docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    "${SUDO[@]}" service docker start >/dev/null 2>&1 || true
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    start_docker_service_if_possible
    return
  fi

  if ! ask_yes_no "Docker is not installed. Install Docker Engine now?" y; then
    echo "Docker is required. Installation stopped." >&2
    exit 1
  fi

  local docker_script
  docker_script="$(mktemp)"
  trap 'rm -f "${docker_script:-}"' RETURN

  curl -fsSL https://get.docker.com -o "$docker_script"
  "${SUDO[@]}" sh "$docker_script"
  rm -f "$docker_script"
  trap - RETURN

  start_docker_service_if_possible
}

install_compose_plugin_if_needed() {
  if docker compose version >/dev/null 2>&1; then
    return
  fi
  if "${SUDO[@]}" docker compose version >/dev/null 2>&1; then
    return
  fi

  echo "Installing the Docker Compose plugin..."

  if command -v apt-get >/dev/null 2>&1; then
    "${SUDO[@]}" apt-get update
    "${SUDO[@]}" apt-get install -y docker-compose-plugin
  elif command -v dnf >/dev/null 2>&1; then
    "${SUDO[@]}" dnf install -y docker-compose-plugin
  elif command -v yum >/dev/null 2>&1; then
    "${SUDO[@]}" yum install -y docker-compose-plugin
  elif command -v pacman >/dev/null 2>&1; then
    "${SUDO[@]}" pacman -S --needed --noconfirm docker-compose
  else
    echo "Docker Compose v2 is missing. Install the Docker Compose plugin manually." >&2
    exit 1
  fi
}

select_docker_command() {
  if docker info >/dev/null 2>&1; then
    DOCKER=(docker)
  elif "${SUDO[@]}" docker info >/dev/null 2>&1; then
    DOCKER=("${SUDO[@]}" docker)
  else
    cat >&2 <<'EOF'
Docker is installed, but the daemon is unavailable or permission was denied.
Start Docker and retry. On a standard Linux host:

  sudo systemctl enable --now docker

The installer can use sudo automatically; adding your account to the docker
group is optional and grants root-equivalent access.
EOF
    exit 1
  fi

  "${DOCKER[@]}" compose version >/dev/null
}

read_secret_with_default_generation() {
  local prompt="$1"
  local generated_length="${2:-18}"
  local value

  read -r -s -p "$prompt" value
  # Visual newline only; do not capture it in POSTGRES_PASSWORD.
  printf '\n' >&2

  if [[ -z "$value" ]]; then
    # Safe for an unquoted Docker Compose dotenv value.
    value="$(openssl rand -hex "$generated_length")"
  fi

  printf '%s' "$value"
}

validate_hostname() {
  local hostname="$1"
  if [[ "$hostname" =~ [/:[:space:]] ]]; then
    echo "Enter only a hostname, without http://, https://, a path, or spaces." >&2
    return 1
  fi
}

json_account_payload() {
  python3 -c 'import json,sys
parts=sys.stdin.buffer.read().split(b"\0")
if len(parts) < 4:
    raise SystemExit("Missing moderator account fields")
name,email,password,color=(part.decode() for part in parts[:4])
print(json.dumps({
    "name": name,
    "email": email,
    "password": password,
    "color": int(color),
}))'
}

write_environment_file() {
  local target="$1"
  local hostname="$2"
  local game_address="$3"
  local db_password="$4"

  cat > "$target/.env" <<EOF_ENV
##############################################
# Database
##############################################
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$db_password

##############################################
# Web
##############################################
WEB_PORT=80
WEB_HOSTNAME=$hostname
WEB_LEGACY_PLAY=http://old.$hostname
WEB_LEGACY_MEDIA=http://legacy.$hostname
WEB_VANILLA_PLAY=http://play.$hostname
WEB_VANILLA_MEDIA=http://media.$hostname
WEB_RECAPTCHA_SITE=
WEB_RECAPTCHA_SECRET=

##############################################
# Email
##############################################
EMAIL_METHOD=
EMAIL_FROM_ADDRESS=no-reply@example.com
EMAIL_SENDGRID_KEY=
EMAIL_SMTP_HOST=
EMAIL_SMTP_PORT=587
EMAIL_SMTP_USER=
EMAIL_SMTP_PASS=
EMAIL_SMTP_SSL=TRUE

##############################################
# Game
##############################################
GAME_ADDRESS=$game_address
GAME_LOGIN_PORT=6112

##############################################
# Card-Jitsu Snow
##############################################
SNOWFLAKE_HOST=$game_address
SNOWFLAKE_PORT=7002
APPLY_WINDOWMANAGER_OFFSET=False
ALLOW_FORCESTART_SNOW=False
ALLOW_FORCESTART_TUSK=True
MATCHMAKING_TIMEOUT=30
EOF_ENV

  chmod 600 "$target/.env" 2>/dev/null || true
}

clone_or_prepare_checkout() {
  local target="$1"
  local core_submodules=(dash houdini snowflake)
  local media_submodules=(legacy-media vanilla-media)
  local media_source=""
  local submodule

  if [[ -e "$target" && ! -f "$target/docker-compose.yml" ]]; then
    echo "Target exists but is not a Re-Wand checkout: $target" >&2
    exit 1
  fi

  if [[ ! -f "$target/docker-compose.yml" ]]; then
    echo
    echo "Cloning Re-Wand..."
    echo "  Repository: $RE_WAND_REPOSITORY"
    echo "  Reference:  $RE_WAND_REF"
    git clone --branch "$RE_WAND_REF" --single-branch \
      "$RE_WAND_REPOSITORY" "$target"
  else
    echo "Using existing checkout: $target"
  fi

  echo "Initializing core submodules..."
  git -C "$target" submodule update --init --recursive \
    "${core_submodules[@]}"

  if [[ "$SKIP_MEDIA_DOWNLOAD" != true ]]; then
    echo "Initializing media submodules..."
    git -C "$target" submodule update --init --recursive \
      "${media_submodules[@]}"
    return
  fi

  echo "Media network-download skipping is enabled."
  if media_source="$(find_local_media_source)"; then
    echo "Reusing media Git objects from: $media_source"
    for submodule in "${media_submodules[@]}"; do
      if is_initialized_git_checkout "$target/$submodule"; then
        echo "  $submodule is already initialized; keeping it."
        continue
      fi
      git -C "$target" submodule update --init --recursive \
        --reference "$media_source/$submodule" "$submodule"
    done
  else
    mkdir -p "$target/legacy-media" "$target/vanilla-media"
    cat <<'EOF'

No initialized local media checkout was found, so media initialization was
skipped. The browser client cannot load without the Vanilla media files.

Install media later with:

  git submodule update --init --recursive legacy-media vanilla-media
  bash apply-to-existing.sh .
  docker compose up -d --build

EOF
  fi
}

ensure_repository_helpers() {
  local target="$1"
  local required=(
    "scripts/patch_wand.py"
    "scripts/create_moderator.py"
    "scripts/create-moderator.sh"
    "scripts/doctor.sh"
  )
  local file

  for file in "${required[@]}"; do
    if [[ ! -f "$target/$file" ]]; then
      cat >&2 <<EOF
The cloned repository does not contain $file.

Upload the complete Re-Wand release to:
  $RE_WAND_REPOSITORY

Do not upload only install.sh; the cloned repository must also contain the
scripts directory used to patch Wand and create the moderator account.
EOF
      exit 1
    fi
  done

  chmod +x \
    "$target/scripts/create-moderator.sh" \
    "$target/scripts/doctor.sh" 2>/dev/null || true
}

apply_re_wand_configuration() {
  local target="$1"
  local ruffle="$2"
  local multilang="$3"
  local redis_persistence="$4"
  local snow="$5"
  local ruffle_url="$6"

  python3 "$target/scripts/patch_wand.py" \
    --root "$target" \
    --ruffle "$ruffle" \
    --multilang "$multilang" \
    --redis-persistence "$redis_persistence" \
    --card-jitsu-snow "$snow" \
    --ruffle-script-url "$ruffle_url" \
    --houdini-websockets-repository "$HOUDINI_WEBSOCKETS_REPOSITORY" \
    --houdini-websockets-ref "$HOUDINI_WEBSOCKETS_REF" \
    --python-websockets-requirement "$PYTHON_WEBSOCKETS_REQUIREMENT" \
    --redis-image "$REDIS_IMAGE"
}

write_installation_record() {
  local target="$1"
  local ruffle="$2"
  local snow="$3"
  local multilang="$4"
  local redis_persistence="$5"
  local ruffle_url="$6"

  mkdir -p "$target/.wand-ruffle"
  cat > "$target/.wand-ruffle/options" <<EOF_OPTIONS
INSTALLER_VERSION=$INSTALLER_VERSION
RE_WAND_REPOSITORY=$RE_WAND_REPOSITORY
RE_WAND_REF=$RE_WAND_REF
RUFFLE=$ruffle
CARD_JITSU_SNOW=$snow
MULTILANGUAGE=$multilang
REDIS_PERSISTENCE=$redis_persistence
RUFFLE_SCRIPT_URL=$ruffle_url
HOUDINI_WEBSOCKETS_REPOSITORY=$HOUDINI_WEBSOCKETS_REPOSITORY
HOUDINI_WEBSOCKETS_REF=$HOUDINI_WEBSOCKETS_REF
PYTHON_WEBSOCKETS_REQUIREMENT=$PYTHON_WEBSOCKETS_REQUIREMENT
REDIS_IMAGE=$REDIS_IMAGE
SKIP_MEDIA_DOWNLOAD=$SKIP_MEDIA_DOWNLOAD
EOF_OPTIONS
}

wait_for_postgres() {
  local target="$1"
  local profile_args=()
  local ready=false

  cd "$target"

  echo "Waiting for PostgreSQL..."
  for _ in {1..120}; do
    if "${DOCKER[@]}" compose exec -T db \
      pg_isready -U postgres >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done

  if [[ "$ready" != true ]]; then
    echo "PostgreSQL did not become ready within 120 seconds." >&2
    return 1
  fi
}

create_initial_moderator() {
  local target="$1"
  local name="$2"
  local email="$3"
  local password="$4"
  local color="$5"

  cd "$target"

  printf '%s\0%s\0%s\0%s\0' \
    "$name" "$email" "$password" "$color" \
    | json_account_payload \
    | "${DOCKER[@]}" compose \
        --profile tools \
        run --rm --build -T moderator_setup
}

main() {
  parse_arguments "$@"
  print_banner
  require_linux
  configure_privilege_command
  install_host_dependencies
  install_docker
  install_compose_plugin_if_needed
  select_docker_command

  if [[ "$SKIP_MEDIA_DOWNLOAD" == true ]]; then
    cat <<'EOF'
Media network-download skipping is enabled.

EOF
  fi

  echo "Please answer the following questions."
  echo

  read -r -p "Installation directory [re-wand-server]: " target
  target="${target:-re-wand-server}"

  while true; do
    read -r -p "Server hostname [localhost]: " hostname
    hostname="${hostname:-localhost}"
    validate_hostname "$hostname" && break
  done

  read -r -p "Externally reachable game address/IP [127.0.0.1]: " game_address
  game_address="${game_address:-127.0.0.1}"

  db_password="$(read_secret_with_default_generation \
    "Database password [generate automatically]: " 18)"

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

  if ask_yes_no \
    "Enable Spanish, Portuguese, and French world servers?" n; then
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

  if ask_yes_no \
    "Create or promote an initial moderator penguin after startup?" y; then
    create_moderator=true

    while true; do
      read -r -p "Moderator penguin name: " moderator_name
      [[ -n "$moderator_name" ]] && break
      echo "A moderator penguin name is required."
    done

    while true; do
      read -r -p "Moderator email: " moderator_email
      [[ "$moderator_email" == *@* ]] && break
      echo "Enter a valid email address."
    done

    read -r -p "Penguin color [1]: " moderator_color
    moderator_color="${moderator_color:-1}"

    while true; do
      read -r -s -p "Moderator password: " moderator_password
      printf '\n'
      read -r -s -p "Confirm moderator password: " moderator_confirm
      printf '\n'

      if [[ -z "$moderator_password" ]]; then
        echo "The moderator password cannot be empty."
      elif [[ "$moderator_password" != "$moderator_confirm" ]]; then
        echo "Passwords did not match."
      else
        break
      fi
    done
  else
    create_moderator=false
  fi

  if ask_yes_no "Build and start the server after configuration?" y; then
    start_server=true
  else
    start_server=false
  fi

  clone_or_prepare_checkout "$target"
  target="$(cd "$target" && pwd)"

  ensure_repository_helpers "$target"
  write_environment_file "$target" "$hostname" "$game_address" "$db_password"

  apply_re_wand_configuration \
    "$target" \
    "$ruffle" \
    "$multilang" \
    "$redis_persistence" \
    "$snow" \
    "$ruffle_url"

  write_installation_record \
    "$target" \
    "$ruffle" \
    "$snow" \
    "$multilang" \
    "$redis_persistence" \
    "$ruffle_url"

  if [[ "$start_server" == true ]]; then
    cd "$target"
    profile_args=()
    if [[ "$multilang" == true ]]; then
      profile_args=(--profile multilang)
    fi

    "${DOCKER[@]}" compose "${profile_args[@]}" up -d --build

    if [[ "$create_moderator" == true ]]; then
      wait_for_postgres "$target"
      create_initial_moderator \
        "$target" \
        "$moderator_name" \
        "$moderator_email" \
        "$moderator_password" \
        "$moderator_color"

      unset moderator_password moderator_confirm
    fi

    echo
    "${DOCKER[@]}" compose "${profile_args[@]}" ps
  else
    echo
    echo "Configuration is complete. Start the server later with:"

    if [[ "$multilang" == true ]]; then
      printf "  cd '%s' && docker compose --profile multilang up -d --build\n" \
        "$target"
    else
      printf "  cd '%s' && docker compose up -d --build\n" "$target"
    fi

    if [[ "$create_moderator" == true ]]; then
      echo "After startup, create the moderator with:"
      printf "  cd '%s' && ./scripts/create-moderator.sh\n" "$target"
    fi
  fi

  unset db_password

  cat <<EOF

Installation complete.

Directory:
  $target

Game:
  http://play.$hostname/

Legacy client:
  http://old.$hostname/

Diagnostics:
  cd '$target' && ./scripts/doctor.sh
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
