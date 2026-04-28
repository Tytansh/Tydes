from __future__ import annotations

from collections.abc import Iterable
import json
from pathlib import Path

from datetime import date, datetime, timedelta, timezone

from app.core.models import AdCard, Alert, BillingPlan, Dashboard, ForecastEntry, FriendProfile, Session, SocialPost, Spot, TideForecast, Trip, User, build_seed
from app.integrations.tide_providers.tidecheck import TideCheckProvider
from app.integrations.weather_providers.open_meteo import OpenMeteoMarineProvider


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
        self.weather_provider = OpenMeteoMarineProvider()
        self.tide_provider = TideCheckProvider()
        self.waitlist_emails: list[str] = []
        self.state_file = Path(__file__).resolve().parents[2] / "data" / "demo_state.json"
        self._load_state()

    def login(self, email: str, locale: str = "en") -> Session:
        self.user.email = email
        self.user.locale = locale
        normalized_email = email.strip().lower()
        self.user.premium = (
            "+premium" in normalized_email
            or normalized_email.startswith("premium@")
        )
        self.user.ads_enabled = not self.user.premium
        self.capture_email(email)
        self._save_state()
        return Session(access_token="demo-access-token", user=self.user)

    def logout(self) -> User:
        self.user.email = "demo@surftravel.app"
        self.user.display_name = "Tytan"
        self.user.handle = "tytan"
        self.user.bio = "Looking for clean waves, easy travel days, and people to paddle out with."
        self.user.surf_skill = "intermediate"
        self.user.avatar_url = None
        self.user.locale = "en"
        self.user.premium = False
        self.user.ads_enabled = True
        self.user.free_live_spot_id = None
        self._save_state()
        return self.user

    def update_profile(
        self,
        *,
        display_name: str,
        handle: str,
        bio: str,
        surf_skill: str,
        avatar_url: str | None,
    ) -> User:
        self.user.display_name = display_name
        self.user.handle = handle
        self.user.bio = bio
        self.user.surf_skill = surf_skill
        self.user.avatar_url = avatar_url
        self._save_state()
        return self.user

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

    def list_forecasts(self, spot_id: str | None = None) -> Iterable[ForecastEntry]:
        if spot_id is None:
            return self.forecasts
        spot = self.get_spot(spot_id)
        if spot is None:
            return []
        if not self._can_access_live_forecast(spot_id):
            return [item for item in self.forecasts if item.spot_id == spot_id]
        try:
            return self.weather_provider.fetch_spot_forecast(spot)
        except Exception as error:
            print(f"Live forecast unavailable for {spot.id}: {error}")
            # Fall back to estimated ranges if the provider is unreachable or rate-limited.
            return [item for item in self.forecasts if item.spot_id == spot_id]

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
            )
        except Exception as error:
            print(f"Live tide data unavailable for {spot.id}: {error}")
            return TideForecast(
                spot_id=spot_id,
                available=False,
                note="Live tide data is unavailable right now.",
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
        alert = next((item for item in self.alerts if item.id == alert_id), None)
        if alert is None:
            return None
        alert.enabled = enabled
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

    def list_posts(self) -> Iterable[SocialPost]:
        return sorted(self.posts, key=lambda post: post.created_at, reverse=True)

    def add_post(self, post: SocialPost) -> SocialPost:
        self.posts.append(post)
        self._save_state()
        return post

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

        alerts_data = data.get("alerts")
        if isinstance(alerts_data, list):
            self.alerts = [Alert.model_validate(item) for item in alerts_data]

        posts_data = data.get("posts")
        if isinstance(posts_data, list):
            self.posts = [SocialPost.model_validate(item) for item in posts_data]

        emails = data.get("waitlist_emails")
        if isinstance(emails, list):
            self.waitlist_emails = [
                str(email).strip().lower()
                for email in emails
                if str(email).strip()
            ]

    def _save_state(self) -> None:
        payload = {
            "user": self.user.model_dump(mode="json"),
            "alerts": [alert.model_dump(mode="json") for alert in self.alerts],
            "posts": [post.model_dump(mode="json") for post in self.posts],
            "waitlist_emails": self.waitlist_emails,
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


store = DemoStore()
