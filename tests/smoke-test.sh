#!/usr/bin/env bash
set -Eeuo pipefail
KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PLUGIN_SOURCE="$TMP_ROOT/plugin-source"
mkdir -p "$PLUGIN_SOURCE"
git -C "$PLUGIN_SOURCE" init -q
git -C "$PLUGIN_SOURCE" config user.email smoke@example.invalid
git -C "$PLUGIN_SOURCE" config user.name "Smoke Test"
printf '# fake plugin\n' > "$PLUGIN_SOURCE/__init__.py"
printf '# fake streams\n' > "$PLUGIN_SOURCE/streams.py"
printf '# fake utils\n' > "$PLUGIN_SOURCE/utils.py"
git -C "$PLUGIN_SOURCE" add .
git -C "$PLUGIN_SOURCE" commit -qm "Initial fake plugin"
PLUGIN_REF="$(git -C "$PLUGIN_SOURCE" rev-parse HEAD)"

make_fixture() {
  local root="$1"
  mkdir -p "$root"/{houdini/houdini/plugins,templates/sites,templates/dash,templates/vanilla-media/play,templates/legacy-media/play,vanilla-media/play/sites/default/files/js}
  cat > "$root/.env" <<'ENV'
POSTGRES_USER=postgres
POSTGRES_PASSWORD=test
GAME_ADDRESS=127.0.0.1
GAME_LOGIN_PORT=6112
WEB_VANILLA_PLAY=http://play.localhost
WEB_VANILLA_MEDIA=http://media.localhost
WEB_LEGACY_PLAY=http://old.localhost
SNOWFLAKE_HOST=127.0.0.1
SNOWFLAKE_PORT=7002
EMAIL_SMTP_PORT=
ENV
  cat > "$root/docker-compose.yml" <<'YAML'
version: '3.7'
services:
  db: {image: postgres:12-alpine}
  redis: {image: redis:5-alpine}
  web: {image: nginx}
  houdini_login: {image: h}
  houdini_blizzard: {image: h}
  houdini_glaciar: {image: h}
  houdini_avalanche: {image: h}
  houdini_yeti: {image: h}
  snowflake: {image: s, environment: [POSTGRES_HOST=db]}
networks:
  wand: {driver: bridge}
YAML
  printf 'asyncpg\nwebsockets\n' > "$root/houdini/requirements.txt"
  cat > "$root/templates/sites/vanilla.conf.template" <<'NGINX'
server { server_name play.example; # WAND_RUFFLE_CORS add_header Access-Control-Allow-Origin "*" always; location / { root /usr/share/nginx/vanilla/play; } } server { server_name media.example; location / { root /usr/share/nginx/vanilla/media; } }
NGINX
  cat > "$root/templates/sites/legacy.conf.template" <<'NGINX'
server { server_name old.example; location / { root /usr/share/nginx/legacy/play; } } server { server_name legacy.example; location / { root /usr/share/nginx/legacy/media; } }
NGINX
  cat > "$root/templates/dash/config.py.template" <<'PY'
SMTP_PORT = int('{{ .Env.EMAIL_SMTP_PORT }}')
PY
  cat > "$root/templates/vanilla-media/play/index.html.template" <<'HTML'
<!doctype html><html><head><script>var x={"wns":"old.example"};</script></head><body></body></html>
HTML
  cat > "$root/templates/legacy-media/play/index.html.template" <<'HTML'
<!doctype html><html><head></head><body></body></html>
HTML
  cat > "$root/vanilla-media/play/sites/default/files/js/game.js" <<'JS'
function launchMPGame(gameDetails) { if (window.snowball) window.snowball.loadMP(gameDetails); }
JS
}

run_patcher() {
  local root="$1" persistence="$2"
  python3 "$KIT_ROOT/scripts/patch_wand.py" --root "$root" \
    --ruffle true \
    --multilang false \
    --redis-persistence "$persistence" \
    --card-jitsu-snow true \
    --houdini-websockets-repository "$PLUGIN_SOURCE" \
    --houdini-websockets-ref "$PLUGIN_REF" \
    --python-websockets-requirement 'websockets==15.0.1' \
    --redis-image 'redis:7-alpine' >/dev/null
}

TMP="$TMP_ROOT/with-persistence"
make_fixture "$TMP"
run_patcher "$TMP" true

files=(
  .env docker-compose.yml docker-compose.override.yml servers.xml
  templates/dash/config.py.template
  houdini/requirements.txt templates/sites/vanilla.conf.template
  templates/sites/legacy.conf.template
  templates/vanilla-media/play/index.html.template
  templates/legacy-media/play/index.html.template
  vanilla-media/play/sites/default/files/js/game.js
)
for file in "${files[@]}"; do sha256sum "$TMP/$file"; done > "$TMP/before.sha"
run_patcher "$TMP" true
for file in "${files[@]}"; do sha256sum "$TMP/$file"; done > "$TMP/after.sha"
diff -u "$TMP/before.sha" "$TMP/after.sha"

python3 - "$TMP/.env" "$TMP/templates/dash/config.py.template" <<'PY'
from pathlib import Path
import sys

env = Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
template = Path(sys.argv[2]).read_text(encoding="utf-8")

assert env.count("EMAIL_SMTP_PORT=587") == 1
assert "SMTP_PORT = int('{{ .Env.EMAIL_SMTP_PORT }}' or '587')" in template
PY
test "$(grep -o 'Access-Control-Allow-Origin' "$TMP/templates/sites/vanilla.conf.template" | wc -l)" -eq 2
test "$(grep -o 'Access-Control-Allow-Origin' "$TMP/templates/sites/legacy.conf.template" | wc -l)" -eq 2
test "$(grep -o 'if ($request_method = OPTIONS) { return 204; }' "$TMP/templates/sites/vanilla.conf.template" | wc -l)" -eq 2
test "$(grep -o 'if ($request_method = OPTIONS) { return 204; }' "$TMP/templates/sites/legacy.conf.template" | wc -l)" -eq 2
! grep -q 'WAND_RUFFLE_CORS' "$TMP/templates/sites/vanilla.conf.template"
grep -Fq 'server_name media.example; add_header Access-Control-Allow-Origin "*" always;' \
  "$TMP/templates/sites/vanilla.conf.template"
grep -Fq 'Access-Control-Allow-Headers "$http_access_control_request_headers" always;' \
  "$TMP/templates/sites/vanilla.conf.template"
grep -Fq 'Access-Control-Expose-Headers "Content-Length, Content-Range, Accept-Ranges" always;' \
  "$TMP/templates/sites/vanilla.conf.template"

if command -v nginx >/dev/null 2>&1; then
  {
    printf 'pid %s;\n' "$TMP/nginx.pid"
    printf 'error_log stderr notice;\n'
    mkdir -p "$TMP/nginx-body" "$TMP/nginx-proxy" "$TMP/nginx-fastcgi" "$TMP/nginx-uwsgi" "$TMP/nginx-scgi"
    printf 'events {}\nhttp {\n'
    printf 'access_log off;\n'
    printf 'client_body_temp_path %s;\n' "$TMP/nginx-body"
    printf 'proxy_temp_path %s;\n' "$TMP/nginx-proxy"
    printf 'fastcgi_temp_path %s;\n' "$TMP/nginx-fastcgi"
    printf 'uwsgi_temp_path %s;\n' "$TMP/nginx-uwsgi"
    printf 'scgi_temp_path %s;\n' "$TMP/nginx-scgi"
    cat "$TMP/templates/sites/vanilla.conf.template"
    printf '\n'
    cat "$TMP/templates/sites/legacy.conf.template"
    printf '\n}\n'
  } > "$TMP/nginx-test.conf"

  nginx -t -q -c "$TMP/nginx-test.conf"
fi

grep -Fxq 'websockets==15.0.1' "$TMP/houdini/requirements.txt"
grep -q 'WAND_RUFFLE_BEGIN' "$TMP/templates/vanilla-media/play/index.html.template"
grep -q 'WAND_RUFFLE_CJS_GUARD' "$TMP/vanilla-media/play/sites/default/files/js/game.js"
grep -q 'profiles: \["multilang"\]' "$TMP/docker-compose.override.yml"
grep -q 'image: redis:7-alpine' "$TMP/docker-compose.override.yml"
grep -q 'redis-data:/data' "$TMP/docker-compose.override.yml"
grep -q '8002:8002' "$TMP/docker-compose.override.yml"
grep -Fq 'RUFFLE_SCRIPT_URL=https://unpkg.com/@ruffle-rs/ruffle@0.3.0' "$TMP/.env"
[[ "$(git -C "$TMP/houdini/houdini/plugins/houdini-websockets" rev-parse HEAD)" == "$PLUGIN_REF" ]]
! grep -q '^version:' "$TMP/docker-compose.yml"

TMP_NO_PERSIST="$TMP_ROOT/without-persistence"
make_fixture "$TMP_NO_PERSIST"
run_patcher "$TMP_NO_PERSIST" false
grep -q 'image: redis:7-alpine' "$TMP_NO_PERSIST/docker-compose.override.yml"
! grep -q 'redis-data:/data' "$TMP_NO_PERSIST/docker-compose.override.yml"

python3 - "$TMP/docker-compose.override.yml" <<'PY'
import sys
try:
    import yaml
except ImportError:
    raise SystemExit(0)
with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)
assert "services" in data
assert data["services"]["houdini_glaciar"]["profiles"] == ["multilang"]
assert data["services"]["redis"]["image"] == "redis:7-alpine"
PY

printf 'Smoke test passed.\n'


bash "$KIT_ROOT/install.sh" --help | grep -q -- '--skip-media-download'
grep -q 'Card-Jitsu Snow remains available' "$KIT_ROOT/install.sh"
! grep -q 'Card-Jitsu Snow disabled because media' "$KIT_ROOT/install.sh"
grep -q 'openssl rand -hex' "$KIT_ROOT/install.sh"