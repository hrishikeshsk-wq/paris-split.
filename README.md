# Paris Split

Personal shared-expense app. Production: https://paris-split.vercel.app

## Features

- Independent trips and groups, saved on each device; invite links join a trip from any device.
- EUR, GBP, CAD and USD, multiple payers, equal/shares/percentage/exact splits.
- Latest dated ECB reference rates through Frankfurter, applied only when chosen. Each expense stores its original currency and fixed conversion rate.
- Integer-cent allocation with deterministic largest-remainder rounding, balances and simplified payments.
- Expense editing, reversible deletion/restoration, append-only activity records displayed in plain language.
- CSV export of active/deleted expenses, payments, balances and activity; no invite or session credentials are exported. Text cells are protected from spreadsheet formula injection.
- Realtime invalidations over Supabase WebSockets, with reconnect and 30-second recovery polling.
- Creator-only member removal/restoration and a private creator recovery key. Removal revokes the removed member’s sessions and rotates the invite; other joined members retain access. Previous financial records and balances remain.

## Run and verify

Requires Node 24; no third-party frontend dependencies or install step.

```
npm test
node server.mjs
node build.mjs
```

The local server listens on `127.0.0.1:4173`. The production build contains only public web assets. `vercel.json` defines response security headers; `build.mjs` also generates a headers-only config for Vercel Drop uploads.

`node tests/features-check.mjs` exercises the live backend with separately named synthetic trips. It tests idempotence, deletion/restore, creator authorization (including omitted credentials), session revocation, old-invite rejection, unaffected-member access, creator recovery, trip isolation, anonymous access denial and FX responses. It writes test credentials only to ignored `work/`. Do not run repeatedly against production without allowing for request limits. The unit tests do not contact external services.

## Backend

Existing Supabase project: `rxzaoeolvaoafzhofcco`. Apply `backend/upgrade.sql` to the original seven-table schema, then `backend/features.sql`. Deploy `backend/index.ts` as `paris-split-api` with gateway JWT verification off: the endpoint performs custom invite/member-session authorization in the database. This file uses only built-in Deno APIs and environment-provided service credentials.

All database functions are SECURITY INVOKER and executable only by `service_role`. Public/anonymous/authenticated clients cannot invoke them or read the protected tables. The Edge Function holds the service key; clients receive only the public anon key for realtime. Expense writes, splits/payers and activity records are atomic. Request IDs make retries idempotent, and updates check timestamps to prevent stale overwrites.

Member-session tokens are stored hashed. Creator recovery keys are private database records and retained only on the creator’s device unless the creator copies one. They are never included in shared invites or normal snapshots. Save the recovery key before clearing browser data. There is no verified email identity: holders of a current invite are trusted to choose an existing active name or create their own. Creator power requires the separate key, never a name.

Realtime public channels contain only `changed: true`, not expenses or invite credentials. Every refresh is authorized. Basic API throttling permits 10 trip creations per IP per hour and 120 other requests per IP per minute. This personal app is not designed as a public commercial service or for sensitive financial account information.

Daily rates: https://frankfurter.dev/ (ECB provider). A reference rate can differ from card/bank rates; enter a custom rate when needed. Existing expenses never change when newer rates arrive.

## Maintenance

Source repository: `hrishikeshsk-wq/paris-split.` (the trailing period is intentional). Keep `work/`, `.env*` and all credentials out of Git. Data remains in Supabase independently of frontend deployments. Use the activity view to restore accidental expense deletions or the creator’s member controls to restore removed people.
