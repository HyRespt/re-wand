#!/usr/bin/env python3
"""Create or promote a moderator account.

Input is one JSON object on stdin. The password is never accepted as a command
line argument and is never written to disk by this script.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from typing import Any

import asyncpg
import bcrypt

from dash.crypto import Crypto


def fail(message: str) -> None:
    print(json.dumps({"ok": False, "error": message}))
    raise SystemExit(1)


def validate(payload: dict[str, Any]) -> tuple[str, str, str, int]:
    nickname = str(payload.get("name", "")).strip()
    email = str(payload.get("email", "")).strip()
    password = str(payload.get("password", ""))
    try:
        color = int(payload.get("color", 1))
    except (TypeError, ValueError):
        fail("Color must be a number from 1 to 16.")
    if len(nickname) < 4 or len(nickname) > 12:
        fail("Penguin name must be between 4 and 12 characters.")
    if not all(character.isalnum() or character.isspace() for character in nickname):
        fail("Penguin name may contain only letters, numbers, and spaces.")
    if re.search(r"[A-Za-z]", nickname) is None:
        fail("Penguin name must contain at least one letter.")
    if not email or "@" not in email:
        fail("A valid email address is required.")
    if len(password) < 4:
        fail("Password must contain at least four characters.")
    if color not in range(1, 17):
        fail("Color must be from 1 to 16.")
    return nickname.title(), email, password, color


def make_password_hash(password: str) -> str:
    static_key = os.environ.get("DASH_STATIC_KEY", "houdini")
    password_hash = Crypto.hash(password).upper()
    password_hash = Crypto.get_login_hash(password_hash, rndk=static_key)
    return bcrypt.hashpw(password_hash.encode("utf-8"), bcrypt.gensalt(12)).decode("utf-8")


async def connect() -> asyncpg.Connection:
    settings = {
        "host": os.environ.get("POSTGRES_HOST", "db"),
        "port": int(os.environ.get("POSTGRES_PORT", "5432")),
        "user": os.environ.get("POSTGRES_USER", "postgres"),
        "password": os.environ.get("POSTGRES_PASSWORD"),
        "database": os.environ.get("POSTGRES_DBNAME", os.environ.get("POSTGRES_USER", "postgres")),
    }
    last_error: Exception | None = None
    for _ in range(60):
        try:
            return await asyncpg.connect(**settings)
        except Exception as exc:  # database may still be starting
            last_error = exc
            await asyncio.sleep(1)
    raise RuntimeError(f"Could not connect to PostgreSQL: {last_error}")


async def run() -> None:
    try:
        payload = json.load(sys.stdin)
    except Exception as exc:
        fail(f"Invalid JSON input: {exc}")
    nickname, email, password, color = validate(payload)
    username = nickname.lower()
    password_hash = make_password_hash(password)

    connection = await connect()
    try:
        async with connection.transaction():
            color_exists = await connection.fetchval("SELECT EXISTS(SELECT 1 FROM item WHERE id = $1)", color)
            if not color_exists:
                fail(f"Color item {color} is not present in the database.")

            existing = await connection.fetchrow(
                "SELECT id FROM penguin WHERE lower(username) = lower($1) LIMIT 1",
                username,
            )
            created = existing is None
            if created:
                penguin_id = await connection.fetchval(
                    """
                    INSERT INTO penguin (
                        username, nickname, password, email, active, moderator, color,
                        approval_en, approval_pt, approval_fr, approval_es, approval_de, approval_ru
                    ) VALUES ($1, $2, $3, $4, TRUE, TRUE, $5, TRUE, TRUE, TRUE, TRUE, TRUE, TRUE)
                    RETURNING id
                    """,
                    username,
                    nickname,
                    password_hash,
                    email,
                    color,
                )
            else:
                penguin_id = existing["id"]
                await connection.execute(
                    """
                    UPDATE penguin
                    SET nickname = $2,
                        password = $3,
                        email = $4,
                        active = TRUE,
                        moderator = TRUE,
                        color = $5,
                        approval_en = TRUE,
                        approval_pt = TRUE,
                        approval_fr = TRUE,
                        approval_es = TRUE,
                        approval_de = TRUE,
                        approval_ru = TRUE
                    WHERE id = $1
                    """,
                    penguin_id,
                    nickname,
                    password_hash,
                    email,
                    color,
                )

            await connection.execute(
                """
                INSERT INTO penguin_item (penguin_id, item_id)
                VALUES ($1, $2)
                ON CONFLICT DO NOTHING
                """,
                penguin_id,
                color,
            )
            await connection.execute("DELETE FROM activation_key WHERE penguin_id = $1", penguin_id)

            if created:
                postcard_exists = await connection.fetchval(
                    "SELECT EXISTS(SELECT 1 FROM postcard WHERE id = 125)"
                )
                if postcard_exists:
                    await connection.execute(
                        "INSERT INTO penguin_postcard (penguin_id, sender_id, postcard_id) VALUES ($1, NULL, 125)",
                        penguin_id,
                    )
    finally:
        await connection.close()

    print(json.dumps({"ok": True, "created": created, "penguin_id": penguin_id, "nickname": nickname}))


if __name__ == "__main__":
    try:
        asyncio.run(run())
    except Exception as exc:
        fail(str(exc))
