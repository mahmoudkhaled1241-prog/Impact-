const path = require('path');
const express = require('express');
const requireAuth = require('../middleware/requireAuth');

const ADMIN_DIR = path.join(__dirname, '..', 'public', 'admin');
const router = express.Router();

// CSS/JS are not sensitive and the login page needs them, so serve them
// unauthenticated under /admin/static.
router.use('/static', express.static(ADMIN_DIR));

router.get('/login', (req, res) => {
  if (req.session && req.session.adminId) return res.redirect('/admin');
  res.sendFile(path.join(ADMIN_DIR, 'login.html'));
});

router.get('/', requireAuth, (req, res) => res.sendFile(path.join(ADMIN_DIR, 'index.html')));
router.get('/page', requireAuth, (req, res) => res.sendFile(path.join(ADMIN_DIR, 'page.html')));
router.get('/assets', requireAuth, (req, res) => res.sendFile(path.join(ADMIN_DIR, 'assets.html')));
router.get('/submissions', requireAuth, (req, res) => res.sendFile(path.join(ADMIN_DIR, 'submissions.html')));

module.exports = router;
