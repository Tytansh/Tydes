from __future__ import annotations

from dataclasses import dataclass
import os
from typing import Any


@dataclass(frozen=True)
class AuthSnapshot:
    auth_accounts: dict[str, dict[str, object]]
    session_tokens: dict[str, str]
    verified_emails: set[str]
    email_verification_codes: dict[str, str]
    password_reset_codes: dict[str, str]


class PostgresAuthRepository:
    def __init__(self, database_url: str) -> None:
        self.database_url = database_url
        self._ensure_schema()

    @classmethod
    def from_env(cls) -> "PostgresAuthRepository | None":
        database_url = os.getenv("DATABASE_URL", "").strip()
        if not database_url:
            return None
        return cls(database_url)

    def bootstrap_from_state(
        self,
        *,
        auth_accounts: dict[str, dict[str, object]],
        session_tokens: dict[str, str],
        verified_emails: set[str],
        email_verification_codes: dict[str, str],
        password_reset_codes: dict[str, str],
    ) -> None:
        if self.account_count() > 0:
            return
        for email, account in auth_accounts.items():
            user = account.get("user")
            password_hash = str(account.get("password_hash", ""))
            if not isinstance(user, dict) or not password_hash:
                continue
            self.create_account(email, password_hash, user)
        migrated_emails = {
            email
            for email in auth_accounts
            if self.get_account(email) is not None
        }
        for token_hash, email in session_tokens.items():
            if _normalize_email(email) in migrated_emails:
                self.create_session_hash(token_hash, email)
        for email in verified_emails:
            if _normalize_email(email) in migrated_emails:
                self.set_verified_email(email)
        for email, code in email_verification_codes.items():
            if _normalize_email(email) in migrated_emails:
                self.set_email_verification_code(email, code)
        for email, code in password_reset_codes.items():
            if _normalize_email(email) in migrated_emails:
                self.set_password_reset_code(email, code)

    def snapshot(self) -> AuthSnapshot:
        with self._connect() as connection:
            rows = connection.execute(
                "SELECT email, password_hash, user_payload FROM auth_accounts"
            ).fetchall()
            accounts = {
                row["email"]: {
                    "password_hash": row["password_hash"],
                    "user": dict(row["user_payload"]),
                }
                for row in rows
            }
            token_rows = connection.execute(
                "SELECT token_hash, email FROM auth_session_tokens"
            ).fetchall()
            verified_rows = connection.execute(
                "SELECT email FROM auth_verified_emails"
            ).fetchall()
            verification_rows = connection.execute(
                "SELECT email, code FROM auth_email_verification_codes"
            ).fetchall()
            reset_rows = connection.execute(
                "SELECT email, code FROM auth_password_reset_codes"
            ).fetchall()
        return AuthSnapshot(
            auth_accounts=accounts,
            session_tokens={
                row["token_hash"]: row["email"]
                for row in token_rows
            },
            verified_emails={row["email"] for row in verified_rows},
            email_verification_codes={
                row["email"]: row["code"]
                for row in verification_rows
            },
            password_reset_codes={
                row["email"]: row["code"]
                for row in reset_rows
            },
        )

    def account_count(self) -> int:
        with self._connect() as connection:
            row = connection.execute("SELECT COUNT(*) AS count FROM auth_accounts").fetchone()
        return int(row["count"])

    def get_account(self, email: str) -> dict[str, object] | None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT password_hash, user_payload
                FROM auth_accounts
                WHERE email = %s
                """,
                (normalized_email,),
            ).fetchone()
        if row is None:
            return None
        return {
            "password_hash": row["password_hash"],
            "user": dict(row["user_payload"]),
        }

    def create_account(
        self,
        email: str,
        password_hash: str,
        user_payload: dict[str, Any],
    ) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO auth_accounts (email, password_hash, user_payload)
                VALUES (%s, %s, %s)
                ON CONFLICT (email) DO NOTHING
                """,
                (normalized_email, password_hash, self._jsonb(user_payload)),
            )

    def save_account_user(self, email: str, user_payload: dict[str, Any]) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE auth_accounts
                SET user_payload = %s, updated_at = NOW()
                WHERE email = %s
                """,
                (self._jsonb(user_payload), normalized_email),
            )

    def update_password(self, email: str, password_hash: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                """
                UPDATE auth_accounts
                SET password_hash = %s, updated_at = NOW()
                WHERE email = %s
                """,
                (password_hash, normalized_email),
            )

    def delete_account(self, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM auth_accounts WHERE email = %s",
                (normalized_email,),
            )

    def handle_exists(self, handle: str, current_user_id: str) -> bool:
        normalized_handle = handle.strip().lower().lstrip("@")
        if not normalized_handle:
            return False
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM auth_accounts
                    WHERE lower(coalesce(user_payload->>'handle', '')) = %s
                      AND coalesce(user_payload->>'id', '') <> %s
                ) AS exists
                """,
                (normalized_handle, current_user_id),
            ).fetchone()
        return bool(row["exists"])

    def create_session_hash(self, token_hash: str, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO auth_session_tokens (token_hash, email)
                VALUES (%s, %s)
                ON CONFLICT (token_hash) DO UPDATE
                SET email = EXCLUDED.email, created_at = NOW()
                """,
                (token_hash, normalized_email),
            )

    def get_session_email(self, token_hash: str) -> str | None:
        with self._connect() as connection:
            row = connection.execute(
                "SELECT email FROM auth_session_tokens WHERE token_hash = %s",
                (token_hash,),
            ).fetchone()
        if row is None:
            return None
        return str(row["email"])

    def delete_sessions_for_email(self, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM auth_session_tokens WHERE email = %s",
                (normalized_email,),
            )

    def set_verified_email(self, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                """
                INSERT INTO auth_verified_emails (email)
                VALUES (%s)
                ON CONFLICT (email) DO NOTHING
                """,
                (normalized_email,),
            )

    def delete_verified_email(self, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                "DELETE FROM auth_verified_emails WHERE email = %s",
                (normalized_email,),
            )

    def is_verified_email(self, email: str) -> bool:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            row = connection.execute(
                """
                SELECT EXISTS (
                    SELECT 1 FROM auth_verified_emails WHERE email = %s
                ) AS exists
                """,
                (normalized_email,),
            ).fetchone()
        return bool(row["exists"])

    def set_email_verification_code(self, email: str, code: str) -> None:
        self._upsert_code("auth_email_verification_codes", email, code)

    def get_email_verification_code(self, email: str) -> str | None:
        return self._get_code("auth_email_verification_codes", email)

    def delete_email_verification_code(self, email: str) -> None:
        self._delete_code("auth_email_verification_codes", email)

    def set_password_reset_code(self, email: str, code: str) -> None:
        self._upsert_code("auth_password_reset_codes", email, code)

    def get_password_reset_code(self, email: str) -> str | None:
        return self._get_code("auth_password_reset_codes", email)

    def delete_password_reset_code(self, email: str) -> None:
        self._delete_code("auth_password_reset_codes", email)

    def _upsert_code(self, table: str, email: str, code: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                f"""
                INSERT INTO {table} (email, code)
                VALUES (%s, %s)
                ON CONFLICT (email) DO UPDATE
                SET code = EXCLUDED.code, created_at = NOW()
                """,
                (normalized_email, code),
            )

    def _get_code(self, table: str, email: str) -> str | None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            row = connection.execute(
                f"SELECT code FROM {table} WHERE email = %s",
                (normalized_email,),
            ).fetchone()
        if row is None:
            return None
        return str(row["code"])

    def _delete_code(self, table: str, email: str) -> None:
        normalized_email = _normalize_email(email)
        with self._connect() as connection:
            connection.execute(
                f"DELETE FROM {table} WHERE email = %s",
                (normalized_email,),
            )

    def _connect(self):
        import psycopg
        from psycopg.rows import dict_row

        return psycopg.connect(
            self.database_url,
            autocommit=True,
            row_factory=dict_row,
        )

    def _jsonb(self, value: dict[str, Any]):
        from psycopg.types.json import Jsonb

        return Jsonb(value)

    def _ensure_schema(self) -> None:
        with self._connect() as connection:
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS auth_accounts (
                    email TEXT PRIMARY KEY,
                    password_hash TEXT NOT NULL,
                    user_payload JSONB NOT NULL,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE UNIQUE INDEX IF NOT EXISTS auth_accounts_handle_unique
                ON auth_accounts (lower(user_payload->>'handle'))
                WHERE coalesce(user_payload->>'handle', '') <> ''
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS auth_session_tokens (
                    token_hash TEXT PRIMARY KEY,
                    email TEXT NOT NULL REFERENCES auth_accounts(email) ON DELETE CASCADE,
                    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            connection.execute(
                """
                CREATE TABLE IF NOT EXISTS auth_verified_emails (
                    email TEXT PRIMARY KEY REFERENCES auth_accounts(email) ON DELETE CASCADE,
                    verified_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            self._create_code_table(connection, "auth_email_verification_codes")
            self._create_code_table(connection, "auth_password_reset_codes")

    def _create_code_table(self, connection, table: str) -> None:
        connection.execute(
            f"""
            CREATE TABLE IF NOT EXISTS {table} (
                email TEXT PRIMARY KEY REFERENCES auth_accounts(email) ON DELETE CASCADE,
                code TEXT NOT NULL,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
            )
            """
        )


def _normalize_email(email: str) -> str:
    return email.strip().lower()
