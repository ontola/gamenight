"use strict";
// Redirects retain the original fragment. Keep room invitations through sign-in.
const invitation = new URLSearchParams(location.hash.slice(1));
for (const kind of ["pair", "room"]) {
  const value = invitation.get(kind);
  if (value) sessionStorage.setItem(kind === "pair" ? "gamenight_pair" : "gamenight_room_code", value);
}
const emailCode = invitation.get("code");
if (invitation.has("pair") || invitation.has("room") || invitation.has("code")) history.replaceState(null, "", location.pathname + location.search);

const $ = id => document.getElementById(id);
let busy = false, resendAt = 0;
let fromEmailLink = false;
function status(text) { $("status").textContent = text; }
async function submit(path, body) {
  const result = await fetch(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  if (result.ok) return;
  if (result.status === 429) throw new Error("Please wait a little before requesting another code.");
  if (result.status === 401) throw new Error(fromEmailLink
    ? "Open this link in the browser where you requested the email, or enter the code in your original sign-in tab. If it has expired, request a new email."
    : "That code is incorrect or has expired. Try again, or request a new email.");
  if (result.status === 502) throw new Error("We couldn’t send your email. Please try again in a minute.");
  throw new Error("Couldn’t sign in. Please try again.");
}
function setBusy(value) {
  busy = value;
  document.querySelectorAll("button").forEach(button => { button.disabled = value; });
  $("resend").disabled = value || Date.now() < resendAt;
}
async function sendCode() {
  if (busy) return;
  setBusy(true); status("Sending your sign-in email…");
  try {
    await submit("/auth/email/request", {email: $("email").value.trim()});
    $("email-form").hidden = true; $("code-form").hidden = false;
    fromEmailLink = false; $("resend").hidden = false;
    $("destination").textContent = "Sent to " + $("email").value.trim();
    $("code").value = ""; $("code").focus();
    resendAt = Date.now() + 60000; status("Check your inbox. Open the sign-in link or enter your 8-digit code below.");
  } catch(error) { status(error.message); } finally { setBusy(false); }
}
$("email-form").addEventListener("submit", event => { event.preventDefault(); sendCode(); });
$("resend").addEventListener("click", sendCode);
$("change").addEventListener("click", () => { $("code-form").hidden = true; $("email-form").hidden = false; $("email").focus(); status(""); });
$("code").addEventListener("input", () => { $("code").value = $("code").value.replace(/\D/g, "").slice(0, 8); });
$("code-form").addEventListener("submit", async event => {
  event.preventDefault(); if (busy) return; setBusy(true); status("Signing you in…");
  try { await submit("/auth/email/verify", {code: $("code").value.trim()}); location.replace("/studio"); }
  catch(error) { status(error.message); setBusy(false); $("code").focus(); }
});
setInterval(() => {
  const seconds = Math.max(0, Math.ceil((resendAt - Date.now()) / 1000));
  $("resend").textContent = seconds ? `Resend in ${seconds}s` : "Send a new email";
  $("resend").disabled = busy || seconds > 0;
}, 1000);
if (emailCode && /^\d{8}$/.test(emailCode)) {
  fromEmailLink = true;
  $("email-form").hidden = true; $("code-form").hidden = false;
  $("code").value = emailCode;
  $("destination").textContent = "Your email link filled in the code. Confirm below to continue.";
  $("resend").hidden = true;
  $("change").textContent = "Use another email";
  $("code-form").querySelector("button[type=submit]").focus();
}
