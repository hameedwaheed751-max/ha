# WAHA gateway

This gateway is separate from Render's existing `server.js` and from Firebase Cloud Functions. It accepts Firebase ID tokens and uses Firebase Admin to authorize either the trusted NetAgent admin identity or an eligible agent in `agents/{uid}`. It derives a distinct WAHA session from the verified Firebase UID and never accepts a client-selected UID, agent key, WAHA session, or API key.

## Server-only settings

- `WAHA_BASE_URL`: private WAHA URL, normally `http://waha:3000` on the Compose network.
- `WAHA_API_KEY`: a newly rotated raw API key available only to the gateway container. Do not use the key from `waha_api_key.txt`.
- `FIREBASE_PROJECT_ID`, `FIREBASE_DATABASE_URL`, and `GOOGLE_APPLICATION_CREDENTIALS`: Firebase project, Realtime Database URL, and read-only-mounted Admin SDK credential for the local pilot. On a production VPS, prefer workload identity/application-default credentials where supported.
- `WAHA_IDEMPOTENCY_FILE`: durable JSON ledger path, defaulting to `gateway/data/idempotency.json`.
- `CORS_ALLOWED_ORIGINS`: exact comma-separated web origins. Leave empty for native clients unless a browser origin is explicitly required. Never use `*` with credentials.
- `WAHA_TIMEOUT_MS`: upstream timeout, bounded to 1-60 seconds.

Use a new key after revoking any exposed key. Put secrets in an untracked `.env` or secret manager, not in Compose literals or Git. The gateway's port must stay loopback-bound for local testing; in a permanent deployment, place only the gateway behind HTTPS and keep WAHA private on the Docker network.

## Security and delivery semantics

The gateway accepts only a valid Firebase ID token for an enabled Firebase Auth user. The trusted administrator UID used by NetAgent's `UserRoleService` can manage only their own UID-derived session and does not receive access to agent records. Other users must have `agents/{uid}/profile` with `role=agent` and `status=active`, plus an active, unexpired subscription at `agents/{uid}/subscription`. Every identity gets a deterministic opaque session name derived server-side from the verified UID. Session status, creation, QR, reconnect, logout, and sends all use that same identity-derived session; client-provided `uid`, `agentKey`, or `session` values are ignored.

Session names use `netagent_` plus the first 40 hexadecimal characters of SHA-256 over the verified Firebase UID. Existing central WAHA sessions are not deleted or reused by this Gateway. WAHA's persistent session volume remains responsible for retaining account sessions.

Browser origins must be listed exactly in `CORS_ALLOWED_ORIGINS`; wildcards, paths, and unlisted origins are rejected. The local Compose binding is reachable only on the Gateway host. Remote agents require a separately reviewed HTTPS Gateway deployment; do not expose WAHA.

Send requests require a fixed event type and `Idempotency-Key`. The durable ledger stores a digest of request data, state, and message ID—not recipient or message text. It reserves before contacting WAHA. Repeated successful requests return the prior result. A conflicting payload is rejected. Timeouts and interrupted/unknown outcomes are recorded as `unknown` and are not retried automatically, because WAHA may already have accepted the message. Reconcile these cases manually before attempting a new event key.

The JSON ledger is suitable only for this single gateway instance. Do not scale horizontally without replacing it with a transactional shared store and an outbox/lease design.

## Local pilot

The root `whatsapp_waha/compose.yaml` exposes WAHA only on loopback and will also expose this gateway only on `127.0.0.1:3001`. Do not open either port in the firewall. Mount `gateway/secrets/` read-only for the Firebase Admin credential and keep `gateway/data/` on the durable host path. Do not call the QR endpoint or create a session until the key has been rotated and settings reviewed.

Tests use local HTTP requests and a mocked WAHA `fetch`; they never call WAHA, Firebase, or send messages.
