"use strict";
window.initAccountSettings = (account, request) => {
  const settings = document.getElementById('account-settings');
  const status = document.getElementById('account-status');
  const preference = document.getElementById('personalization');
  settings.hidden = false;
  preference.checked = account.preferences.personalization;
  preference.addEventListener('change', async () => {
    const enabled = preference.checked;
    preference.disabled = true;
    try {
      account.preferences = await request('/v1/me/preferences', 'PUT', {...account.preferences, personalization: enabled});
      status.textContent = enabled ? 'Game preferences enabled.' : 'Game preferences cleared.';
    } catch (error) { preference.checked = !enabled; status.textContent = error.message; }
    finally { preference.disabled = false; }
  });
  const action = (id, run) => document.getElementById(id).addEventListener('click', async event => {
    const button = event.currentTarget;
    button.disabled = true;
    try { await run(); } catch (error) { status.textContent = error.message; }
    finally { button.disabled = false; }
  });
  action('unlink', async () => {
    await request('/v1/pairing/unlink', 'POST', {});
    status.textContent = 'Lobbies disconnected. Your artwork stays in your account.';
  });
  action('logout', async () => {
    await request('/v1/session', 'DELETE'); location.replace('/auth/login');
  });
  action('delete', async () => {
    if (!confirm('Delete your cloud profile, artwork, preferences and sessions?')) return;
    await request('/v1/me', 'DELETE'); location.replace('/');
  });
};
