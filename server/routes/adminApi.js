const fs = require('fs');
const path = require('path');
const express = require('express');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const db = require('../db');
const requireAuth = require('../middleware/requireAuth');

const PROJECT_ROOT = path.join(__dirname, '..', '..');
const ASSETS_DIR = path.join(PROJECT_ROOT, 'assets');

const router = express.Router();

// ---- Auth (unauthenticated) ----------------------------------------------

router.post('/login', (req, res) => {
  const { username, password } = req.body || {};
  if (!username || !password) {
    return res.status(400).json({ error: 'Username and password are required' });
  }
  const user = db.prepare('SELECT * FROM admin_users WHERE username = ?').get(username);
  if (!user || !bcrypt.compareSync(password, user.password_hash)) {
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  req.session.adminId = user.id;
  req.session.username = user.username;
  res.json({ ok: true, username: user.username });
});

router.post('/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

router.get('/me', (req, res) => {
  if (!req.session || !req.session.adminId) return res.status(401).json({ error: 'Not authenticated' });
  res.json({ username: req.session.username });
});

// ---- Everything below requires a logged-in admin -------------------------

router.use(requireAuth);

router.post('/change-password', (req, res) => {
  const { currentPassword, newPassword } = req.body || {};
  if (!currentPassword || !newPassword || newPassword.length < 8) {
    return res.status(400).json({ error: 'New password must be at least 8 characters' });
  }
  const user = db.prepare('SELECT * FROM admin_users WHERE id = ?').get(req.session.adminId);
  if (!bcrypt.compareSync(currentPassword, user.password_hash)) {
    return res.status(401).json({ error: 'Current password is incorrect' });
  }
  const hash = bcrypt.hashSync(newPassword, 10);
  db.prepare('UPDATE admin_users SET password_hash = ? WHERE id = ?').run(hash, user.id);
  res.json({ ok: true });
});

// ---- Pages -----------------------------------------------------------------

router.get('/pages', (req, res) => {
  const pages = db
    .prepare('SELECT slug, title, deleted, updated_at FROM pages ORDER BY slug COLLATE NOCASE')
    .all();
  res.json({ pages });
});

router.get('/pages/:slug/fields', (req, res) => {
  const { slug } = req.params;
  const page = db.prepare('SELECT * FROM pages WHERE slug = ?').get(slug);
  if (!page) return res.status(404).json({ error: 'Page not found' });
  const fields = db
    .prepare('SELECT id, field_key, en_value, ar_value FROM content_fields WHERE page_slug = ? ORDER BY field_key COLLATE NOCASE')
    .all(slug);
  res.json({ page, fields });
});

router.put('/pages/:slug/fields/:fieldId', (req, res) => {
  const { slug, fieldId } = req.params;
  const { en_value, ar_value } = req.body || {};
  const field = db.prepare('SELECT * FROM content_fields WHERE id = ? AND page_slug = ?').get(fieldId, slug);
  if (!field) return res.status(404).json({ error: 'Field not found' });
  db.prepare(`
    UPDATE content_fields SET en_value = ?, ar_value = ?, updated_at = datetime('now') WHERE id = ?
  `).run(en_value ?? '', ar_value ?? '', fieldId);
  db.prepare(`UPDATE pages SET updated_at = datetime('now') WHERE slug = ?`).run(slug);
  res.json({ ok: true });
});

router.post('/pages/:slug/fields', (req, res) => {
  const { slug } = req.params;
  const { field_key, en_value, ar_value } = req.body || {};
  const page = db.prepare('SELECT * FROM pages WHERE slug = ?').get(slug);
  if (!page) return res.status(404).json({ error: 'Page not found' });
  if (!field_key || !/^[A-Za-z0-9_]+$/.test(field_key)) {
    return res.status(400).json({ error: 'field_key is required and must be alphanumeric/underscore' });
  }
  try {
    const info = db.prepare(`
      INSERT INTO content_fields (page_slug, field_key, en_value, ar_value) VALUES (?, ?, ?, ?)
    `).run(slug, field_key, en_value ?? '', ar_value ?? '');
    res.json({ ok: true, id: info.lastInsertRowid });
  } catch (err) {
    if (String(err.message).includes('UNIQUE')) {
      return res.status(409).json({ error: 'A field with that key already exists on this page' });
    }
    throw err;
  }
});

router.delete('/pages/:slug/fields/:fieldId', (req, res) => {
  const { slug, fieldId } = req.params;
  const info = db.prepare('DELETE FROM content_fields WHERE id = ? AND page_slug = ?').run(fieldId, slug);
  if (info.changes === 0) return res.status(404).json({ error: 'Field not found' });
  res.json({ ok: true });
});

// Note on add/delete PAGE (not field): a brand new page needs an actual
// .dc.html file with markup, not just DB rows, since rendering re-uses the
// static file as its template (see routes/pages.js). This endpoint creates
// that file from a minimal generic template plus registers it in the DB.
// Deleting a page soft-deletes it (keeps history, 404s the public route)
// rather than removing the .dc.html file, which an admin can still do
// manually if they really want the file gone.

const NEW_PAGE_TEMPLATE = (title) => `<!DOCTYPE html>
<html lang="en" dir="ltr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title} | Impact for Learning &amp; Development</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&family=IBM+Plex+Sans+Arabic:wght@400;600;700&family=Inter:wght@400;500;600;700;800;900&display=swap" rel="stylesheet">
<style>
  :root { color-scheme: dark; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  html, body { background: #0A141D; }
  body { font-family: 'Inter', Helvetica, Arial, sans-serif; color: #F4FBFC; -webkit-font-smoothing: antialiased; }
  a { text-decoration: none; color: #18D4E2; }
  #root { position: relative; width: 100%; background: #0A141D; }
  #root.lang-ar { font-family: 'IBM Plex Sans Arabic', 'Inter', sans-serif; }
  header { position: sticky; top: 0; z-index: 50; display: flex; align-items: center; justify-content: space-between; gap: 10px 24px; padding: 14px clamp(20px, 6vw, 120px); background: rgba(10,20,29,.92); backdrop-filter: blur(10px); border-bottom: 1px solid rgba(140,205,214,.22); }
  header img { height: clamp(28px, 3vw, 38px); }
  .hero { padding: clamp(80px, 14vh, 160px) clamp(24px, 6vw, 120px) clamp(60px, 8vh, 100px); max-width: 900px; margin: 0 auto; display: grid; gap: 24px; }
  .hero h1 { font-weight: 700; font-size: clamp(30px, 4vw, 54px); line-height: 1.1; }
  .hero p { color: #AFC7CD; font-size: 17px; line-height: 1.65; }
  footer { background: #0E1B26; border-top: 1px solid rgba(140,205,214,.22); padding: 24px clamp(24px, 6vw, 120px); display: flex; justify-content: space-between; align-items: center; font-family: 'IBM Plex Mono', monospace; font-size: 12px; color: #567179; }
</style>
</head>
<body>
<div id="root" dir="ltr">
  <header>
    <a href="Impact L&amp;D Parallax.dc.html"><img src="assets/logo.png" alt="Impact"></a>
  </header>
  <section class="hero">
    <h1 data-t="heading">${title}</h1>
    <p data-t="intro">Edit this page's content from the admin CMS.</p>
  </section>
  <footer>
    <span data-t="copyright">© 2026 Impact for Learning &amp; Development. All rights reserved.</span>
  </footer>
</div>
<script>
(function () {
  var EN = { heading: '${title}', intro: "Edit this page's content from the admin CMS.", copyright: '© 2026 Impact for Learning & Development. All rights reserved.' };
  var AR = { heading: '${title}', intro: 'عدّل محتوى هذه الصفحة من لوحة التحكم.', copyright: '© 2026 إمباكت للتعلم والتطوير. جميع الحقوق محفوظة.' };
  var root = document.getElementById('root');
  var targets = document.querySelectorAll('[data-t]');
  function applyLang(lang) {
    var t = lang === 'ar' ? AR : EN;
    var isAr = lang === 'ar';
    root.setAttribute('dir', isAr ? 'rtl' : 'ltr');
    root.classList.toggle('lang-ar', isAr);
    targets.forEach(function (el) {
      var key = el.getAttribute('data-t');
      if (t[key] !== undefined) el.textContent = t[key];
    });
  }
  var saved = localStorage.getItem('impactLang');
  applyLang(saved === 'ar' ? 'ar' : 'en');
})();
</script>
</body>
</html>
`;

router.post('/pages', (req, res) => {
  const { slug, title } = req.body || {};
  if (!slug || !/^[A-Za-z0-9 &'-]+$/.test(slug)) {
    return res.status(400).json({ error: 'slug is required and may only contain letters, numbers, spaces, & \' -' });
  }
  const filePath = path.join(PROJECT_ROOT, `${slug}.dc.html`);
  if (fs.existsSync(filePath)) {
    return res.status(409).json({ error: 'A page file with that name already exists' });
  }
  const pageTitle = title || slug;
  fs.writeFileSync(filePath, NEW_PAGE_TEMPLATE(pageTitle), 'utf8');

  db.prepare(`INSERT INTO pages (slug, title) VALUES (?, ?)`).run(slug, pageTitle);
  db.prepare(`INSERT INTO content_fields (page_slug, field_key, en_value, ar_value) VALUES (?, 'heading', ?, ?)`)
    .run(slug, pageTitle, pageTitle);
  db.prepare(`INSERT INTO content_fields (page_slug, field_key, en_value, ar_value) VALUES (?, 'intro', ?, ?)`)
    .run(slug, "Edit this page's content from the admin CMS.", 'عدّل محتوى هذه الصفحة من لوحة التحكم.');
  db.prepare(`INSERT INTO content_fields (page_slug, field_key, en_value, ar_value) VALUES (?, 'copyright', ?, ?)`)
    .run(slug, '© 2026 Impact for Learning & Development. All rights reserved.', '© 2026 إمباكت للتعلم والتطوير. جميع الحقوق محفوظة.');

  res.json({ ok: true, slug });
});

router.delete('/pages/:slug', (req, res) => {
  const { slug } = req.params;
  const info = db.prepare(`UPDATE pages SET deleted = 1, updated_at = datetime('now') WHERE slug = ?`).run(slug);
  if (info.changes === 0) return res.status(404).json({ error: 'Page not found' });
  res.json({ ok: true });
});

router.post('/pages/:slug/restore', (req, res) => {
  const { slug } = req.params;
  const info = db.prepare(`UPDATE pages SET deleted = 0, updated_at = datetime('now') WHERE slug = ?`).run(slug);
  if (info.changes === 0) return res.status(404).json({ error: 'Page not found' });
  res.json({ ok: true });
});

// ---- Assets ----------------------------------------------------------------

router.get('/assets', (req, res) => {
  const files = fs.readdirSync(ASSETS_DIR).filter((f) => !f.startsWith('.'));
  const withStats = files.map((name) => {
    const stat = fs.statSync(path.join(ASSETS_DIR, name));
    return { name, size: stat.size, modified: stat.mtime };
  });
  res.json({ assets: withStats });
});

const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, ASSETS_DIR),
    filename: (req, file, cb) => {
      // Preserve the original name so it can be referenced by src="assets/<name>"
      // exactly as the page markup expects; optionally overridden via
      // req.body.filename to replace an existing asset under its exact name.
      const name = req.body && req.body.filename ? req.body.filename : file.originalname;
      cb(null, name);
    }
  }),
  limits: { fileSize: 15 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    const ok = /^image\/(png|jpe?g|webp|gif|svg\+xml)$/.test(file.mimetype);
    cb(ok ? null : new Error('Only image files are allowed'), ok);
  }
});

router.post('/assets', upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  res.json({ ok: true, name: req.file.filename });
});

router.delete('/assets/:name', (req, res) => {
  const name = req.params.name;
  const filePath = path.join(ASSETS_DIR, name);
  if (!filePath.startsWith(ASSETS_DIR) || !fs.existsSync(filePath)) {
    return res.status(404).json({ error: 'Asset not found' });
  }
  fs.unlinkSync(filePath);
  res.json({ ok: true });
});

// ---- Contact submissions (read-only view for the admin) --------------------

router.get('/contact-submissions', (req, res) => {
  const rows = db.prepare('SELECT * FROM contact_submissions ORDER BY created_at DESC LIMIT 200').all();
  res.json({ submissions: rows });
});

module.exports = router;
