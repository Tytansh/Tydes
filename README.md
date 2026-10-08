# Tydes

Monorepo for the Tydes mobile app with a Flutter client and FastAPI backend.

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

For local media/upload URLs, set:

```bash
export PUBLIC_BACKEND_URL=http://127.0.0.1:8000
```

## Flutter

```bash
cd apps/mobile_flutter
flutter pub get
flutter run
```

By default the app points at `https://api.tydes.io/api/v1`. For local backend work, pass a dev override:

```bash
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

## Launch Notes

- Public legal pages live under `docs/privacy`, `docs/terms`, and `docs/support`.
- Launch checklist lives in `docs/launch-checklist.md`.
- Email setup lives in `docs/email-setup.md`.
- App Review Notes template lives in `docs/app-review-notes-template.md`.
- Premium setup details live in `docs/app-store-subscriptions.md`.
- Production map tile setup lives in `docs/map-provider.md`.
