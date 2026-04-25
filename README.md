# Surf Travel Starter

Greenfield monorepo for a global surf + travel mobile app with a Flutter client and FastAPI backend.

## Structure

- `apps/mobile_flutter`: Flutter mobile app
- `apps/api_fastapi`: FastAPI backend
- `worker`: Background job placeholders
- `docs`: Notes and future architecture docs

## FastAPI

```bash
cd apps/api_fastapi
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn app.main:app --reload
```

API docs will be available at `http://127.0.0.1:8000/docs`.

## Flutter

```bash
cd apps/mobile_flutter
flutter pub get
flutter run
```

The app expects the backend at `http://127.0.0.1:8000/api/v1` on simulators. If you need a device-specific host, update `lib/core/network/api_config.dart`.

