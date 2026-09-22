// Shared helpers used by every admin page.

async function api(path, options) {
  const res = await fetch('/api/admin' + path, {
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    ...options,
    body: options && options.body ? JSON.stringify(options.body) : undefined
  });
  if (res.status === 401) {
    window.location.href = '/admin/login';
    throw new Error('Not authenticated');
  }
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

function renderAdminHeader(activePath) {
  const el = document.getElementById('adminHeader');
  if (!el) return;
  el.innerHTML = `
    <div class="brand"><img src="assets/logo.png" alt="" style="height:24px" onerror="this.style.display='none'"> Impact CMS</div>
    <nav>
      <a href="/admin" class="${activePath === '/admin' ? 'active' : ''}">Pages</a>
      <a href="/admin/assets" class="${activePath === '/admin/assets' ? 'active' : ''}">Assets</a>
      <a href="/admin/submissions" class="${activePath === '/admin/submissions' ? 'active' : ''}">Contact Submissions</a>
    </nav>
    <div class="user">
      <span id="adminUsername"></span>
      <a href="#" id="logoutLink">Log out</a>
    </div>
  `;
  api('/me').then((data) => {
    document.getElementById('adminUsername').textContent = data.username;
  }).catch(() => {});
  document.getElementById('logoutLink').addEventListener('click', async (e) => {
    e.preventDefault();
    await api('/logout', { method: 'POST' });
    window.location.href = '/admin/login';
  });
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
