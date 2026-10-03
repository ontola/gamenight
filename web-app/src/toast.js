// One transient notification surface, shared by room and account actions.
window.showToast = (() => {
  let toast, message, timeout;
  return text => {
    if (!toast) {
      toast = document.createElement("div"); toast.className = "app-toast";
      message = document.createElement("span"); message.setAttribute("role", "status"); message.setAttribute("aria-live", "polite");
      const close = document.createElement("button"); close.type = "button"; close.className = "icon-btn";
      close.textContent = "×"; close.setAttribute("aria-label", "Dismiss notification");
      close.onclick = () => { clearTimeout(timeout); toast.hidden = true; };
      toast.append(message, close);
      toast.addEventListener("pointerenter", () => clearTimeout(timeout));
      toast.addEventListener("pointerleave", () => { timeout = setTimeout(() => { toast.hidden = true; }, 6000); });
    }
    clearTimeout(timeout);
    (document.querySelector("dialog[open]") || document.body).append(toast);
    message.textContent = text; toast.hidden = false;
    timeout = setTimeout(() => { toast.hidden = true; }, 8000);
  };
})();
