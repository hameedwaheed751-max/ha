# NetAgent WAHA/GOWS pilot

This directory contains the optional WAHA gateway integration for NetAgent. Meta/Render remain the default; WAHA is selected only when the Flutter build explicitly sets `NETAGENT_WHATSAPP_PROVIDER=waha`. The Gateway verifies Firebase ID tokens, authorizes the trusted NetAgent administrator or an eligible agent, and assigns each verified Firebase UID a separate WAHA session.

The Flutter integration is isolated in `lib/services/waha_notification_service.dart` and `lib/services/whatsapp_notification_dispatcher.dart`. Meta remains the default. To select the gateway deliberately for a local Flutter build, provide both `--dart-define=NETAGENT_WHATSAPP_PROVIDER=waha` and `--dart-define=WAHA_GATEWAY_URL=http://127.0.0.1:3001`; omitting the provider define keeps Meta selected. There is no automatic fallback between providers.

## Pinned image

The Compose file pins `devlikeapro/waha:gows-2026.9.2`; it does not use `latest`. At the time of review (2026-10-21), Docker Hub listed the `gows-2026.9.2` tag, published 2026-10-02. Recheck the tag and release notes before pulling it. The GOWS variant omits Chromium and uses the GOWS engine.

## Pilot host estimate

For one session, start with a Linux VPS offering 2-4 vCPU, 4-8 GB RAM, and 50 GB SSD/NVMe. Reserve roughly 1 vCPU and 1-2 GB RAM for the OS, Docker, and a future small gateway; reserve the remainder for WAHA/GOWS and short-lived QR/history-sync load. These are conservative planning estimates, not official per-session minimums. Measure actual CPU, memory, and disk use during the pilot before extrapolating to more agents.

Current cost is provider- and region-dependent. Budget for the VPS, encrypted off-host backups, and any applicable tax; optionally add a domain/TLS endpoint for the future gateway. Hetzner's pricing page showed cloud instances starting at EUR 5.99/month excluding VAT when reviewed, but that smallest instance is below the recommended pilot size. Obtain a current quote for the recommended specification before purchase. WAHA's documentation describes self-hosting without per-session/per-message service pricing; confirm any image-tier, support, or commercial-use terms before production.

## Secrets and local data

1. Set `WAHA_API_KEY_SHA512` to the SHA-512 hex digest of a newly rotated high-entropy key, set `WAHA_GATEWAY_API_KEY` to that new raw key, and configure the Firebase project and exact name of the existing central WAHA session. The raw key remains server-only. Never use the exposed key file or commit any key, Firebase service account, or `.env`.
2. Keep the VPS firewall closed to inbound port 3000. Compose binds WAHA to `127.0.0.1:3000` only; do not change this to `0.0.0.0` and do not configure a public reverse proxy to WAHA.
3. WAHA has no host-published port; the gateway reaches it through the Compose network. The gateway itself is bound to `127.0.0.1:3001` for the local pilot. This binding is reachable only from the gateway host; agents on other devices require a separately reviewed HTTPS deployment of the gateway. Keep WAHA private and never publish its port.
4. Mount the Firebase Admin credential read-only under `gateway/secrets/`; restrict host permissions and keep it out of image build context. Restrict and encrypt backups of `data/sessions/` and `gateway/data/`.
5. Dashboard and Swagger are disabled. Do not enable them on a public interface.

## Manual pilot sequence (not executed)

Only after explicit approval to operate the pilot:

1. Provision a VPS only after confirming the selected plan, location, monthly price, backups, and provider terms. Install and secure Docker using the provider's official instructions; enable host updates, SSH keys, and a default-deny firewall.
2. Copy this directory to the VPS, create `.env` and the read-only Firebase Admin credential securely, review `compose.yaml`, and only then start with `docker compose up -d`. This deployment command has not been run.
3. For local administration, use an SSH local port forward to `127.0.0.1:3000`; the gateway is only at `127.0.0.1:3001`. Never expose WAHA port 3000 publicly.
4. Verify that a valid Firebase ID token belongs to an enabled Firebase Auth user. The trusted administrator identity used by Flutter may manage only its own UID-derived session; it does not gain access to agent records. Other users must still meet the existing `agents/{uid}/profile` role/status and `agents/{uid}/subscription` active/unexpired checks. Missing/invalid tokens return `401`; unauthorized accounts return `403`.
5. Session names are derived from the verified UID. Existing central WAHA sessions are not deleted or reused; agents link their own session explicitly, and existing session data remains on the WAHA volume. After approval, request a QR only while status is `SCAN_QR_CODE`, then verify `WORKING`. No real message or session is created by automated tests.
6. Repeat the same event key and confirm no second message is sent. Test an ambiguous timeout and confirm the gateway records `unknown` rather than retrying. Restart the container and host to validate persistence; restore an encrypted backup in a disposable test environment.
7. Confirm no public connection reaches WAHA, the QR response has `Cache-Control: no-store`, and neither API keys nor QR/message contents appear in logs.

Expected WAHA lifecycle statuses include `STARTING`, `SCAN_QR_CODE`, `WORKING`, and `FAILED`. QR codes expire; fetch a fresh one when WAHA reports `SCAN_QR_CODE`, rather than caching it. WAHA's documented QR flow permits a limited number of refreshed QR codes before the session fails and needs a restart.

## License and distribution checks before use

- WAHA's GitHub repository declares Apache-2.0. Review the exact pinned release's LICENSE and NOTICE files, preserve required notices, and confirm the license covers the specific Docker image/tier selected.
- GOWS's GitHub repository did not expose an SPDX license or root LICENSE file during this review. Do not treat this as a license clearance. Before production or redistribution, obtain and review the license for GOWS and all bundled Go modules, Node packages, and image layers; request written clarification from the maintainers if the terms are not clear.
- Verify the WAHA Community/support tier's current terms and any commercial-use restrictions directly with the publisher. Support/donation pricing is not itself proof of a software license grant.
- Generate an image SBOM for the pinned image and retain its digest, release notes, license notices, and security scan results with the deployment record.

## Production boundary

The Firebase-authenticated gateway is implemented under `gateway/`. It validates Firebase ID tokens, checks the user's agent profile and subscription through Firebase Admin, and selects the same server-owned WAHA session for every authorized agent. The API key and session name never come from the client. Meta/Render remain unchanged and are not an automatic failover path.

The current Compose binding is local-only and cannot be reached by agents on other devices. Remote multi-agent use requires a separately reviewed HTTPS deployment, an exact CORS origin allowlist, and a durable shared idempotency store before horizontal scaling.

## Official references

- WAHA release: https://github.com/devlikeapro/waha/releases/tag/2026.9.2
- WAHA engines and Docker tags: https://waha.devlike.pro/docs/how-to/engines/
- GOWS engine: https://waha.devlike.pro/docs/engines/gows/
- Session creation, lifecycle, QR, and persistence behavior: https://waha.devlike.pro/docs/how-to/sessions/
- Persistent session storage: https://waha.devlike.pro/docs/how-to/storages/
- Send text endpoint: https://waha.devlike.pro/docs/how-to/send-messages/
- WAHA API security: https://waha.devlike.pro/docs/how-to/security/
- WAHA license source: https://github.com/devlikeapro/waha/blob/core/LICENSE
- GOWS repository: https://github.com/devlikeapro/gows
- Docker Hub pinned image tags: https://hub.docker.com/r/devlikeapro/waha/tags
- VPS pricing reference: https://www.hetzner.com/cloud/
