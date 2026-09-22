# Impact CMS backend

A small Node.js/Express + SQLite backend that:

1. Serves every `*.dc.html` page from the project root, injecting live
   content from the database in place of each page's hardcoded
   `var EN = {...}; var AR = {...};` dictionaries.
2. Provides an admin panel (`/admin`) to log in and edit every piece of
   text on every page, in both English and Arabic, plus add/remove pages
   and manage image assets — no code changes required for day-to-day
   content edits.
3. Handles the contact form (`POST /api/contact`), sends the inquiry by
   email, and routes it based on country: **Egypt → `info@impactegypt.com`,
   everything else (UAE, KSA, rest of the Middle East / world) →
   `info@impact-ld.me`**.

## Quick start

```bash
cd server
cp .env.example .env      # then edit .env — see "Environment variables" below
npm install
npm run migrate           # one-time: seeds the DB from the existing .dc.html pages
npm start
```

Then open:
- **Site:** http://localhost:3000/Impact%20L%26D%20Parallax.dc.html (or any other `*.dc.html` page — they all work at `/<Page Name>.dc.html`)
- **Admin panel:** http://localhost:3000/admin/login

The first time the server runs, it creates one admin account from
`ADMIN_USERNAME` / `ADMIN_PASSWORD` in `.env` (default `admin` /
`changeme` if left unset — **change these**). Change the password from
the admin panel once logged in.

## How content editing works

Every page's `var EN = {...}; var AR = {...};` block was parsed once
(`server/db/migrate.js`) into a `content_fields` table
(`page_slug`, `field_key`, `en_value`, `ar_value`). When a page is
requested, `server/routes/pages.js` reads the static `.dc.html` file from
disk and swaps in the *current* database values for `EN`/`AR` before
sending the response — the original `data-t="key"` / `applyLang()`
client-side mechanism in every page is untouched, it now just receives
its dictionary from the server instead of having it hardcoded.

**This means the database is the source of truth for text content once
`npm run migrate` has run once.** `npm run migrate` is safe to re-run
(e.g. on every deploy) — it only *adds* fields that don't already exist
in the DB, it never overwrites a value an admin has edited or a value
already seeded from an earlier version of a page. If you hand-edit copy
in a `.dc.html` file after the DB already has that field, that edit
won't show up on the live site until you either delete the row in the
DB and re-migrate, or edit it in the admin panel instead — don't edit
page copy by hand once this backend is running, use the admin panel.

Adding a **new** `data-t="someKey"` element to a page's HTML: the admin
panel's "+ Add field" button on that page lets you create the matching
DB row (key must match exactly). Removing a `data-t` element from the
HTML doesn't remove its DB row automatically — delete it from the admin
panel too if you want it gone.

## Admin panel features

- **Pages** (`/admin`) — list every page, search/filter, soft-delete
  (stops serving it, content is kept and restorable) or create a new
  page from a minimal template.
- **Page editor** (`/admin/page?slug=...`) — every text field on that
  page, EN and AR side by side, inline save, add/delete fields.
- **Assets** (`/admin/assets`) — every file in `assets/`; drag-and-drop
  upload, or upload a file with the *same name* as an existing asset to
  replace it everywhere it's referenced.
- **Contact submissions** (`/admin/submissions`) — read-only log of the
  last 200 contact-form messages, which mailbox each was routed to, and
  whether the email actually sent.

## Environment variables

See `.env.example` for the full list with comments. The important ones:

| Variable | Purpose |
|---|---|
| `SESSION_SECRET` | Random string for signing admin session cookies. **Must** be set to something long/random in production. |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Only used to create the *first* admin account. Change the password from the admin panel afterward. |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASS` | Any SMTP-capable provider works — Gmail SMTP, SendGrid, Resend, Mailgun, your own mail server, etc. |
| `MAIL_FROM` | The "From" address on outgoing contact-form emails. Usually needs to be a domain verified with your SMTP provider. |
| `MAIL_TO_EGYPT` / `MAIL_TO_DEFAULT` | The two routing destinations. Defaults already match the client's request (`info@impactegypt.com` / `info@impact-ld.me`) — only change these if that changes. |

Until real `SMTP_*` values are set, the contact form still works end to
end (validates, stores the submission, routes correctly) but email
delivery fails gracefully — the failure and the intended recipient are
both visible in `/admin/submissions` and the API response, nothing is
silently lost.

## Contact form routing logic

`server/routes/contact.js`, function `routeByCountry`: the submitted
`country` field is lowercased and checked for `"egypt"` / `"eg"` /
`"egy"` / `"مصر"`. Match → `MAIL_TO_EGYPT`. No match (UAE, KSA, any other
country) → `MAIL_TO_DEFAULT`. The same logic is duplicated client-side in
`Contact.dc.html` purely as a `mailto:` fallback for the rare case the
backend is unreachable — the server's decision is always the
authoritative one for actual sent email.

## Deployment

This is a normal stateful Node.js app (SQLite file + an `assets/`
directory it writes to) — it needs a host that gives you a persistent
disk, not a purely serverless/stateless platform. Good fits: **Render**,
**Railway**, a small VPS (with a process manager like `pm2` or a
systemd service), or a Docker container with a mounted volume for
`server/db/` and `assets/`.

1. `npm install --production`
2. Set real environment variables (see above) — especially
   `SESSION_SECRET`, `SMTP_*`, and change the default admin password.
3. `npm run migrate` (safe to run on every deploy, see above).
4. `npm start`, behind a reverse proxy (nginx / the platform's own) that
   terminates HTTPS.
5. Once served over HTTPS, set `cookie.secure: true` in the session
   config in `server/index.js` so admin session cookies require HTTPS.
6. Point the domain's DNS / reverse-proxy at this server instead of
   wherever the static files were hosted before.

## What's *not* built yet

- **Rich content structures** (repeatable lists, reordering carousel
  items, image-per-item galleries) — the CMS edits every existing text
  field and swaps images by filename, but doesn't let you add/remove
  *items* within a list (e.g. add a 6th partner logo) without a code
  change. Flag this to whoever's driving content if it's needed.
- **Multi-admin roles / audit log** — currently one flat `admin_users`
  table, no per-user permissions or edit history beyond
  `content_fields.updated_at`.
- **Production session store** — sessions currently use
  `express-session`'s in-memory store (fine for one server / low
  traffic; will lose sessions on restart, and won't work if you run
  multiple server instances behind a load balancer). Swap in a
  persistent store (e.g. `connect-sqlite3`, or Redis) before scaling
  beyond a single instance.
- **Automated tests** — everything so far was verified manually
  end-to-end (page serving, login, field edit round-trip, add/delete
  page, asset upload/delete, contact-form routing for Egypt/UAE/KSA).
  Consider adding integration tests if this codebase will keep growing.
