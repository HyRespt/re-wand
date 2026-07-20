# Re-Wand

[![Smoke test](https://github.com/HyRespt/re-wand/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/HyRespt/re-wand/actions/workflows/smoke-test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE.md)

Re-Wand is a Docker Compose setup for running Houdini with modern browser support through [Ruffle](https://ruffle.rs/).

It is based on [solero/wand](https://github.com/solero/wand) and adds an interactive installer, Ruffle WebSockets, Card-Jitsu Snow support, Redis persistence, optional English-only mode, moderator creation, and diagnostics.

> Re-Wand is an unofficial community project and is not affiliated with or endorsed by Disney.

## Features

- Standalone Linux/WSL installer
- Vanilla and Legacy Ruffle support
- Houdini login/world WebSocket bridges
- Card-Jitsu Snow WebSocket support
- English-only or multilingual worlds
- Redis 7 Alpine with optional persistence
- Automatic moderator penguin setup
- Migration tool for existing Wand servers
- Smoke tests and installation diagnostics

## Requirements

The installer supports Linux and Linux under WSL. It can install the required tools automatically:

- Git
- curl
- OpenSSL
- Python 3
- Docker Engine
- Docker Compose v2

## Install

Review the installer first:

```bash
curl -fsSL   https://raw.githubusercontent.com/HyRespt/re-wand/master/install.sh   -o install-re-wand.sh

less install-re-wand.sh
bash install-re-wand.sh
```

Or run it directly:

```bash
bash <(
  curl -fsSL   https://raw.githubusercontent.com/HyRespt/re-wand/master/install.sh
)
```

The installer asks for the hostname, reachable game address, database password, Ruffle, Card-Jitsu Snow, multilingual worlds, Redis persistence, moderator account, and whether to start immediately.

Recommended choices for a small English-only server:

```text
Ruffle:                                  Yes
Card-Jitsu Snow:                         Yes
Spanish/Portuguese/French worlds:        No
Redis persistence:                       Yes
Create initial moderator:                Yes
Build and start:                         Yes
```

## URLs and ports

For a hostname such as `example.test`:

```text
http://play.example.test/      Vanilla client
http://media.example.test/     Vanilla media
http://old.example.test/       Legacy client
http://legacy.example.test/    Legacy media
```

Every player device must resolve these names to the Re-Wand server.

| Port | Service |
|---:|---|
| 80 | Web client and media |
| 6112 | Login server |
| 7112 | Login WebSocket |
| 9875 | Blizzard |
| 10875 | Blizzard WebSocket |
| 7002 | Card-Jitsu Snow |
| 8002 | Snow WebSocket |

Optional worlds use:

| World | Game | WebSocket |
|---|---:|---:|
| Glaciar | 9876 | 10876 |
| Avalanche | 9877 | 10877 |
| Yeti | 9878 | 10878 |

For a private Tailscale deployment, use private DNS or hosts-file entries and restrict access with Tailscale ACLs or a firewall.

## Start and manage

Start the English-only stack:

```bash
docker compose up -d
```

Start all language worlds:

```bash
docker compose --profile multilang up -d
```

Show status:

```bash
docker compose ps
```

Follow logs:

```bash
docker compose logs -f   web   houdini_login   houdini_blizzard
```

Card-Jitsu Snow logs:

```bash
docker compose logs -f dash snowflake
```

Stop without deleting saved data:

```bash
docker compose down
```

Do not use `docker compose down -v` unless you intentionally want to delete named volumes.

## Upgrade an existing Wand server

```bash
git clone   https://github.com/HyRespt/re-wand.git   re-wand-tools

bash re-wand-tools/apply-to-existing.sh /path/to/wand
```

The migration tool creates timestamped backups in:

```text
.wand-ruffle/backups/
```

## Moderator account

Create or promote a moderator later with:

```bash
bash scripts/create-moderator.sh
```

The password is read interactively and is not stored in `.env`.

## Diagnostics

```bash
bash scripts/doctor.sh
```

The doctor checks Compose, Redis 7, persistence, Ruffle templates, the Houdini WebSocket plugin, Snowflake configuration, and running services.

## Troubleshooting

### Docker permission denied

```bash
sudo systemctl enable --now docker
sudo docker info
```

### Login does not connect

```bash
docker compose ps houdini_login houdini_blizzard
docker compose logs houdini_login houdini_blizzard
```

Confirm ports `7112` and `10875` are reachable from the browser.

### Card-Jitsu Snow does not connect

```bash
docker compose ps snowflake
docker compose logs --tail=150 dash snowflake
docker compose port snowflake 8002
```

### Progress resets after restart

```bash
docker compose exec redis   redis-cli CONFIG GET appendonly
```

With persistence enabled, the result should include `appendonly` and `yes`.

## Known limitations

- Ruffle is not perfectly compatible with Adobe Flash Player.
- Some fonts and effects may render differently.
- Card-Jitsu Snow may still have graphical or scaling issues.
- Hardware acceleration strongly affects browser performance.
- HTTPS requires matching secure `wss://` WebSocket configuration.

## Development

```bash
git clone --recurse-submodules   https://github.com/HyRespt/re-wand.git

cd re-wand

bash -n install.sh
bash -n apply-to-existing.sh
bash -n scripts/create-moderator.sh
bash -n scripts/doctor.sh

python3 -m py_compile   scripts/patch_wand.py   scripts/create_moderator.py

bash tests/smoke-test.sh
```

Expected output:

```text
Smoke test passed.
```

## Credits

Re-Wand builds on the work of:

- [Wand](https://github.com/solero/wand)
- [Houdini](https://github.com/solero/houdini)
- [Dash](https://github.com/solero/dash)
- [Snowflake](https://github.com/Lekuruu/snowflake)
- [Ruffle](https://github.com/ruffle-rs/ruffle)
- [houdini-websockets](https://github.com/Lekuruu/houdini-websockets)

Thank you to the original maintainers and community contributors.

## License

Re-Wand's own changes are provided under the [MIT License](LICENSE.md). Dependencies, submodules, and game assets retain their respective licenses and ownership.
