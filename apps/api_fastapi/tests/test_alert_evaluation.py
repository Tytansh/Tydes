"""Alert evaluation fixtures; no account, database or upstream network access."""
from datetime import UTC, datetime, timedelta
from pathlib import Path
import os
import sys
import tempfile
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
os.environ.setdefault("TYDES_DATA_DIR", tempfile.mkdtemp(prefix="tydes-alert-tests-"))

from app.core.models import Alert, ForecastEntry, build_seed
from app.core.store import DemoStore
from app.integrations.weather_providers.open_meteo import spot_local_date


def _fixture(monkeypatch, **forecast_changes):
    store = DemoStore.__new__(DemoStore)
    spot = build_seed()["spots"][0]
    store.spots = [spot]
    forecast = ForecastEntry(
        id="fixture", spot_id=spot.id, day=spot_local_date(spot),
        wave_height_m=2.0, wind_kts=5, quality="fair",
        source="open-meteo", confidence="live",
    ).model_copy(update=forecast_changes)
    monkeypatch.setattr(store, "list_forecasts", lambda *_args: [forecast])
    alert = Alert(
        id="test", user_id="test-user", spot_id=spot.id,
        wave_enabled=True, min_wave_height_m=1.0,
        wind_enabled=True, max_wind_kts=14,
        next_check_at=datetime.now(UTC),
    )
    return store, spot, alert


@pytest.mark.parametrize("changes", [
    {"confidence": "estimated"},
    {"source": "estimated"},
    {"source": "seed"},
    {"wave_height_m": None},
    {"wind_kts": None},
    {"wave_height_m": float("nan")},
    {"wind_kts": float("inf")},
])
def test_unreliable_forecast_never_activates_alert(monkeypatch, changes):
    store, _, alert = _fixture(monkeypatch, **changes)
    store._evaluate_alert(alert)
    assert alert.status == "waiting"
    assert alert.last_triggered_at is None


@pytest.mark.parametrize("offset", [-1, 1])
def test_not_today_at_spot_is_not_current_alert_data(monkeypatch, offset):
    store, spot, alert = _fixture(monkeypatch)
    row = ForecastEntry(
        id="old-or-future", spot_id=spot.id,
        day=spot_local_date(spot) + timedelta(days=offset),
        wave_height_m=2, wind_kts=5, quality="good",
        source="open-meteo", confidence="live",
    )
    monkeypatch.setattr(store, "list_forecasts", lambda *_args: [row])
    store._evaluate_alert(alert)
    assert alert.status == "waiting"
    assert alert.last_triggered_at is None


def test_provider_failure_static_fallback_is_not_a_match(monkeypatch):
    store, _, alert = _fixture(monkeypatch)
    monkeypatch.delattr(store, "list_forecasts")
    monkeypatch.setattr(store, "_can_access_live_forecast", lambda *_args: True)
    def unavailable(*_args, **_kwargs):
        raise RuntimeError("Provider unavailable")
    store.weather_provider = SimpleNamespace(fetch_spot_forecast=unavailable)
    store._evaluate_alert(alert)
    assert alert.status == "waiting"
    assert alert.last_triggered_at is None


def test_valid_model_match_has_honest_forecast_reason(monkeypatch):
    store, _, alert = _fixture(monkeypatch)
    store._evaluate_alert(alert)
    assert alert.status == "triggered"
    assert "Model forecast values" in alert.status_reason
    assert "not an observation or safety rating" in alert.status_reason
    assert "right now" not in alert.status_reason
    assert alert.last_triggered_at is not None
    assert alert.next_check_at > alert.last_evaluated_at


def test_zero_wind_is_valid_calm_data(monkeypatch):
    store, _, alert = _fixture(monkeypatch, wind_kts=0.0)
    store._evaluate_alert(alert)
    assert alert.status == "triggered"


def test_zero_wave_height_does_not_fall_through_to_larger_value(monkeypatch):
    store, _, alert = _fixture(monkeypatch, wave_height_max_m=0.0)
    store._evaluate_alert(alert)
    assert alert.status == "watching"
    assert "wave below" in alert.status_reason


def test_no_selected_conditions_do_not_trigger_or_fetch(monkeypatch):
    store, _, alert = _fixture(monkeypatch)
    def unexpected(*_args):
        raise AssertionError("No wave or wind condition should fetch a forecast")
    monkeypatch.setattr(store, "list_forecasts", unexpected)
    alert.wave_enabled = alert.wind_enabled = alert.tide_enabled = False
    store._evaluate_alert(alert)
    assert alert.status == "waiting"


def test_disabled_alert_does_not_fetch(monkeypatch):
    store, _, alert = _fixture(monkeypatch)
    def unexpected(*_args):
        raise AssertionError("Disabled alert should not fetch")
    monkeypatch.setattr(store, "list_forecasts", unexpected)
    alert.enabled = False
    store._evaluate_alert(alert)
    assert alert.status == "watching"
    assert alert.status_reason == "Alert is turned off."
