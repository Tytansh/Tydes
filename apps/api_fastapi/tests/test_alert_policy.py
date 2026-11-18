"""Alert plan policy: fake accounts/providers, isolated JSON and SQL fixtures."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from contextvars import ContextVar
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import sys
import tempfile
from threading import Barrier, Event, RLock
from types import SimpleNamespace

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
# DemoStore is a module-level singleton: isolate it before importing any app
# module, even when this test file is collected before the shared API fixtures.
_test_state_dir = tempfile.mkdtemp(prefix="tydes-alert-policy-tests-")
os.environ["TYDES_DATA_DIR"] = _test_state_dir
os.environ["TYDES_STATE_FILE"] = str(Path(_test_state_dir) / "demo_state.json")
from app.core.alert_policy import AlertPolicyError
from app.core.auth import require_authenticated_user
from app.core.models import Alert, ForecastEntry, TideForecast, build_seed
from app.core.postgres_planning import PostgresPlanningRepository
from app.core.rate_limit import api_rate_limiter
from app.core.store import DemoStore
from app.integrations.weather_providers.open_meteo import spot_local_date
from app.modules.alerts import router as routes


@pytest.fixture
def subject(tmp_path, monkeypatch):
    seed = build_seed()
    user = seed["user"].model_copy(update={"id": "owner", "email": "owner@example.com",
        "premium": False, "admin_premium": False, "email_verified": True,
        "subscription_active": None, "free_live_spot_id": seed["spots"][0].id})
    store = DemoStore.__new__(DemoStore)
    store._request_user = ContextVar("alert-policy-test-user", default=None)
    store._default_user = user
    store._state_lock = RLock()
    store.spots = seed["spots"][:3]
    store.alerts = []
    store.posts = store.comments = []
    store.auth_accounts = {user.email: {"user": user.model_dump(mode="json")}}
    store.postgres_auth = store.postgres_social = store.postgres_planning = None
    store.session_tokens = {}
    store.calls = []
    store.path = tmp_path / "alerts.json"
    def save():
        store.auth_accounts[store.user.email] = {"user": store.user.model_dump(mode="json")}
        store.path.write_text(json.dumps([alert.model_dump(mode="json") for alert in store.alerts]))
    monkeypatch.setattr(store, "_save_state", save)
    def forecast(spot, **kwargs):
        store.calls.append(("forecast", spot.id))
        return [ForecastEntry(id="real-model", spot_id=spot.id, day=spot_local_date(spot),
            wave_height_m=2, wind_kts=5, quality="fair", source="open-meteo", confidence="live")]
    def tides(spot, *args, **kwargs):
        store.calls.append(("tides", spot.id))
        return TideForecast(spot_id=spot.id, available=False)
    store.weather_provider = SimpleNamespace(fetch_spot_forecast=forecast)
    store.tide_provider = SimpleNamespace(fetch_spot_tides=tides)
    monkeypatch.delenv("TYDES_PREMIUM_EMAILS", raising=False)
    monkeypatch.setenv("ALERTS_MAX_PER_USER", "25")
    monkeypatch.setenv("ALERTS_CREATED_PER_USER_DAY", "100")
    api_rate_limiter.clear()
    yield store
    api_rate_limiter.clear()


def account(store, **changes):
    user = store.user.model_copy(update=changes)
    store.user = user
    store.auth_accounts[user.email] = {"user": user.model_dump(mode="json")}
    return user


def alert(store, identifier="a", *, spot=None, enabled=True, owner=None):
    return Alert(id=identifier, user_id=owner or store.user.id,
        spot_id=spot or store.spots[0].id, enabled=enabled,
        wave_enabled=True, min_wave_height_m=1, wind_enabled=True, max_wind_kts=18,
        next_check_at=datetime.now(timezone.utc))


def client_for(store, monkeypatch):
    app = FastAPI()
    app.include_router(routes.router)
    monkeypatch.setattr(routes, "store", store)
    def authenticate():
        return store._default_user.model_copy(deep=True)
    app.dependency_overrides[require_authenticated_user] = authenticate
    return TestClient(app)


def test_free_create_requires_selected_spot_and_one_active_limit(subject, monkeypatch):
    client = client_for(subject, monkeypatch)
    locked = client.post("/alerts", json={"spot_id": subject.spots[1].id})
    assert locked.status_code == 403 and "free Premium break" in locked.json()["detail"]
    assert subject.calls == [] and subject.alerts == []
    first = client.post("/alerts", json={"spot_id": subject.spots[0].id})
    assert first.status_code == 200 and first.json()["pause_reason"] is None
    assert client.post("/alerts", json={"spot_id": subject.spots[0].id}).status_code == 409
    assert sum(item.enabled for item in subject.alerts) == 1


def test_free_without_selected_spot_cannot_create_even_disabled_new_config(subject):
    account(subject, free_live_spot_id=None)
    with pytest.raises(AlertPolicyError) as error:
        subject.add_alert(alert(subject, enabled=False))
    assert error.value.status_code == 403 and subject.calls == []


@pytest.mark.parametrize("field", ["spot_id", "enabled", "wave_enabled", "wind_enabled", "tide_enabled"])
def test_patch_null_nonnullable_setting_is_422_without_mutation(subject, monkeypatch, field):
    subject.alerts = [alert(subject)]
    before = subject.alerts[0].model_dump()
    response = client_for(subject, monkeypatch).patch("/alerts/a", json={field: None})
    assert response.status_code == 422
    assert subject.alerts[0].model_dump() == before
    assert subject.calls == []
    assert list(subject.list_alerts())[0].id == "a"


@pytest.mark.parametrize("field", ["spot_id", "enabled", "wave_enabled", "wind_enabled", "tide_enabled"])
def test_store_revalidates_merged_settings_before_persistence(subject, field):
    subject.alerts = [alert(subject)]
    before = subject.alerts[0].model_dump()
    with pytest.raises(AlertPolicyError) as error:
        subject.update_alert("a", {field: None})
    assert error.value.status_code == 422
    assert subject.alerts[0].model_dump() == before
    assert subject.calls == []
    assert Alert.model_validate(json.loads(subject.path.read_text())[0]).id == "a"


def test_patch_nullable_thresholds_can_be_cleared(subject, monkeypatch):
    subject.alerts = [alert(subject, enabled=False)]
    response = client_for(subject, monkeypatch).patch("/alerts/a", json={
        "min_wave_height_m": None, "max_wind_kts": None,
        "tide_type": None, "tide_offset_hours": None})
    assert response.status_code == 200
    assert response.json()["min_wave_height_m"] is None
    assert response.json()["max_wind_kts"] is None


def test_premium_ten_active_separate_from_twenty_five_saved(subject):
    account(subject, premium=True)
    for number in range(10):
        subject.add_alert(alert(subject, f"active-{number:02}"))
    with pytest.raises(AlertPolicyError) as error:
        subject.add_alert(alert(subject, "eleventh"))
    assert error.value.status_code == 409
    for number in range(15):
        subject.add_alert(alert(subject, f"off-{number:02}", enabled=False))
    assert len(subject.alerts) == 25 and sum(item.enabled for item in subject.alerts) == 10
    with pytest.raises(AlertPolicyError, match="keep up to 25"):
        subject.add_alert(alert(subject, "twenty-six", enabled=False))


def test_disable_frees_active_slot_but_never_resumes_an_old_configuration(subject):
    subject.add_alert(alert(subject, "a"))
    subject.add_alert(alert(subject, "b", enabled=False))
    with pytest.raises(AlertPolicyError):
        subject.update_alert("b", {"enabled": True})
    subject.update_alert("a", {"enabled": False})
    updated = subject.update_alert("b", {"enabled": True})
    assert updated.enabled and updated.pause_reason is None
    assert next(item for item in subject.alerts if item.id == "a").enabled is False


def test_legacy_locked_configs_are_paused_before_any_upstream_read_and_reason_persists(subject):
    blocked = alert(subject, "locked", spot=subject.spots[1].id)
    blocked.tide_enabled = True
    subject.alerts = [blocked]
    values = list(subject.list_alerts())
    assert values[0].enabled is False and values[0].pause_reason == "spot_access"
    reason = values[0].status_reason
    assert subject.calls == []
    assert list(subject.list_alerts())[0].status_reason == reason
    saved = Alert.model_validate(json.loads(subject.path.read_text())[0])
    assert saved.pause_reason == "spot_access" and saved.enabled is False


def test_legacy_reconciliation_keeps_eligible_ids_first_without_auto_resuming(subject):
    subject.alerts = [alert(subject, "a-locked", spot=subject.spots[1].id),
                      alert(subject, "z-eligible"), alert(subject, "b-eligible")]
    subject.reconcile_alert_policy()
    rows = {item.id: item for item in subject.alerts}
    assert rows["b-eligible"].enabled
    assert rows["z-eligible"].pause_reason == "active_limit"
    assert rows["a-locked"].pause_reason == "spot_access"
    assert subject.calls == []
    account(subject, premium=True)
    subject.reconcile_alert_policy()
    assert sum(item.enabled for item in subject.alerts) == 1


def test_disabled_locked_legacy_config_can_be_edited_but_not_enabled(subject, monkeypatch):
    subject.alerts = [alert(subject, "legacy", spot=subject.spots[1].id, enabled=False)]
    client = client_for(subject, monkeypatch)
    response = client.patch("/alerts/legacy", json={"min_wave_height_m": 1.75})
    assert response.status_code == 200 and response.json()["min_wave_height_m"] == 1.75
    assert client.patch("/alerts/legacy", json={"enabled": True}).status_code == 409
    assert subject.calls == []


def test_active_edit_to_locked_spot_is_rejected_without_changing_existing_alert(subject):
    subject.add_alert(alert(subject))
    calls = len(subject.calls)
    with pytest.raises(AlertPolicyError) as error:
        subject.update_alert("a", {"spot_id": subject.spots[1].id})
    assert error.value.status_code == 409
    assert subject.alerts[0].spot_id == subject.spots[0].id and subject.alerts[0].enabled
    assert len(subject.calls) == calls


def test_free_spot_switch_pauses_old_alert_without_moving_or_resuming_it(subject):
    subject.add_alert(alert(subject))
    subject.calls.clear()
    subject.set_free_live_spot(subject.spots[1].id)
    old = subject.alerts[0]
    assert old.spot_id == subject.spots[0].id and not old.enabled and old.pause_reason == "spot_access"
    assert subject.calls == []
    subject.add_alert(alert(subject, "new", spot=subject.spots[1].id))
    assert sum(item.enabled for item in subject.alerts) == 1


@pytest.mark.parametrize("path", ["premium_status", "subscription", "admin", "admin_self", "expired_read"])
def test_premium_loss_paths_pause_ineligible_and_excess_alerts_without_provider_calls(subject, path):
    account(subject, premium=True, admin_premium=path == "admin")
    subject.alerts = [alert(subject, "a-locked", spot=subject.spots[1].id),
                      alert(subject, "b-eligible"), alert(subject, "c-extra")]
    if path == "premium_status":
        subject.set_premium_status(False)
    elif path == "subscription":
        subject.set_user_subscription_status(subject.user.id, SimpleNamespace(
            active=False, expires_at=None, management_url=None))
    elif path == "admin":
        admin = subject.user.model_copy(update={"id": "admin", "email": "admin@example.com"})
        with subject.request_user_context(admin):
            subject.set_admin_user_access("owner", premium=False)
    elif path == "admin_self":
        account(subject, admin_premium=True)
        subject.set_admin_user_access("owner", premium=False)
    else:
        account(subject, subscription_active=True,
                subscription_expires_at=datetime.now(timezone.utc) - timedelta(seconds=1))
        subject.reconcile_alert_policy()
    rows = {item.id: item for item in subject.alerts}
    assert rows["b-eligible"].enabled
    assert rows["a-locked"].pause_reason == "spot_access"
    assert rows["c-extra"].pause_reason == "active_limit"
    assert subject.calls == []


def test_manual_disable_clears_structured_auto_pause_reason(subject):
    subject.alerts = [alert(subject, spot=subject.spots[1].id)]
    subject.reconcile_alert_policy()
    updated = subject.update_alert("a", {"enabled": False})
    assert updated.pause_reason is None and updated.status_reason == "Alert is turned off."


def test_plan_grant_does_not_resume_paused_alerts(subject):
    subject.alerts = [alert(subject, spot=subject.spots[1].id)]
    subject.reconcile_alert_policy()
    subject.set_premium_status(True)
    assert not subject.alerts[0].enabled and subject.alerts[0].pause_reason == "spot_access"
    assert subject.update_alert("a", {"enabled": True}).enabled


def test_estimated_model_data_cannot_trigger_even_an_eligible_free_alert(subject):
    def estimate(spot, **kwargs):
        return [ForecastEntry(id="estimated", spot_id=spot.id, day=spot_local_date(spot),
            wave_height_m=10, wind_kts=0, source="estimated", confidence="estimated", quality="epic")]
    subject.weather_provider.fetch_spot_forecast = estimate
    saved = subject.add_alert(alert(subject))
    assert saved.status == "waiting" and saved.last_triggered_at is None


@pytest.mark.parametrize("premium,attempts,expected", [(False, 8, 1), (True, 14, 10)])
def test_concurrent_creates_cannot_exceed_active_plan_cap(subject, premium, attempts, expected):
    user = account(subject, premium=premium)
    barrier = Barrier(attempts)
    def create(number):
        with subject.request_user_context(user.model_copy(deep=True)):
            barrier.wait(timeout=5)
            try:
                subject.add_alert(alert(subject, f"concurrent-{number:02}"))
                return True
            except AlertPolicyError:
                return False
    with ThreadPoolExecutor(max_workers=attempts) as executor:
        results = list(executor.map(create, range(attempts)))
    assert sum(results) == expected and sum(item.enabled for item in subject.alerts) == expected


def test_concurrent_enables_cannot_exceed_free_cap(subject):
    for number in range(6):
        subject.add_alert(alert(subject, f"off-{number}", enabled=False))
    barrier = Barrier(6)
    def enable(number):
        with subject.request_user_context(subject._default_user.model_copy(deep=True)):
            barrier.wait(timeout=5)
            try:
                subject.update_alert(f"off-{number}", {"enabled": True})
                return True
            except AlertPolicyError:
                return False
    with ThreadPoolExecutor(max_workers=6) as executor:
        assert sum(executor.map(enable, range(6))) == 1
    assert sum(item.enabled for item in subject.alerts) == 1


def test_json_failure_rolls_back_alert_mutation(subject, monkeypatch):
    def failed_save():
        raise OSError("fixture disk failure")
    monkeypatch.setattr(subject, "_save_state", failed_save)
    with pytest.raises(OSError):
        subject.add_alert(alert(subject))
    assert subject.alerts == []


def test_slow_provider_does_not_hold_state_lock_or_restore_disabled_config(subject, monkeypatch):
    subject.alerts = [alert(subject)]
    entered, release = Event(), Event()
    original = subject.weather_provider.fetch_spot_forecast
    def slow(spot, **kwargs):
        assert not subject._state_lock._is_owned()
        entered.set()
        assert release.wait(3)
        return original(spot, **kwargs)
    monkeypatch.setattr(subject.weather_provider, "fetch_spot_forecast", slow)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(lambda: list(subject.list_alerts()))
        assert entered.wait(2)
        try:
            disabled = pool.submit(subject.update_alert, "a", {"enabled": False}).result(timeout=1)
            assert disabled.enabled is False
            # An unrelated owner's state mutation is also independent of I/O.
            other = subject.user.model_copy(update={"id": "other", "email": "other@example.com"})
            subject.auth_accounts[other.email] = {"user": other.model_dump(mode="json")}
            pool.submit(subject.reconcile_alert_policy, other).result(timeout=1)
        finally:
            release.set()
        result = pending.result(timeout=2)
    assert result[0].enabled is False
    assert result[0].status_reason == "Alert is turned off."


def test_creation_is_durable_and_cap_enforced_before_slow_failed_check(subject, monkeypatch):
    entered, release = Event(), Event()
    def slow_failure(*args, **kwargs):
        entered.set()
        assert release.wait(3)
        raise RuntimeError("fixture provider outage")
    monkeypatch.setattr(subject.weather_provider, "fetch_spot_forecast", slow_failure)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(subject.add_alert, alert(subject))
        assert entered.wait(2)
        try:
            with subject._state_lock:
                assert len(subject.alerts) == 1 and subject.alerts[0].enabled
                assert json.loads(subject.path.read_text())[0]["id"] == "a"
            blocked = pool.submit(subject.add_alert, alert(subject, "second"))
            with pytest.raises(AlertPolicyError) as error:
                blocked.result(timeout=1)
            assert error.value.status_code == 409
        finally:
            release.set()
        result = pending.result(timeout=2)
    assert result.enabled and result.status == "waiting"
    assert "Waiting on wave data" in result.status_reason
    assert len(subject.alerts) == 1


def test_another_account_cannot_mutate_or_pause_owners_alerts(subject):
    subject.add_alert(alert(subject))
    other = subject.user.model_copy(update={"id": "other", "email": "other@example.com", "free_live_spot_id": None})
    subject.auth_accounts[other.email] = {"user": other.model_dump(mode="json")}
    with subject.request_user_context(other):
        assert list(subject.list_alerts()) == []
        assert subject.update_alert("a", {"enabled": False}) is None
        assert subject.delete_alert("a") is False
    assert subject.alerts[0].user_id == "owner" and subject.alerts[0].enabled


def test_old_alert_payloads_default_to_no_pause_metadata(subject):
    payload = alert(subject).model_dump(mode="json")
    payload.pop("pause_reason")
    assert Alert.model_validate(payload).pause_reason is None


class _Rows:
    def __init__(self, rows): self.rows = rows
    def fetchall(self): return self.rows
    def fetchone(self): return self.rows[0] if self.rows else None


class _PlanningConnection:
    def __init__(self):
        self.rows = {}
        self.calls = []
        self.active = False
    def __enter__(self): return self
    def __exit__(self, *args): pass
    @contextmanager
    def transaction(self):
        before = deepcopy(self.rows)
        self.active = True
        try: yield
        except BaseException:
            self.rows = before
            raise
        finally: self.active = False
    def execute(self, sql, params):
        assert self.active
        self.calls.append((sql, params))
        if "pg_advisory_xact_lock" in sql:
            return _Rows([])
        if sql.strip().startswith("SELECT"):
            return _Rows([{"payload": item} for item in self.rows.values() if item["user_id"] == params[0]])
        if sql.strip().startswith("INSERT"):
            identifier, owner, payload = params
            if identifier in self.rows and self.rows[identifier]["user_id"] != owner:
                return _Rows([])
            self.rows[identifier] = deepcopy(payload)
            return _Rows([{"id": identifier}])
        if sql.strip().startswith("DELETE"):
            if self.rows.get(params[0], {}).get("user_id") == params[1]:
                del self.rows[params[0]]
            return _Rows([])
        raise AssertionError("Unexpected fixture SQL")


def test_postgres_mutations_use_one_owner_lock_and_transaction_with_pause_metadata(subject, monkeypatch):
    repository = PostgresPlanningRepository.__new__(PostgresPlanningRepository)
    connection = _PlanningConnection()
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", lambda payload: payload)
    with repository.alert_transaction("owner") as alerts:
        row = alert(subject)
        row.enabled = False
        row.pause_reason = "active_limit"
        alerts.append(row)
    assert connection.rows["a"]["pause_reason"] == "active_limit"
    assert "pg_advisory_xact_lock" in connection.calls[0][0]
    assert connection.calls[0][1] == ("tydes-alert-policy:owner",)
    assert "FOR UPDATE" in connection.calls[1][0]
    with pytest.raises(RuntimeError):
        with repository.alert_transaction("owner") as alerts:
            alerts.clear()
            raise RuntimeError("fixture rollback")
    assert connection.rows["a"]["pause_reason"] == "active_limit"


def test_postgres_scope_rejects_cross_account_rows_and_rolls_back(subject, monkeypatch):
    repository = PostgresPlanningRepository.__new__(PostgresPlanningRepository)
    connection = _PlanningConnection()
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", lambda payload: payload)
    with pytest.raises(ValueError, match="owner mismatch"):
        with repository.alert_transaction("owner") as alerts:
            alerts.append(alert(subject, owner="other"))
    assert connection.rows == {}


def test_postgres_provider_reads_are_outside_mutation_transaction(subject, monkeypatch):
    repository = PostgresPlanningRepository.__new__(PostgresPlanningRepository)
    connection = _PlanningConnection()
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", lambda payload: payload)
    subject.postgres_planning = repository
    original = subject.weather_provider.fetch_spot_forecast
    def checked(spot, **kwargs):
        assert connection.active is False
        return original(spot, **kwargs)
    monkeypatch.setattr(subject.weather_provider, "fetch_spot_forecast", checked)
    subject.add_alert(alert(subject))
    list(subject.list_alerts())
    subject.update_alert("a", {"min_wave_height_m": 1.5})
    assert len(subject.calls) == 3
    assert connection.rows["a"]["min_wave_height_m"] == 1.5


def test_postgres_billing_downgrade_reconciles_explicit_target_not_webhook_caller(subject, monkeypatch):
    owner = account(subject, premium=True)
    repository = PostgresPlanningRepository.__new__(PostgresPlanningRepository)
    connection = _PlanningConnection()
    legacy = [alert(subject, "a-locked", spot=subject.spots[1].id),
              alert(subject, "b-eligible"), alert(subject, "c-excess")]
    connection.rows = {item.id: item.model_dump(mode="json") for item in legacy}
    monkeypatch.setattr(repository, "_connect", lambda: connection)
    monkeypatch.setattr(repository, "_jsonb", lambda payload: payload)
    subject.postgres_planning = repository
    snapshot = {"user": owner}
    def update(user_id, subscription, **kwargs):
        assert user_id == owner.id
        snapshot["user"] = owner.model_copy(update={"premium": False, "subscription_active": False})
        return snapshot["user"]
    subject.postgres_auth = SimpleNamespace(
        get_user_by_id=lambda owner_id: snapshot["user"] if owner_id == owner.id else None,
        update_subscription_fields=update,
    )
    caller = owner.model_copy(update={"id": "unrelated-caller", "email": "caller@example.com"})
    with subject.request_user_context(caller):
        result = subject.set_user_subscription_status(owner.id,
            SimpleNamespace(active=False, expires_at=None, management_url=None))
        assert subject.user.id == caller.id
    assert result.premium is False
    rows = {key: Alert.model_validate(value) for key, value in connection.rows.items()}
    assert rows["b-eligible"].enabled
    assert rows["a-locked"].pause_reason == "spot_access"
    assert rows["c-excess"].pause_reason == "active_limit"
    assert subject.calls == []


def test_fresh_account_permissions_override_stale_premium_request(subject):
    stale = account(subject, premium=True)
    fresh = stale.model_copy(update={"premium": False})
    subject.postgres_auth = SimpleNamespace(get_user_by_id=lambda _owner: fresh)
    with subject.request_user_context(stale):
        with pytest.raises(AlertPolicyError) as error:
            subject.add_alert(alert(subject, spot=subject.spots[1].id))
    assert error.value.status_code == 403 and subject.calls == []


def test_deleted_postgres_account_does_not_fall_back_to_old_request_identity(subject):
    subject.postgres_auth = SimpleNamespace(get_user_by_id=lambda _owner: None)
    with pytest.raises(AlertPolicyError) as error:
        subject.add_alert(alert(subject))
    assert error.value.status_code == 403 and subject.calls == []
