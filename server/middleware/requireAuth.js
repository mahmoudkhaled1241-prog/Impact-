// Protects /admin/* pages and /api/admin/* endpoints. Relies on
// express-session having populated req.session.adminId at login.

module.exports = function requireAuth(req, res, next) {
  if (req.session && req.session.adminId) return next();

  if (req.path.startsWith('/api/')) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  return res.redirect('/admin/login');
};
