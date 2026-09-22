// Serves every *.dc.html page from the project root, but with its embedded
// `var EN = {...}; var AR = {...};` dictionaries replaced by whatever is
// currently in the database — so edits made in the admin CMS show up on
// the live pages without touching the HTML files on disk.

const fs = require('fs');
const path = require('path');
const express = require('express');
const db = require('../db');
const { replaceObjectLiteral } = require('../lib/objectLiteral');

const PROJECT_ROOT = path.join(__dirname, '..', '..');

const router = express.Router();

function pageFileExists(slug) {
  const file = path.join(PROJECT_ROOT, `${slug}.dc.html`);
  return fs.existsSync(file) ? file : null;
}

function loadFieldsAsDicts(slug) {
  const rows = db
    .prepare('SELECT field_key, en_value, ar_value FROM content_fields WHERE page_slug = ?')
    .all(slug);
  const EN = {};
  const AR = {};
  for (const row of rows) {
    EN[row.field_key] = row.en_value;
    AR[row.field_key] = row.ar_value;
  }
  return { EN, AR };
}

function renderPage(slug) {
  const file = pageFileExists(slug);
  if (!file) return null;

  const page = db.prepare('SELECT deleted FROM pages WHERE slug = ?').get(slug);
  if (page && page.deleted) return null;

  let html = fs.readFileSync(file, 'utf8');
  const { EN, AR } = loadFieldsAsDicts(slug);

  html = replaceObjectLiteral(html, 'EN', EN);
  html = replaceObjectLiteral(html, 'AR', AR);
  return html;
}

// Accept both "/Contact.dc.html" (matches every href already in the site)
// and the bare slug "/Contact" for convenience.
router.get(/^\/(.+?)(\.dc\.html)?$/, (req, res, next) => {
  const slug = decodeURIComponent(req.params[0]);
  if (!pageFileExists(slug)) return next();

  const html = renderPage(slug);
  if (html == null) return res.status(404).send('Page not found');

  res.set('Content-Type', 'text/html; charset=utf-8');
  res.send(html);
});

module.exports = { router, renderPage, loadFieldsAsDicts, pageFileExists };
