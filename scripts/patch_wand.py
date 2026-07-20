#!/usr/bin/env python3
"""Apply the Wand Ruffle Edition configuration to a Wand checkout.

This script deliberately uses only the Python standard library so it can run
before Docker images are built.
"""
from __future__ import annotations

import argparse
import datetime as dt
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

MARKER_BEGIN = "<!-- WAND_RUFFLE_BEGIN -->"
MARKER_END = "<!-- WAND_RUFFLE_END -->"
CORS_MARKER = "# WAND_RUFFLE_CORS"
CJS_MARKER = "// WAND_RUFFLE_CJS_GUARD"
DEFAULT_RUFFLE_SCRIPT_URL = "https://unpkg.com/@ruffle-rs/ruffle@0.3.0"
DEFAULT_HOUDINI_WEBSOCKETS_REPOSITORY = "https://github.com/Lekuruu/houdini-websockets.git"
DEFAULT_HOUDINI_WEBSOCKETS_REF = "8721758d4fa593ff3a19138e0cc3f89f9a96329b"
DEFAULT_PYTHON_WEBSOCKETS_REQUIREMENT = "websockets==15.0.1"
DEFAULT_REDIS_IMAGE = "redis:7-alpine"


def parse_bool(value: str) -> bool:
    value = value.strip().lower()
    if value in {"1", "true", "yes", "y", "on"}:
        return True
    if value in {"0", "false", "no", "n", "off"}:
        return False
    raise argparse.ArgumentTypeError(f"Not a boolean: {value}")


class Patcher:
    def __init__(self, root: Path) -> None:
        self.root = root.resolve()
        stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
        self.backup_root = self.root / ".wand-ruffle" / "backups" / stamp
        self.changed: list[Path] = []
        self.warnings: list[str] = []

    def require(self, relative: str) -> Path:
        path = self.root / relative
        if not path.exists():
            raise FileNotFoundError(f"Required Wand file is missing: {path}")
        return path

    def backup(self, path: Path) -> None:
        if not path.exists():
            return
        relative = path.relative_to(self.root)
        destination = self.backup_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)

    def write(self, path: Path, content: str, *, mode: int | None = None) -> None:
        old = path.read_text(encoding="utf-8") if path.exists() else None
        if old == content:
            return
        self.backup(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        if mode is not None:
            path.chmod(mode)
        if path not in self.changed:
            self.changed.append(path)

    def update_env(self, values: dict[str, str]) -> None:
        path = self.require(".env")
        lines = path.read_text(encoding="utf-8").splitlines()
        remaining = dict(values)
        output: list[str] = []
        for line in lines:
            match = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
            if match and match.group(1) in remaining:
                key = match.group(1)
                output.append(f"{key}={remaining.pop(key)}")
            else:
                output.append(line)
        if remaining:
            output.extend(["", "# Wand Ruffle Edition"])
            output.extend(f"{key}={value}" for key, value in remaining.items())
        self.write(path, "\n".join(output).rstrip() + "\n")

    def remove_obsolete_compose_version(self) -> None:
        path = self.require("docker-compose.yml")
        content = path.read_text(encoding="utf-8")
        updated = re.sub(r"(?m)^version:\s*['\"]?[^\n'\"]+['\"]?\s*\n", "", content, count=1)
        self.write(path, updated)

    def install_websocket_plugin(self, repository: str, ref: str, requirement: str) -> None:
        plugin = self.root / "houdini/houdini/plugins/houdini-websockets"
        if plugin.exists() and not (plugin / ".git").exists():
            raise RuntimeError(
                f"WebSocket plugin directory exists but is not a Git checkout: {plugin}"
            )
        if not plugin.exists():
            plugin.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["git", "clone", "--no-checkout", repository, str(plugin)],
                check=True,
            )
        subprocess.run(
            ["git", "-C", str(plugin), "fetch", "--depth", "1", "origin", ref],
            check=True,
        )
        subprocess.run(
            ["git", "-C", str(plugin), "checkout", "--detach", "FETCH_HEAD"],
            check=True,
        )

        requirements = self.require("houdini/requirements.txt")
        lines = requirements.read_text(encoding="utf-8").splitlines()
        output: list[str] = []
        replaced = False
        for line in lines:
            if re.match(r"^\s*websockets(?:[<>=!~].*)?$", line.strip(), re.I):
                if not replaced:
                    output.append(requirement)
                    replaced = True
                continue
            output.append(line)
        if not replaced:
            output.append(requirement)
        self.write(requirements, "\n".join(output).rstrip() + "\n")

    def patch_cors(self, enabled: bool) -> None:
        for relative in ("templates/sites/vanilla.conf.template", "templates/sites/legacy.conf.template"):
            path = self.require(relative)
            content = path.read_text(encoding="utf-8")
            content = re.sub(
                rf"\s*{re.escape(CORS_MARKER)}\s*add_header\s+Access-Control-Allow-Origin\s+[^;]+;",
                "",
                content,
            )
            if enabled:
                content = re.sub(
                    r"(server_name\s+[^;]+;)",
                    rf'\1 {CORS_MARKER} add_header Access-Control-Allow-Origin "*" always;',
                    content,
                )
            self.write(path, content)

    @staticmethod
    def ruffle_block(kind: str, multilang: bool, snow: bool, ws_scheme: str) -> str:
        play_var = "WEB_VANILLA_PLAY" if kind == "vanilla" else "WEB_LEGACY_PLAY"
        proxies: list[tuple[str, str, str]] = [
            ("{{ .Env.GAME_ADDRESS }}", "6112", "7112"),
            ("{{ .Env.GAME_ADDRESS }}", "9875", "10875"),
        ]
        if multilang:
            proxies.extend(
                [
                    ("{{ .Env.GAME_ADDRESS }}", "9876", "10876"),
                    ("{{ .Env.GAME_ADDRESS }}", "9877", "10877"),
                    ("{{ .Env.GAME_ADDRESS }}", "9878", "10878"),
                ]
            )
        if snow and kind == "vanilla":
            proxies.append(("{{ .Env.SNOWFLAKE_HOST }}", "{{ .Env.SNOWFLAKE_PORT }}", "8002"))

        entries: list[str] = []
        host_template = "{{ (parseUrl .Env.%s).Host }}" % play_var
        for host, port, ws_port in proxies:
            entries.append(
                "    {\n"
                f'      host: "{host}",\n'
                f"      port: {port},\n"
                f'      proxyUrl: "{ws_scheme}://{host_template}:{ws_port}"\n'
                "    }"
            )
        proxy_text = ",\n".join(entries)
        extra = ""
        if kind == "vanilla":
            extra = (
                ",\n  fontSources: [\n"
                '    "{{ .Env.WEB_VANILLA_MEDIA }}/play/v2/client/fonts/en/FontLibrary.swf"\n'
                "  ]"
            )
        return (
            f"{MARKER_BEGIN}\n"
            "<script>\n"
            "window.RufflePlayer = window.RufflePlayer || {};\n"
            "window.RufflePlayer.config = {\n"
            "  socketProxy: [\n"
            f"{proxy_text}\n"
            "  ],\n"
            "  maxExecutionDuration: 120,\n"
            "  splashScreen: false,\n"
            '  autoplay: "on",\n'
            '  unmuteOverlay: "hidden"'
            f"{extra}\n"
            "};\n"
            "</script>\n"
            '<script src="{{ .Env.RUFFLE_SCRIPT_URL }}"></script>\n'
            f"{MARKER_END}"
        )

    def patch_html(self, path: Path, block: str | None) -> None:
        content = path.read_text(encoding="utf-8")

        # Once our marker exists, replace that exact range in place. This keeps
        # repeated runs byte-stable and avoids reformatting the surrounding HTML.
        marker_pattern = (
            rf"{re.escape(MARKER_BEGIN)}.*?{re.escape(MARKER_END)}"
        )
        if MARKER_BEGIN in content and MARKER_END in content:
            replacement = block or ""
            content = re.sub(marker_pattern, replacement, content, count=1, flags=re.S)
            self.write(path, content)
            return

        # On the first run, clean common hand-added blocks to prevent double
        # Ruffle initialization. Keep surrounding whitespace changes minimal.
        content = re.sub(
            r"<script[^>]*>.*?window\.RufflePlayer.*?</script>\s*",
            "",
            content,
            flags=re.S | re.I,
        )
        content = re.sub(
            r"<script[^>]+src=[\"'][^\"']*ruffle[^\"']*[\"'][^>]*>\s*</script>\s*",
            "",
            content,
            flags=re.S | re.I,
        )
        if block:
            match = re.search(r"</head\s*>", content, flags=re.I)
            if not match:
                raise RuntimeError(f"Could not find </head> in {path}")
            position = match.start()
            prefix = "" if position == 0 or content[position - 1] == "\n" else "\n"
            content = content[:position] + prefix + block + "\n" + content[position:]
        self.write(path, content)

    def patch_ruffle_templates(self, enabled: bool, multilang: bool, snow: bool, ws_scheme: str) -> None:
        targets: list[tuple[str, str]] = [
            ("templates/vanilla-media/play/index.html.template", "vanilla"),
            ("templates/legacy-media/play/index.html.template", "legacy"),
        ]
        if multilang:
            for language in ("es", "fr", "pt"):
                targets.extend(
                    [
                        (f"templates/vanilla-media/play/{language}/index.html.template", "vanilla"),
                        (f"templates/legacy-media/play/{language}/index.html.template", "legacy"),
                    ]
                )
        for relative, kind in targets:
            path = self.root / relative
            if not path.exists():
                self.warnings.append(f"Template not found, skipped: {relative}")
                continue
            block = self.ruffle_block(kind, multilang, snow, ws_scheme) if enabled else None
            self.patch_html(path, block)

    def patch_card_jitsu_snow(self, enabled: bool) -> None:
        if not enabled:
            return
        template = self.require("templates/vanilla-media/play/index.html.template")
        content = template.read_text(encoding="utf-8")
        updated, count = re.subn(
            r'("wns"\s*:\s*")[^"]+("\s*[,}])',
            r'\1{{ (parseUrl .Env.WEB_VANILLA_PLAY).Host }}\2',
            content,
            count=1,
        )
        if count:
            self.write(template, updated)
        else:
            self.warnings.append("Could not find the Vanilla WNS setting; Card-Jitsu Snow may need a manual WNS edit.")

        js_root = self.root / "vanilla-media/play/sites/default/files/js"
        candidates = list(js_root.rglob("*.js")) if js_root.exists() else []
        patched = 0
        already_present = False
        for path in candidates:
            source = path.read_text(encoding="utf-8", errors="ignore")
            if CJS_MARKER in source:
                already_present = True
                continue
            if not re.search(
                r"function\s+launchMPGame\s*\(\s*gameDetails\s*\)\s*\{",
                source,
            ):
                continue
            replacement = (
                "function launchMPGame(gameDetails) {\n"
                f"    {CJS_MARKER}\n"
                "    if (gameDetails == null || (typeof gameDetails === \"string\" && gameDetails.trim() === \"\")) {\n"
                "        returnToClubPenguin();\n"
                "        return;\n"
                "    }"
            )
            updated, count = re.subn(
                r"function\s+launchMPGame\s*\(\s*gameDetails\s*\)\s*\{",
                replacement,
                source,
                count=1,
            )
            if count:
                self.write(path, updated)
                patched += 1
        if patched == 0 and not already_present:
            self.warnings.append("Could not patch launchMPGame; the Card-Jitsu Snow argument guard was not installed.")

    def write_servers_xml(self, multilang: bool) -> None:
        languages = [
            ("en", 3100, "Blizzard", 9875),
        ]
        if multilang:
            languages.extend(
                [
                    ("es", 3101, "Glaciar", 9876),
                    ("pt", 3102, "Avalanche", 9877),
                    ("fr", 3103, "Yeti", 9878),
                ]
            )
        chunks: list[str] = []
        for locale, server_id, name, port in languages:
            chunks.append(
                f'    <language locale="{locale}">\n'
                f'      <server id="{server_id}" name="{name}" safe="false" '
                f'address="{{{{ .Env.GAME_ADDRESS }}}}" port="{port}" />\n'
                "    </language>"
            )
        xml = (
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            "<servers>\n"
            '  <environment name="live">\n'
            '    <login address="{{ .Env.GAME_ADDRESS }}" port="{{ .Env.GAME_LOGIN_PORT }}" />\n'
            '    <redemption address="{{ .Env.GAME_ADDRESS }}" port="9875" />\n'
            + "\n".join(chunks)
            + "\n  </environment>\n</servers>\n"
        )
        self.write(self.root / "servers.xml", xml)

    def write_compose_override(
        self,
        ruffle: bool,
        multilang: bool,
        redis_persistence: bool,
        snow: bool,
        redis_image: str,
    ) -> None:
        lines = ["services:", "  redis:", f"    image: {redis_image}"]
        if redis_persistence:
            lines.extend(
                [
                    "    command: [\"redis-server\", \"--appendonly\", \"yes\", \"--appendfsync\", \"everysec\"]",
                    "    volumes:",
                    "      - redis-data:/data",
                ]
            )
        if ruffle:
            lines.extend(
                [
                    "  houdini_login:",
                    "    ports:",
                    '      - "7112:7112"',
                    "  houdini_blizzard:",
                    "    ports:",
                    '      - "10875:10875"',
                ]
            )
        optional = [
            ("houdini_glaciar", "10876"),
            ("houdini_avalanche", "10877"),
            ("houdini_yeti", "10878"),
        ]
        if not multilang or ruffle:
            for service, port in optional:
                lines.append(f"  {service}:")
                if not multilang:
                    lines.append('    profiles: ["multilang"]')
                if ruffle:
                    lines.extend(["    ports:", f'      - "{port}:{port}"'])
        if snow:
            lines.extend(
                [
                    "  snowflake:",
                    "    ports:",
                    '      - "8002:8002"',
                    "    environment:",
                    '      - WEBSOCKET_ENABLED=True',
                    '      - WEBSOCKET_PORT=8002',
                ]
            )
        lines.extend(
            [
                "  moderator_setup:",
                "    build: ./dash",
                '    profiles: ["tools"]',
                "    env_file:",
                "      - .env",
                "    environment:",
                "      POSTGRES_HOST: db",
                "      DASH_STATIC_KEY: houdini",
                "    networks:",
                "      - wand",
                "    volumes:",
                "      - ./dash:/usr/src/dash",
                "      - ./scripts/create_moderator.py:/usr/src/dash/create_moderator.py:ro",
                "    depends_on:",
                "      - db",
                '    entrypoint: ["python", "/usr/src/dash/create_moderator.py"]',
            ]
        )
        if redis_persistence:
            lines.extend(["volumes:", "  redis-data:"])
        self.write(self.root / "docker-compose.override.yml", "\n".join(lines) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--ruffle", type=parse_bool, default=True)
    parser.add_argument("--multilang", type=parse_bool, default=False)
    parser.add_argument("--redis-persistence", type=parse_bool, default=True)
    parser.add_argument("--card-jitsu-snow", type=parse_bool, default=True)
    parser.add_argument("--ruffle-script-url", default=DEFAULT_RUFFLE_SCRIPT_URL)
    parser.add_argument("--ws-scheme", choices=("ws", "wss"), default="ws")
    parser.add_argument(
        "--houdini-websockets-repository",
        default=DEFAULT_HOUDINI_WEBSOCKETS_REPOSITORY,
    )
    parser.add_argument(
        "--houdini-websockets-ref",
        default=DEFAULT_HOUDINI_WEBSOCKETS_REF,
    )
    parser.add_argument(
        "--python-websockets-requirement",
        default=DEFAULT_PYTHON_WEBSOCKETS_REQUIREMENT,
    )
    parser.add_argument("--redis-image", default=DEFAULT_REDIS_IMAGE)
    args = parser.parse_args()

    patcher = Patcher(args.root)
    snow_enabled = args.ruffle and args.card_jitsu_snow
    patcher.require("docker-compose.yml")
    patcher.require("houdini/requirements.txt")
    patcher.require("templates/vanilla-media/play/index.html.template")
    patcher.require("templates/legacy-media/play/index.html.template")

    patcher.remove_obsolete_compose_version()
    patcher.update_env(
        {
            "RUFFLE_SCRIPT_URL": args.ruffle_script_url,
            "WEBSOCKET_ENABLED": "True" if snow_enabled else "False",
            "WEBSOCKET_PORT": "8002",
            "WAND_MULTILANGUAGE": "True" if args.multilang else "False",
        }
    )
    if args.ruffle:
        patcher.install_websocket_plugin(
            args.houdini_websockets_repository,
            args.houdini_websockets_ref,
            args.python_websockets_requirement,
        )
    patcher.patch_cors(args.ruffle)
    patcher.patch_ruffle_templates(args.ruffle, args.multilang, snow_enabled, args.ws_scheme)
    patcher.patch_card_jitsu_snow(snow_enabled)
    patcher.write_servers_xml(args.multilang)
    patcher.write_compose_override(
        args.ruffle,
        args.multilang,
        args.redis_persistence,
        snow_enabled,
        args.redis_image,
    )

    print("\nConfiguration complete.")
    if patcher.changed:
        print("Changed files:")
        for path in patcher.changed:
            print(f"  - {path.relative_to(patcher.root)}")
        print(f"Backups: {patcher.backup_root.relative_to(patcher.root)}")
    else:
        print("No file changes were necessary.")
    if patcher.warnings:
        print("Warnings:")
        for warning in patcher.warnings:
            print(f"  - {warning}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (FileNotFoundError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
