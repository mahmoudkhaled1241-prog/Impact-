const path = require('path');
const bcrypt = require('bcryptjs');
const Database = require('better-sqlite3');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'cms.sqlite3');
const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS pages (
    slug TEXT PRIMARY KEY,          -- filename without .dc.html, e.g. "Contact"
    title TEXT NOT NULL,
    nav_label TEXT,                 -- optional label shown in generated nav/admin lists
    deleted INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS content_fields (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    page_slug TEXT NOT NULL REFERENCES pages(slug) ON DELETE CASCADE,
    field_key TEXT NOT NULL,        -- matches data-t="key" in the page HTML
    en_value TEXT NOT NULL DEFAULT '',
    ar_value TEXT NOT NULL DEFAULT '',
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    UNIQUE(page_slug, field_key)
  );

  CREATE TABLE IF NOT EXISTS admin_users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS contact_submissions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    inquiry_type TEXT,
    name TEXT,
    email TEXT,
    company TEXT,
    role TEXT,
    country TEXT,
    service_interest TEXT,
    budget TEXT,
    timeline TEXT,
    message TEXT,
    routed_to TEXT,                 -- which mailbox this was sent to
    email_sent INTEGER NOT NULL DEFAULT 0,
    email_error TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`);

function ensureDefaultAdmin() {
  const existing = db.prepare('SELECT COUNT(*) AS n FROM admin_users').get();
  if (existing.n > 0) return;
  const username = process.env.ADMIN_USERNAME || 'admin';
  const password = process.env.ADMIN_PASSWORD || 'changeme';
  const hash = bcrypt.hashSync(password, 10);
  db.prepare('INSERT INTO admin_users (username, password_hash) VALUES (?, ?)').run(username, hash);
  console.log(`[db] Created default admin user "${username}". Set ADMIN_USERNAME/ADMIN_PASSWORD in .env to control this.`);
}

ensureDefaultAdmin();

module.exports = db;
