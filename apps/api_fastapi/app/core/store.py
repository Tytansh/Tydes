from __future__ import annotations

from collections.abc import Iterable
import hashlib
import hmac
import json
import secrets

from datetime import date, datetime, timedelta, timezone
from typing import Literal

from app.core.email_sender import send_password_reset_email, send_verification_email
from app.core.models import AdCard, Alert, BillingPlan, Dashboard, ForecastEntry, FriendProfile, Session, SocialComment, SocialEngagementState, SocialPost, SocialRepost, Spot, SurfWindowForecast, TideForecast, Trip, User, build_seed
from app.core.postgres_auth import PostgresAuthRepository
from app.core.runtime import public_media_url, state_file_path
from app.integrations.tide_providers.tidecheck import TideCheckProvider
from app.integrations.weather_providers.open_meteo import FREE_FORECAST_MAX_AGE, FRESH_FORECAST_MAX_AGE, OpenMeteoMarineProvider, PREVIEW_FORECAST_MAX_AGE

ForecastFreshness = Literal["fresh", "preview"]

_PASSWORD_HASH_ALGORITHM = "pbkdf2_sha256"
_PASSWORD_HASH_ITERATIONS = 260_000


class DemoStore:
    def __init__(self) -> None:
        seed = build_seed()
        self.user: User = seed["user"]  # type: ignore[assignment]
        self.spots: list[Spot] = list(seed["spots"])  # type: ignore[arg-type]
        self.forecasts: list[ForecastEntry] = list(seed["forecasts"])  # type: ignore[arg-type]
        self.trips: list[Trip] = list(seed["trips"])  # type: ignore[arg-type]
        self.alerts: list[Alert] = list(seed["alerts"])  # type: ignore[arg-type]
        self.plans: list[BillingPlan] = list(seed["plans"])  # type: ignore[arg-type]
        self.ads: list[AdCard] = list(seed["ads"])  # type: ignore[arg-type]
        self.friends: list[FriendProfile] = list(seed["friends"])  # type: ignore[arg-type]
        self.posts: list[SocialPost] = list(seed["posts"])  # type: ignore[arg-type]
        self.comments: list[SocialComment] = list(seed["comments"])  # type: ignore[arg-type]
        self.liked_post_ids: set[str] = set()
        self.reposts: list[SocialRepost] = []
        self.liked_comment_ids: set[str] = set()
        self.rsvp_post_ids: set[str] = set()
        self.weather_provider = OpenMeteoMarineProvider()
        self.tide_provider = TideCheckProvider()
        self.waitlist_emails: list[str] = []
        self.verified_emails: set[str] = set()
        self.email_verification_codes: dict[str, str] = {}
        self.password_reset_codes: dict[str, str] = {}
        self.auth_accounts: dict[str, dict[str, object]] = {}
        self.session_tokens: dict[str, str] = {}
        self.state_file = state_file_path()
        self._load_state()
        self.postgres_auth = PostgresAuthRepository.from_env()
        if self.postgres_auth is not None:
            self.postgres_auth.bootstrap_from_state(
                auth_accounts=self.auth_accounts,
                session_tokens=self.session_tokens,
                verified_emails=self.verified_emails,
                email_verification_codes=self.email_verification_codes,
                password_reset_codes=self.password_reset_codes,
            )
            self._sync_auth_from_postgres()

    def login(
        self,
        email: str,
        locale: str = "en",
        password: str | None = None,
    ) -> Session:
        normalized_email = email.strip().lower()
        account = self._get_auth_account(normalized_email)
        if account is not None:
            password_hash = str(account.get("password_hash", ""))
            if password is None or not _verify_password(password, password_hash):
                raise ValueError("Invalid email or password.")
            user_payload = account.get("user")
            if not isinstance(user_payload, dict):
                raise ValueError("Account profile is unavailable.")
            self.user = User.model_validate(user_payload)
            self.user.locale = locale
            self.user.premium = self.user.premium or self._email_has_premium_override(
                normalized_email
            )
            self.user.ads_enabled = not self.user.premium
            self._save_current_account_user()
            token = self._create_session_token(normalized_email)
            self._save_state()
            return Session(access_token=token, user=self.user)

        if password is not None and not self._can_use_demo_login(normalized_email):
            raise ValueError("No account found for that email.")

        self.user.email = email
        self.user.locale = locale
        self.user.premium = self._email_has_premium_override(normalized_email)
        self.user.email_verified = (
            self._is_verified_email(normalized_email)
            or normalized_email.endswith("@surftravel.app")
            or self.user.premium
        )
        self.user.ads_enabled = not self.user.premium
        self.capture_email(email)
        token = self._create_session_token(normalized_email)
        self._save_state()
        return Session(access_token=token, user=self.user)

    def signup(self, email: str, password: str, locale: str = "en") -> dict[str, object]:
        normalized_email = email.strip().lower()
        if self._get_auth_account(normalized_email) is not None:
            raise ValueError("An account already exists for that email.")

        verification_code = _generate_verification_code()
        email_result = send_verification_email(normalized_email, verification_code)
        if email_result.configured and not email_result.sent:
            raise RuntimeError("Could not send verification email right now.")

        user = self.user.model_copy(
            update={
                "id": f"usr_{secrets.token_urlsafe(8).replace('-', '').replace('_', '')}",
                "email": normalized_email,
                "locale": locale,
                "email_verified": False,
                "premium": self._email_has_premium_override(normalized_email),
                "display_name": "",
                "handle": "",
                "bio": "",
                "surf_skill": "",
                "avatar_url": None,
                "home_region": "",
                "ads_enabled": not self._email_has_premium_override(normalized_email),
                "favorite_spot_ids": [],
                "free_live_spot_id": None,
            }
        )
        self.user = user
        account = {
            "password_hash": _hash_password(password),
            "user": self.user.model_dump(mode="json"),
        }
        self._create_auth_account(normalized_email, account)
        self.capture_email(normalized_email)
        self._set_email_verification_code(normalized_email, verification_code)
        token = self._create_session_token(normalized_email)
        self._save_state()
        return {
            "session": Session(access_token=token, user=self.user),
            "verification_required": True,
            "verification_sent_to": normalized_email,
            "verification_hint": None
            if email_result.sent
            else f"Demo verification code: {verification_code}",
        }

    def verify_email(self, email: str, code: str) -> User:
        normalized_email = email.strip().lower()
        expected_code = self._get_email_verification_code(normalized_email)
        if expected_code is None and self.postgres_auth is None:
            expected_code = "123456"
        if code.strip() != expected_code:
            raise ValueError("Invalid verification code.")
        self._set_verified_email(normalized_email)
        self._delete_email_verification_code(normalized_email)
        account = self._get_auth_account(normalized_email)
        if account is not None and isinstance(account.get("user"), dict):
            user = User.model_validate(account["user"])
            user.email_verified = True
            self._save_auth_account_user(normalized_email, user)
            self.user = user
        elif self.user.email.strip().lower() == normalized_email:
            self.user.email_verified = True
        self._save_state()
        return self.user

    def logout(self) -> User:
        previous_email = self.user.email.strip().lower()
        if self.postgres_auth is not None:
            self.postgres_auth.delete_sessions_for_email(previous_email)
            self.session_tokens = {
                token_hash: email
                for token_hash, email in self.session_tokens.items()
                if email != previous_email
            }
        self.user.email = "demo@surftravel.app"
        self.user.display_name = "Tytan"
        self.user.handle = "ty"
        self.user.bio = "Looking for clean waves, easy travel days, and people to paddle out with."
        self.user.surf_skill = "intermediate"
        self.user.avatar_url = None
        self.user.locale = "en"
        self.user.premium = False
        self.user.email_verified = True
        self.user.ads_enabled = True
        self.user.free_live_spot_id = None
        self._save_state()
        return self.user

    def delete_current_account(self) -> User:
        normalized_email = self.user.email.strip().lower()
        self._delete_auth_account(normalized_email)
        self._delete_verified_email(normalized_email)
        self._delete_email_verification_code(normalized_email)
        self._delete_password_reset_code(normalized_email)
        self.session_tokens = {
            token_hash: email
            for token_hash, email in self.session_tokens.items()
            if email != normalized_email
        }
        return self.logout()

    def request_password_reset(self, email: str) -> dict[str, object]:
        normalized_email = email.strip().lower()
        account = self._get_auth_account(normalized_email)
        if account is None:
            return {
                "reset_sent_to": normalized_email,
                "reset_hint": None,
            }

        reset_code = _generate_verification_code()
        email_result = send_password_reset_email(normalized_email, reset_code)
        if email_result.configured and not email_result.sent:
            raise RuntimeError("Could not send password reset email right now.")
        self._set_password_reset_code(normalized_email, reset_code)
        self._save_state()
        return {
            "reset_sent_to": normalized_email,
            "reset_hint": None
            if email_result.sent
            else f"Demo password reset code: {reset_code}",
        }

    def reset_password(self, email: str, code: str, new_password: str) -> Session:
        normalized_email = email.strip().lower()
        account = self._get_auth_account(normalized_email)
        if account is None:
            raise ValueError("No account found for that email.")
        expected_code = self._get_password_reset_code(normalized_email)
        if expected_code is None or code.strip() != expected_code:
            raise ValueError("Invalid password reset code.")

        user_payload = account.get("user")
        if not isinstance(user_payload, dict):
            raise ValueError("Account profile is unavailable.")

        self._delete_password_reset_code(normalized_email)
        self._update_auth_password(normalized_email, _hash_password(new_password))
        self.user = User.model_validate(user_payload)
        token = self._create_session_token(normalized_email)
        self._save_state()
        return Session(access_token=token, user=self.user)

    def update_profile(
        self,
        *,
        display_name: str,
        handle: str,
        bio: str,
        surf_skill: str,
        home_region: str,
        avatar_url: str | None,
    ) -> User:
        self.user.display_name = display_name
        self.user.handle = handle
        self.user.bio = bio
        self.user.surf_skill = surf_skill
        self.user.home_region = home_region
        self.user.avatar_url = avatar_url
        for post in self.posts:
            if post.user_id == self.user.id:
                post.author_name = display_name
                post.author_handle = handle
                post.author_avatar_url = avatar_url
                post.author_premium = self.user.premium
        for comment in self.comments:
            if comment.user_id == self.user.id:
                comment.author_name = display_name
                comment.author_handle = handle
                comment.author_avatar_url = avatar_url
                comment.author_premium = self.user.premium
        self._save_state()
        return self.user

    def handle_exists(self, handle: str) -> bool:
        normalized = handle.strip().lower().lstrip("@")
        if not normalized:
            return False
        reserved_handles = {
            self._handle_from_name(friend.display_name)
            for friend in self.friends
        }
        post_handles = {
            (post.author_handle or "").strip().lower().lstrip("@")
            for post in self.posts
            if post.user_id != self.user.id
        }
        if normalized in reserved_handles or normalized in post_handles:
            return True
        if self.postgres_auth is not None:
            return self.postgres_auth.handle_exists(normalized, self.user.id)
        account_handles = {
            str((account.get("user") or {}).get("handle", ""))
            .strip()
            .lower()
            .lstrip("@")
            for account in self.auth_accounts.values()
            if isinstance(account.get("user"), dict)
            and (account.get("user") or {}).get("id") != self.user.id
        }
        return normalized in account_handles

    def _handle_from_name(self, name: str) -> str:
        return "".join(character for character in name.lower() if character.isalnum())

    def _display_name_from_email(self, email: str) -> str:
        local_part = email.split("@", 1)[0].split("+", 1)[0]
        words = [
            word
            for word in local_part.replace(".", " ").replace("_", " ").split()
            if word
        ]
        if not words:
            return "Surf Traveler"
        return " ".join(word.capitalize() for word in words)

    def _email_has_premium_override(self, email: str) -> bool:
        return "+premium" in email or email.startswith("premium@")

    def _can_use_demo_login(self, email: str) -> bool:
        return (
            email.endswith("@surftravel.app")
            or self._email_has_premium_override(email)
        )

    def _create_session_token(self, email: str) -> str:
        token = secrets.token_urlsafe(32)
        token_hash = _hash_token(token)
        normalized_email = email.strip().lower()
        self.session_tokens[token_hash] = normalized_email
        if (
            self.postgres_auth is not None
            and self.postgres_auth.get_account(normalized_email) is not None
        ):
            self.postgres_auth.create_session_hash(token_hash, normalized_email)
        return token

    def use_session_token(self, token: str) -> bool:
        token_hash = _hash_token(token)
        email = (
            self.postgres_auth.get_session_email(token_hash)
            if self.postgres_auth is not None
            else self.session_tokens.get(token_hash)
        )
        if email is None:
            return False
        account = self._get_auth_account(email)
        if account is None:
            return False
        user_payload = account.get("user")
        if not isinstance(user_payload, dict):
            return False
        self.user = User.model_validate(user_payload)
        return True

    def _save_current_account_user(self) -> None:
        normalized_email = self.user.email.strip().lower()
        self._save_auth_account_user(normalized_email, self.user)

    def _sync_auth_from_postgres(self) -> None:
        if self.postgres_auth is None:
            return
        snapshot = self.postgres_auth.snapshot()
        self.auth_accounts = snapshot.auth_accounts
        self.session_tokens = snapshot.session_tokens
        self.verified_emails = snapshot.verified_emails
        self.email_verification_codes = snapshot.email_verification_codes
        self.password_reset_codes = snapshot.password_reset_codes

    def _get_auth_account(self, email: str) -> dict[str, object] | None:
        normalized_email = email.strip().lower()
        if self.postgres_auth is not None:
            account = self.postgres_auth.get_account(normalized_email)
            if account is not None:
                self.auth_accounts[normalized_email] = account
            return account
        return self.auth_accounts.get(normalized_email)

    def _create_auth_account(
        self,
        email: str,
        account: dict[str, object],
    ) -> None:
        normalized_email = email.strip().lower()
        self.auth_accounts[normalized_email] = account
        if self.postgres_auth is not None:
            user_payload = account.get("user")
            if not isinstance(user_payload, dict):
                raise ValueError("Account profile is unavailable.")
            self.postgres_auth.create_account(
                normalized_email,
                str(account.get("password_hash", "")),
                user_payload,
            )

    def _save_auth_account_user(self, email: str, user: User) -> None:
        normalized_email = email.strip().lower()
        account = self.auth_accounts.get(normalized_email)
        if account is not None:
            account["user"] = user.model_dump(mode="json")
        if self.postgres_auth is not None and account is not None:
            self.postgres_auth.save_account_user(
                normalized_email,
                user.model_dump(mode="json"),
            )

    def _update_auth_password(self, email: str, password_hash: str) -> None:
        normalized_email = email.strip().lower()
        account = self.auth_accounts.get(normalized_email)
        if account is not None:
            account["password_hash"] = password_hash
        if self.postgres_auth is not None:
            self.postgres_auth.update_password(normalized_email, password_hash)

    def _delete_auth_account(self, email: str) -> None:
        normalized_email = email.strip().lower()
        self.auth_accounts.pop(normalized_email, None)
        if self.postgres_auth is not None:
            self.postgres_auth.delete_account(normalized_email)

    def _set_verified_email(self, email: str) -> None:
        normalized_email = email.strip().lower()
        self.verified_emails.add(normalized_email)
        if self.postgres_auth is not None:
            self.postgres_auth.set_verified_email(normalized_email)

    def _delete_verified_email(self, email: str) -> None:
        normalized_email = email.strip().lower()
        self.verified_emails.discard(normalized_email)
        if self.postgres_auth is not None:
            self.postgres_auth.delete_verified_email(normalized_email)

    def _is_verified_email(self, email: str) -> bool:
        normalized_email = email.strip().lower()
        if self.postgres_auth is not None:
            return self.postgres_auth.is_verified_email(normalized_email)
        return normalized_email in self.verified_emails

    def _set_email_verification_code(self, email: str, code: str) -> None:
        normalized_email = email.strip().lower()
        self.email_verification_codes[normalized_email] = code
        if self.postgres_auth is not None:
            self.postgres_auth.set_email_verification_code(normalized_email, code)

    def _get_email_verification_code(self, email: str) -> str | None:
        normalized_email = email.strip().lower()
        if self.postgres_auth is not None:
            return self.postgres_auth.get_email_verification_code(normalized_email)
        return self.email_verification_codes.get(normalized_email)

    def _delete_email_verification_code(self, email: str) -> None:
        normalized_email = email.strip().lower()
        self.email_verification_codes.pop(normalized_email, None)
        if self.postgres_auth is not None:
            self.postgres_auth.delete_email_verification_code(normalized_email)

    def _set_password_reset_code(self, email: str, code: str) -> None:
        normalized_email = email.strip().lower()
        self.password_reset_codes[normalized_email] = code
        if self.postgres_auth is not None:
            self.postgres_auth.set_password_reset_code(normalized_email, code)

    def _get_password_reset_code(self, email: str) -> str | None:
        normalized_email = email.strip().lower()
        if self.postgres_auth is not None:
            return self.postgres_auth.get_password_reset_code(normalized_email)
        return self.password_reset_codes.get(normalized_email)

    def _delete_password_reset_code(self, email: str) -> None:
        normalized_email = email.strip().lower()
        self.password_reset_codes.pop(normalized_email, None)
        if self.postgres_auth is not None:
            self.postgres_auth.delete_password_reset_code(normalized_email)

    def get_dashboard(self) -> Dashboard:
        featured = self._featured_spot()
        forecast = list(self.list_forecasts(featured.id))[0]
        trip = self.trips[0] if self.trips else None
        alerts_enabled = sum(1 for item in self.alerts if item.enabled)
        return Dashboard(
            featured_spot=featured,
            top_forecast=forecast,
            upcoming_trip=trip,
            alerts_enabled=alerts_enabled,
        )

    def list_spots(self, region: str | None = None) -> Iterable[Spot]:
        if region is None:
            return self.spots
        return [spot for spot in self.spots if spot.region.lower() == region.lower()]

    def get_spot(self, spot_id: str) -> Spot | None:
        return next((spot for spot in self.spots if spot.id == spot_id), None)

    def list_forecasts(
        self,
        spot_id: str | None = None,
        freshness: ForecastFreshness = "fresh",
    ) -> Iterable[ForecastEntry]:
        if spot_id is None:
            live_spot_id = None if self.user.premium else self.user.free_live_spot_id
            return [
                forecast
                for spot in self.spots
                for forecast in (
                    self._list_forecasts_for_spot(spot, freshness=freshness)
                    if self.user.premium or spot.id == live_spot_id
                    else [item for item in self.forecasts if item.spot_id == spot.id]
                )
            ]
        spot = self.get_spot(spot_id)
        if spot is None:
            return []
        return self._list_forecasts_for_spot(spot, freshness=freshness)

    def _list_forecasts_for_spot(
        self,
        spot: Spot,
        freshness: ForecastFreshness = "fresh",
    ) -> list[ForecastEntry]:
        can_access_live = self._can_access_live_forecast(spot.id)
        try:
            if can_access_live:
                max_cache_age = (
                    PREVIEW_FORECAST_MAX_AGE
                    if freshness == "preview"
                    else FRESH_FORECAST_MAX_AGE
                )
            else:
                max_cache_age = FREE_FORECAST_MAX_AGE
            forecasts = self.weather_provider.fetch_spot_forecast(
                spot,
                max_cache_age=max_cache_age,
            )
            if can_access_live:
                return forecasts
            return [self._locked_free_forecast_estimate(forecast) for forecast in forecasts]
        except Exception as error:
            print(f"Live forecast unavailable for {spot.id}: {error}")
            # Fall back to seeded values only if Open-Meteo is unreachable.
            return [item for item in self.forecasts if item.spot_id == spot.id]

    def _locked_free_forecast_estimate(self, forecast: ForecastEntry) -> ForecastEntry:
        wave_height = (
            forecast.wave_height_m
            if forecast.wave_height_m is not None
            else (
                (forecast.wave_height_min_m + forecast.wave_height_max_m) / 2
                if forecast.wave_height_min_m is not None
                and forecast.wave_height_max_m is not None
                else forecast.wave_height_max_m or forecast.wave_height_min_m or 0.0
            )
        )
        wave_min = max(0.0, round(wave_height - 0.1, 1))
        wave_max = round(wave_height + 0.1, 1)
        return forecast.model_copy(
            update={
                "wave_height_m": None,
                "wave_height_min_m": wave_min,
                "wave_height_max_m": wave_max,
                "period_s": None,
                "wind_kts": None,
                "wind_kts_min": None,
                "wind_kts_max": None,
                "swell_wave_height_m": None,
                "wind_wave_height_m": None,
                "sea_surface_temperature_c": None,
                "confidence": "estimated",
                "confidence_note": (
                    "Estimated from cached marine forecast data. "
                    "Premium unlocks fresher live wave, wind, period, tide, and water data."
                ),
            }
        )

    def get_tides(self, spot_id: str, start_day: date | None = None) -> TideForecast:
        spot = self.get_spot(spot_id)
        if spot is None:
            return TideForecast(
                spot_id=spot_id,
                available=False,
                note="Spot not found.",
            )
        if not self._can_access_live_data(spot_id):
            locked_note = (
                "Unlock this spot to view live tide data."
                if self.user.free_live_spot_id is None
                else "Premium subscription unlocks live tide data on more spots."
            )
            return TideForecast(
                spot_id=spot_id,
                available=False,
                note=locked_note,
            )
        try:
            return self.tide_provider.fetch_spot_tides(
                spot,
                start_day or date.today(),
                days=3,
            )
        except Exception as error:
            print(f"Live tide data unavailable for {spot.id}: {error}")
            return TideForecast(
                spot_id=spot_id,
                available=False,
                note="Live tide data is unavailable right now.",
            )

    def get_surf_window(self, spot_id: str) -> SurfWindowForecast:
        spot = self.get_spot(spot_id)
        if spot is None:
            return SurfWindowForecast(
                spot_id=spot_id,
                available=False,
                note="Spot not found.",
            )
        can_access_live = self._can_access_live_forecast(spot_id)
        if not can_access_live and spot_id != "spot_balangan":
            return SurfWindowForecast(
                spot_id=spot_id,
                available=False,
                note="Premium unlocks Best Time Today.",
            )
        try:
            window = self.weather_provider.fetch_spot_surf_window(
                spot,
                max_cache_age=FRESH_FORECAST_MAX_AGE
                if can_access_live
                else FREE_FORECAST_MAX_AGE,
            )
            if can_access_live:
                return window
            return window.model_copy(
                update={
                    "confidence": "estimated",
                    "note": "Balangan prototype. Premium unlocks this live window across more breaks.",
                }
            )
        except Exception as error:
            print(f"Best surf window unavailable for {spot.id}: {error}")
            return SurfWindowForecast(
                spot_id=spot.id,
                available=False,
                note="Best Time Today is unavailable right now.",
            )

    def list_trips(self) -> Iterable[Trip]:
        return self.trips

    def add_trip(self, trip: Trip) -> Trip:
        self.trips.append(trip)
        self._save_state()
        return trip

    def list_alerts(self) -> Iterable[Alert]:
        self.evaluate_alerts()
        return self.alerts

    def add_alert(self, alert: Alert) -> Alert:
        self._evaluate_alert(alert)
        self.alerts.append(alert)
        self._save_state()
        return alert

    def update_alert_enabled(self, alert_id: str, enabled: bool) -> Alert | None:
        return self.update_alert(alert_id, {"enabled": enabled})

    def update_alert(self, alert_id: str, values: dict[str, object]) -> Alert | None:
        alert = next((item for item in self.alerts if item.id == alert_id), None)
        if alert is None:
            return None
        for key, value in values.items():
            if hasattr(alert, key):
                setattr(alert, key, value)
        self._evaluate_alert(alert)
        self._save_state()
        return alert

    def evaluate_alerts(self) -> list[Alert]:
        for alert in self.alerts:
            self._evaluate_alert(alert)
        self._save_state()
        return self.alerts

    def delete_alert(self, alert_id: str) -> bool:
        before = len(self.alerts)
        self.alerts = [item for item in self.alerts if item.id != alert_id]
        if len(self.alerts) != before:
            self._save_state()
        return len(self.alerts) != before

    def list_plans(self) -> Iterable[BillingPlan]:
        return self.plans

    def set_premium_status(self, active: bool) -> User:
        premium_active = active or self._email_has_premium_override(self.user.email)
        self.user.premium = premium_active
        self.user.ads_enabled = not premium_active
        for post in self.posts:
            if post.user_id == self.user.id:
                post.author_premium = premium_active
        for comment in self.comments:
            if comment.user_id == self.user.id:
                comment.author_premium = premium_active
        self._save_state()
        return self.user

    def list_ads(self, placement: str | None = None) -> Iterable[AdCard]:
        if not self.user.ads_enabled:
            return []
        if placement is None:
            return self.ads
        return [ad for ad in self.ads if ad.placement == placement]

    def list_favorite_spots(self) -> Iterable[Spot]:
        favorite_ids = set(self.user.favorite_spot_ids)
        return [spot for spot in self.spots if spot.id in favorite_ids]

    def add_favorite_spot(self, spot_id: str) -> list[str]:
        if self.get_spot(spot_id) is None:
            return self.user.favorite_spot_ids
        if spot_id not in self.user.favorite_spot_ids:
            self.user.favorite_spot_ids.append(spot_id)
            self._save_state()
        return self.user.favorite_spot_ids

    def remove_favorite_spot(self, spot_id: str) -> list[str]:
        self.user.favorite_spot_ids = [
            favorite_id
            for favorite_id in self.user.favorite_spot_ids
            if favorite_id != spot_id
        ]
        self._save_state()
        return self.user.favorite_spot_ids

    def set_free_live_spot(self, spot_id: str) -> User | None:
        if self.get_spot(spot_id) is None:
            return None
        if self.user.premium:
            self.user.free_live_spot_id = spot_id
            self._save_state()
            return self.user
        if (
            self.user.free_live_spot_id is not None
            and self.user.free_live_spot_id != spot_id
        ):
            raise ValueError("Free live spot already selected")
        self.user.free_live_spot_id = spot_id
        self._save_state()
        return self.user

    def capture_email(self, email: str) -> dict[str, str]:
        normalized = email.strip().lower()
        if normalized and normalized not in self.waitlist_emails:
            self.waitlist_emails.append(normalized)
            self._save_state()
        return {"email": normalized, "status": "captured"}

    def list_friends(self) -> Iterable[FriendProfile]:
        return self.friends

    def list_auth_users(self) -> list[dict[str, object]]:
        if self.postgres_auth is not None:
            self._sync_auth_from_postgres()
        users: list[dict[str, object]] = []
        for email, account in sorted(self.auth_accounts.items()):
            user = account.get("user")
            if not isinstance(user, dict):
                continue
            users.append(
                {
                    "email": email,
                    "user_id": user.get("id"),
                    "handle": user.get("handle") or "",
                    "display_name": user.get("display_name") or "",
                    "email_verified": bool(user.get("email_verified")),
                    "premium": bool(user.get("premium")),
                }
            )
        return users

    def list_posts(self) -> Iterable[SocialPost]:
        return sorted(self.posts, key=lambda post: post.created_at, reverse=True)

    def add_post(self, post: SocialPost) -> SocialPost:
        self.posts.append(post)
        self._save_state()
        return post

    def social_engagement_state(self) -> SocialEngagementState:
        return SocialEngagementState(
            liked_post_ids=sorted(self.liked_post_ids),
            reposted_post_ids=[repost.post_id for repost in self.reposts],
            reposts=sorted(
                self.reposts,
                key=lambda repost: repost.created_at,
                reverse=True,
            ),
            liked_comment_ids=sorted(self.liked_comment_ids),
            rsvp_post_ids=sorted(self.rsvp_post_ids),
            comments=sorted(
                self.comments,
                key=lambda comment: comment.created_at,
                reverse=True,
            ),
        )

    def set_post_like(self, post_id: str, liked: bool) -> SocialEngagementState | None:
        if self.get_post(post_id) is None:
            return None
        if liked:
            self.liked_post_ids.add(post_id)
        else:
            self.liked_post_ids.discard(post_id)
        self._save_state()
        return self.social_engagement_state()

    def set_post_repost(self, post_id: str, reposted: bool) -> SocialEngagementState | None:
        if self.get_post(post_id) is None:
            return None
        self.reposts = [
            item for item in self.reposts if item.post_id != post_id
        ]
        if reposted:
            self.reposts.insert(
                0,
                SocialRepost(post_id=post_id, created_at=datetime.now(timezone.utc)),
            )
        self._save_state()
        return self.social_engagement_state()

    def set_event_rsvp(self, post_id: str, joined: bool) -> SocialEngagementState | None:
        post = self.get_post(post_id)
        if post is None:
            return None
        if post.post_type not in {"surf_plan", "looking_for_buddy"}:
            return None
        if joined:
            self.rsvp_post_ids.add(post_id)
        else:
            self.rsvp_post_ids.discard(post_id)
        self._save_state()
        return self.social_engagement_state()

    def add_comment(
        self,
        *,
        post_id: str,
        comment_id: str,
        text: str,
        reply_to_comment_id: str | None,
    ) -> SocialEngagementState | None:
        if self.get_post(post_id) is None:
            return None
        if reply_to_comment_id is not None and self.get_comment(reply_to_comment_id) is None:
            return None
        self.comments.append(
            SocialComment(
                id=comment_id,
                post_id=post_id,
                user_id=self.user.id,
                author_name=self.user.display_name,
                author_handle=self.user.handle,
                author_avatar_url=self.user.avatar_url,
                author_premium=self.user.premium,
                text=text,
                reply_to_comment_id=reply_to_comment_id,
                created_at=datetime.now(timezone.utc),
            )
        )
        self._save_state()
        return self.social_engagement_state()

    def delete_comment(self, comment_id: str) -> SocialEngagementState | None:
        comment = self.get_comment(comment_id)
        if comment is None:
            return None
        if comment.user_id != self.user.id:
            post = self.get_post(comment.post_id)
            if post is None or post.user_id != self.user.id:
                return None
        self.comments = [
            item
            for item in self.comments
            if item.id != comment_id and item.reply_to_comment_id != comment_id
        ]
        self.liked_comment_ids.discard(comment_id)
        self._save_state()
        return self.social_engagement_state()

    def set_comment_like(
        self,
        comment_id: str,
        liked: bool,
    ) -> SocialEngagementState | None:
        if self.get_comment(comment_id) is None:
            return None
        if liked:
            self.liked_comment_ids.add(comment_id)
        else:
            self.liked_comment_ids.discard(comment_id)
        self._save_state()
        return self.social_engagement_state()

    def get_post(self, post_id: str) -> SocialPost | None:
        return next((post for post in self.posts if post.id == post_id), None)

    def get_comment(self, comment_id: str) -> SocialComment | None:
        return next(
            (comment for comment in self.comments if comment.id == comment_id),
            None,
        )

    def _load_state(self) -> None:
        if not self.state_file.exists():
            return
        try:
            data = json.loads(self.state_file.read_text())
        except (OSError, json.JSONDecodeError):
            return

        user_data = data.get("user")
        if isinstance(user_data, dict):
            merged = self.user.model_dump(mode="json")
            merged.update(user_data)
            self.user = User.model_validate(merged)
            self._repair_demo_user_profile()

        alerts_data = data.get("alerts")
        if isinstance(alerts_data, list):
            self.alerts = [Alert.model_validate(item) for item in alerts_data]

        posts_data = data.get("posts")
        if isinstance(posts_data, list):
            seed_posts = {post.id: post for post in self.posts}
            stored_posts = [SocialPost.model_validate(item) for item in posts_data]
            merged_posts = {post.id: post for post in stored_posts}
            merged_posts.update(seed_posts)
            self.posts = list(merged_posts.values())
            self._sync_demo_user_post_snapshots()

        comments_data = data.get("comments")
        if isinstance(comments_data, list):
            seed_comments = {comment.id: comment for comment in self.comments}
            stored_comments = [
                SocialComment.model_validate(item) for item in comments_data
            ]
            merged_comments = {comment.id: comment for comment in stored_comments}
            merged_comments.update(seed_comments)
            self.comments = list(merged_comments.values())

        engagement_data = data.get("social_engagement")
        if isinstance(engagement_data, dict):
            state = SocialEngagementState.model_validate(engagement_data)
            self.liked_post_ids = set(state.liked_post_ids)
            if state.reposts:
                self.reposts = list(state.reposts)
            else:
                self.reposts = [
                    SocialRepost(
                        post_id=post_id,
                        created_at=(self.get_post(post_id) or self.posts[0]).created_at,
                    )
                    for post_id in dict.fromkeys(state.reposted_post_ids)
                    if self.get_post(post_id) is not None and self.posts
                ]
            self.liked_comment_ids = set(state.liked_comment_ids)
            self.rsvp_post_ids = set(state.rsvp_post_ids)

        emails = data.get("waitlist_emails")
        if isinstance(emails, list):
            self.waitlist_emails = [
                str(email).strip().lower()
                for email in emails
                if str(email).strip()
            ]

        verified_emails = data.get("verified_emails")
        if isinstance(verified_emails, list):
            self.verified_emails = {
                str(email).strip().lower()
                for email in verified_emails
                if str(email).strip()
            }

        password_reset_codes = data.get("password_reset_codes")
        if isinstance(password_reset_codes, dict):
            self.password_reset_codes = {
                str(email).strip().lower(): str(code)
                for email, code in password_reset_codes.items()
                if str(email).strip() and str(code).strip()
            }

        auth_accounts = data.get("auth_accounts")
        if isinstance(auth_accounts, dict):
            self.auth_accounts = {
                str(email).strip().lower(): account
                for email, account in auth_accounts.items()
                if isinstance(account, dict) and str(email).strip()
            }

        session_tokens = data.get("session_tokens")
        if isinstance(session_tokens, dict):
            self.session_tokens = {
                str(token_hash): str(email).strip().lower()
                for token_hash, email in session_tokens.items()
                if str(token_hash).strip() and str(email).strip()
            }

    def _repair_demo_user_profile(self) -> None:
        if self.user.id != "usr_demo":
            return
        if self.user.handle == "tytan":
            self.user.handle = "ty"
        if self.user.avatar_url is None:
            self.user.avatar_url = public_media_url("media_c19db8e5b6_thumb.jpg")

    def _sync_demo_user_post_snapshots(self) -> None:
        if self.user.id != "usr_demo":
            return
        for post in self.posts:
            if post.user_id == self.user.id:
                post.author_name = self.user.display_name
                post.author_handle = self.user.handle
                post.author_avatar_url = self.user.avatar_url
                post.author_premium = self.user.premium
        for comment in self.comments:
            if comment.user_id == self.user.id:
                comment.author_name = self.user.display_name
                comment.author_handle = self.user.handle
                comment.author_avatar_url = self.user.avatar_url
                comment.author_premium = self.user.premium

    def _save_state(self) -> None:
        self._repair_demo_user_profile()
        self._sync_demo_user_post_snapshots()
        self._save_current_account_user()
        payload = {
            "user": self.user.model_dump(mode="json"),
            "alerts": [alert.model_dump(mode="json") for alert in self.alerts],
            "posts": [post.model_dump(mode="json") for post in self.posts],
            "comments": [
                comment.model_dump(mode="json") for comment in self.comments
            ],
            "social_engagement": self.social_engagement_state().model_dump(
                mode="json"
            ),
            "waitlist_emails": self.waitlist_emails,
            "verified_emails": sorted(self.verified_emails),
            "password_reset_codes": self.password_reset_codes,
            "auth_accounts": self.auth_accounts,
            "session_tokens": self.session_tokens,
        }
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        self.state_file.write_text(json.dumps(payload, indent=2))

    def _can_access_live_forecast(self, spot_id: str) -> bool:
        return self._can_access_live_data(spot_id)

    def _featured_spot(self) -> Spot:
        if not self.user.premium and self.user.free_live_spot_id is not None:
            spot = self.get_spot(self.user.free_live_spot_id)
            if spot is not None:
                return spot
        return self.spots[0]

    def _can_access_live_data(self, spot_id: str) -> bool:
        return self.user.premium or self.user.free_live_spot_id == spot_id

    def _evaluate_alert(self, alert: Alert) -> None:
        now = datetime.now(timezone.utc)
        previous_status = alert.status
        alert.last_evaluated_at = now

        if not alert.enabled:
            alert.status = "watching"
            alert.status_reason = "Alert is turned off."
            alert.next_check_at = now + timedelta(hours=4)
            return

        spot = self.get_spot(alert.spot_id)
        if spot is None:
            alert.status = "waiting"
            alert.status_reason = "Spot not found."
            alert.next_check_at = now + timedelta(hours=4)
            return

        unmet: list[str] = []
        waiting: list[str] = []
        forecast = next(iter(self.list_forecasts(alert.spot_id)), None)

        if alert.wave_enabled:
            wave_value = None
            if forecast is not None:
                wave_value = (
                    forecast.wave_height_max_m
                    or forecast.wave_height_m
                    or forecast.wave_height_min_m
                )
            if wave_value is None:
                waiting.append("wave data")
            elif alert.min_wave_height_m is not None and wave_value < alert.min_wave_height_m:
                unmet.append(f"wave below {alert.min_wave_height_m}m")

        if alert.wind_enabled:
            wind_value = None
            if forecast is not None:
                wind_value = (
                    forecast.wind_kts_max
                    or forecast.wind_kts
                    or forecast.wind_kts_min
                )
            if wind_value is None:
                waiting.append("wind data")
            elif alert.max_wind_kts is not None and wind_value > alert.max_wind_kts:
                unmet.append(f"wind above {alert.max_wind_kts}kts")

        if alert.tide_enabled:
            tide = self.get_tides(alert.spot_id, now.date())
            if not tide.available or alert.tide_type is None or alert.tide_offset_hours is None:
                waiting.append("tide data")
            else:
                matching_events = [
                    event for event in tide.events if event.type == alert.tide_type
                ]
                if not matching_events:
                    waiting.append("tide events")
                else:
                    target_times = [
                        event.time + timedelta(hours=alert.tide_offset_hours)
                        for event in matching_events
                    ]
                    in_window = any(
                        abs((target - now).total_seconds()) <= 90 * 60
                        for target in target_times
                    )
                    if not in_window:
                        tide_label = "high tide" if alert.tide_type == "high" else "low tide"
                        offset = alert.tide_offset_hours
                        if offset == 0:
                            unmet.append(f"not at {tide_label}")
                        elif offset is not None and offset < 0:
                            unmet.append(f"not {abs(offset)}h before {tide_label}")
                        else:
                            unmet.append(f"not {abs(offset or 0)}h after {tide_label}")

        if waiting:
            alert.status = "waiting"
            alert.status_reason = f"Waiting on {', '.join(waiting)}."
        elif unmet:
            alert.status = "watching"
            alert.status_reason = "Watching: " + " • ".join(unmet)
        else:
            alert.status = "triggered"
            alert.status_reason = "Conditions match your alert right now."
            if previous_status != "triggered":
                alert.last_triggered_at = now

        alert.next_check_at = now + timedelta(hours=1 if alert.tide_enabled else 4)


def _hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        salt.encode("utf-8"),
        _PASSWORD_HASH_ITERATIONS,
    ).hex()
    return f"{_PASSWORD_HASH_ALGORITHM}${_PASSWORD_HASH_ITERATIONS}${salt}${digest}"


def _verify_password(password: str, password_hash: str) -> bool:
    try:
        algorithm, iterations, salt, expected_digest = password_hash.split("$", 3)
        if algorithm != _PASSWORD_HASH_ALGORITHM:
            return False
        actual_digest = hashlib.pbkdf2_hmac(
            "sha256",
            password.encode("utf-8"),
            salt.encode("utf-8"),
            int(iterations),
        ).hex()
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(actual_digest, expected_digest)


def _generate_verification_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


store = DemoStore()
