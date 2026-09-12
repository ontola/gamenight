"use strict";
const $ = id => document.getElementById(id);
let busy = false, resendAt = 0;
function status(text) { $("status").textContent = text; }
async function submit(path, body) {
  const result = await fetch(path, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body)});
  if (result.ok) return;
  if (result.status === 429) throw new Error("Please wait a little before requesting another code.");
  if (result.status === 401) throw new Error("That code is incorrect or has expired. Try again, or request a new one.");
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
  setBusy(true); status("Sending your code…");
  try {
    await submit("/auth/email/request", {email: $("email").value.trim()});
    $("email-form").hidden = true; $("code-form").hidden = false;
    $("destination").textContent = "Sent to " + $("email").value.trim();
    $("code").value = ""; $("code").focus();
    resendAt = Date.now() + 60000; status("Check your inbox for your 8-digit code.");
  } catch(error) { status(error.message); } finally { setBusy(false); }
}
$("email-form").addEventListener("submit", event => { event.preventDefault(); sendCode(); });
$("resend").addEventListener("click", sendCode);
$("change").addEventListener("click", () => { $("code-form").hidden = true; $("email-form").hidden = false; $("email").focus(); status(""); });
$("code-form").addEventListener("submit", async event => {
  event.preventDefault(); if (busy) return; setBusy(true); status("Signing you in…");
  try { await submit("/auth/email/verify", {code: $("code").value.trim()}); location.replace("/studio"); }
  catch(error) { status(error.message); setBusy(false); $("code").focus(); }
});
setInterval(() => {
  const seconds = Math.max(0, Math.ceil((resendAt - Date.now()) / 1000));
  $("resend").textContent = seconds ? `Resend in ${seconds}s` : "Send a new code";
  $("resend").disabled = busy || seconds > 0;
}, 1000);
