require('dotenv').config();

const path = require('path');
const express = require('express');
const session = require('express-session');

require('./db'); // ensures schema + default admin exist before anything else runs
require('./db/migrate')(); // idempotent: seeds any pages/fields not already in the DB

const pagesRoute = require('./routes/pages');
const adminApi = require('./routes/adminApi');
const adminPages = require('./routes/adminPages');
const contactRoute = require('./routes/contact');

const PROJECT_ROOT = path.join(__dirname, '..');
const app = express();

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

app.use(session({
  secret: process.env.SESSION_SECRET || 'dev-only-secret-change-me',
  resave: false,
  saveUninitialized: false,
  cookie: {
    httpOnly: true,
    maxAge: 1000 * 60 * 60 * 12, // 12 hours
    sameSite: 'lax'
    // NOTE: set `secure: true` once the site is served over HTTPS in
    // production (see server/README.md).
  }
}));

// Static assets (images) referenced by every page as src="assets/...".
app.use('/assets', express.static(path.join(PROJECT_ROOT, 'assets')));

// Public API
app.use('/api/contact', contactRoute);

// Admin (both the JSON API and the HTML/CSS/JS panel itself)
app.use('/api/admin', adminApi);
app.use('/admin', adminPages);

// Every *.dc.html page, served with live DB content injected in place of
// the hardcoded EN/AR dictionaries.
app.use('/', pagesRoute.router);

app.use((req, res) => res.status(404).send('Not found'));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  console.log(`Impact CMS server running at http://localhost:${PORT}`);
  console.log(`Admin panel:                http://localhost:${PORT}/admin/login`);
});
