// Halcyon passman: watches for a login (a password field + a submit) and, after it, offers to save it.
(() => {
  if (window.top !== window) return;
  const host = location.hostname.replace(/^www\./, "");

  function usernameFor(pw) {
    const scope = pw.form || document;
    const cands = [...scope.querySelectorAll('input[type="email"], input[type="text"], input[type="tel"], input:not([type])')]
      .filter((i) => i.value && i.offsetParent !== null && !(i.compareDocumentPosition(pw) & Node.DOCUMENT_POSITION_PRECEDING));
    const named = cands.filter((i) => /user|login|email|mail|account|name/i.test(i.name + " " + i.id + " " + (i.autocomplete || "")));
    return ((named.length ? named : cands).pop() || { value: "" }).value;
  }

  let lastSent = "";
  function capture() {
    const pws = [...document.querySelectorAll('input[type="password"]')].filter((p) => p.value);
    if (pws.length !== 1) return;                     // 0 = nothing typed; 2+ = sign-up / change-password forms: stay out of them
    const pw = pws[0], user = usernameFor(pw), key = host + "\0" + user + "\0" + pw.value;
    if (key === lastSent) return;
    lastSent = key;
    chrome.runtime.sendMessage({ type: "captured", host, user, pass: pw.value }, () => setTimeout(offer, 1200));
  }

  document.addEventListener("submit", capture, true);
  document.addEventListener("keydown", (e) => { if (e.key === "Enter" && e.target && e.target.type === "password") capture(); }, true);
  document.addEventListener("click", (e) => {       // buttons of forms that are not real <form>s (most single-page apps)
    const b = e.target && e.target.closest && e.target.closest('button, [role="button"], input[type="submit"]');
    if (b && /log.?in|sign.?in|continue|next|submit|enter/i.test(b.innerText || b.value || "")) capture();
  }, true);

  // ---- the question (a closed shadow root: the page cannot read or click it)
  let box = null;
  function offer() {
    chrome.runtime.sendMessage({ type: "pending" }, (res) => {
      if (chrome.runtime.lastError || !res || !res.pending || box) return;
      const p = res.pending;
      box = document.createElement("div");
      box.style.cssText = "all:initial;position:fixed;top:16px;right:16px;z-index:2147483647";
      const root = box.attachShadow({ mode: "closed" });
      root.innerHTML = `
        <style>
          .c{font:13px system-ui,sans-serif;color:#e8e8ee;background:#16161d;border:1px solid #3a3a4a;border-radius:14px;padding:14px 16px;width:300px;box-shadow:0 10px 30px #0008}
          b{display:block;font-size:14px;margin-bottom:4px} p{margin:0 0 12px;color:#a8a8b8;word-break:break-all}
          .r{display:flex;gap:8px} button{font:inherit;border:0;border-radius:999px;padding:6px 14px;cursor:pointer;color:#e8e8ee;background:#2a2a36}
          button.s{background:#7aa2f7;color:#10101a;font-weight:600}
        </style>
        <div class="c"><b></b><p></p><div class="r"><button class="s">Save</button><button class="n">Not now</button><button class="v">Never</button></div></div>`;
      root.querySelector("b").textContent = (p.status === "changed" ? "Update password for " : "Save password for ") + p.host + "?";
      root.querySelector("p").textContent = (p.user || "(no username)") + "  ·  Halcyon vault";
      const done = (type) => () => { chrome.runtime.sendMessage({ type }, () => { box.remove(); box = null; }); };
      root.querySelector(".s").onclick = done("save");
      root.querySelector(".n").onclick = done("dismiss");
      root.querySelector(".v").onclick = done("never");
      document.documentElement.appendChild(box);
    });
  }
  offer();                                           // after a page load that followed a login
})();
