// Halcyon passman: the service worker. It is the only part that talks to the native helper (scripts/passman-host.py),
// and the helper never sends a password back: it only says "known / new / changed", so a web page cannot read the vault.
const HOST = "com.halcyon.passman";
const PENDING_MS = 2 * 60 * 1000;

function ask(msg) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, msg, (res) => {
      if (chrome.runtime.lastError) resolve({ ok: false, error: chrome.runtime.lastError.message });
      else resolve(res || { ok: false, error: "no answer" });
    });
  });
}

async function setPending(tabId, data) { await chrome.storage.session.set({ ["p" + tabId]: data }); }
async function getPending(tabId) {
  const k = "p" + tabId, v = (await chrome.storage.session.get(k))[k];
  if (v && Date.now() - v.ts < PENDING_MS) return v;
  if (v) await chrome.storage.session.remove(k);
  return null;
}

chrome.runtime.onMessage.addListener((msg, sender, reply) => {
  const tabId = sender.tab && sender.tab.id;
  (async () => {
    if (msg.type === "captured") {
      // a form was submitted: ask the helper if this login is already stored / was refused for this site
      const r = await ask({ type: "check", host: msg.host, user: msg.user, pass: msg.pass });
      if (r.ok && (r.status === "new" || r.status === "changed")) {
        await setPending(tabId, { host: msg.host, user: msg.user, pass: msg.pass, status: r.status, ts: Date.now() });
      }
      reply({ ok: true });
    } else if (msg.type === "pending") {
      reply({ pending: await getPending(tabId) });
    } else if (msg.type === "save") {
      const p = await getPending(tabId);
      if (!p) return reply({ ok: false, error: "expired" });
      const r = await ask({ type: "save", host: p.host, user: p.user, pass: p.pass });
      await chrome.storage.session.remove("p" + tabId);
      reply(r);
    } else if (msg.type === "never") {
      const p = await getPending(tabId);
      if (p) await ask({ type: "never", host: p.host });
      await chrome.storage.session.remove("p" + tabId);
      reply({ ok: true });
    } else if (msg.type === "dismiss") {
      await chrome.storage.session.remove("p" + tabId);
      reply({ ok: true });
    }
  })();
  return true;
});
