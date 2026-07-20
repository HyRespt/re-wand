#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

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

json_account_payload() {
  python3 -c 'import json,sys
raw=sys.stdin.buffer.read().split(b"\0")
if len(raw) < 4:
    raise SystemExit("Missing account fields")
name,email,password,color=(part.decode() for part in raw[:4])
print(json.dumps({
    "name": name,
    "email": email,
    "password": password,
    "color": int(color),
}))'
}

while true; do
  read -r -p "Moderator penguin name: " moderator_name
  [[ -n "$moderator_name" ]] && break
  echo "A penguin name is required."
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
    echo "The password cannot be empty."
  elif [[ "$moderator_password" != "$moderator_confirm" ]]; then
    echo "Passwords did not match."
  else
    break
  fi
done

DOCKER_TEXT="$(compose_command)" || {
  echo "Docker is unavailable or permission was denied." >&2
  exit 1
}
read -r -a DOCKER <<<"$DOCKER_TEXT"

printf '%s\0%s\0%s\0%s\0' \
  "$moderator_name" \
  "$moderator_email" \
  "$moderator_password" \
  "$moderator_color" \
  | json_account_payload \
  | "${DOCKER[@]}" compose \
      --profile tools \
      run --rm --build -T moderator_setup

unset moderator_password moderator_confirm
