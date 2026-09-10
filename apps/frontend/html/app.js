/* Aspecta UI.
 *
 * Deliberately dependency-free: no bundler, no framework, no CDN. That keeps
 * the image at nginx plus ~20 kB of assets, lets the content security policy
 * forbid every external origin, and removes the npm supply chain from the
 * deployment path. The API is same-origin because nginx proxies /api/ to the
 * backend Service.
 */
(() => {
  "use strict";

  const API = "/api/v1";
  const ALERT_REFRESH_MS = 15000;
  const STATS_REFRESH_MS = 30000;
  const SEARCH_DEBOUNCE_MS = 250;

  const el = (id) => document.getElementById(id);
  const dom = {
    banner: el("banner"),
    version: el("meta-version"),
    revision: el("meta-revision"),
    objects: el("meta-objects"),
    uptime: el("meta-uptime"),
    filters: el("filters"),
    q: el("q"),
    type: el("type"),
    constellation: el("constellation"),
    size: el("size"),
    results: el("results"),
    cards: el("cards"),
    count: el("result-count"),
    prev: el("prev"),
    next: el("next"),
    pageLabel: el("page-label"),
    alerts: el("alerts"),
    mix: el("mix"),
  };

  let page = 1;
  let pages = 1;
  let searchTimer = null;

  async function getJSON(path) {
    const res = await fetch(path, { headers: { Accept: "application/json" } });
    if (!res.ok) {
      const detail = await res.json().catch(() => null);
      throw new Error(detail?.error?.message || `Request failed with status ${res.status}`);
    }
    return res.json();
  }

  function text(node, value) {
    node.textContent = value;
  }

  function formatDistance(ly) {
    if (!ly) return "—";
    if (ly >= 1e6) return `${(ly / 1e6).toFixed(1)} Mly`;
    if (ly >= 1e3) return `${(ly / 1e3).toFixed(1)} kly`;
    return `${ly} ly`;
  }

  function formatUptime(seconds) {
    if (seconds === undefined || seconds === null) return "—";
    const d = Math.floor(seconds / 86400);
    const h = Math.floor((seconds % 86400) / 3600);
    const m = Math.floor((seconds % 3600) / 60);
    if (d) return `${d}d ${h}h`;
    if (h) return `${h}h ${m}m`;
    return `${m}m ${seconds % 60}s`;
  }

  function humanType(type) {
    return type ? type.replace(/-/g, " ") : "unknown";
  }

  function option(value, label) {
    const opt = document.createElement("option");
    opt.value = value;
    opt.textContent = label;
    return opt;
  }

  function fillSelect(select, values, formatter) {
    const current = select.value;
    while (select.options.length > 1) select.remove(1);
    values.forEach((v) => select.append(option(v, formatter ? formatter(v) : v)));
    if (values.includes(current)) select.value = current;
  }

  function buildCard(obj) {
    const li = document.createElement("li");
    li.className = "card";

    const ids = document.createElement("p");
    ids.className = "ids";
    ids.textContent = [obj.messier, obj.ngc].filter((v) => v && v !== "-").join(" · ");

    const title = document.createElement("h3");
    title.textContent = obj.name;

    const tag = document.createElement("span");
    tag.className = "tag";
    tag.textContent = humanType(obj.type);

    const desc = document.createElement("p");
    desc.textContent = obj.description || "";

    const dl = document.createElement("dl");
    const facts = [
      ["Constellation", obj.constellation || "—"],
      ["Magnitude", Number.isFinite(obj.magnitude) ? obj.magnitude.toFixed(1) : "—"],
      ["Distance", formatDistance(obj.distanceLy)],
      ["Found", obj.year ? `${obj.discoveredBy || "unknown"}, ${obj.year}` : obj.discoveredBy || "—"],
    ];
    facts.forEach(([label, value]) => {
      const wrap = document.createElement("div");
      const dt = document.createElement("dt");
      dt.textContent = label;
      const dd = document.createElement("dd");
      dd.textContent = value;
      wrap.append(dt, dd);
      dl.append(wrap);
    });

    li.append(ids, title, tag, desc, dl);
    return li;
  }

  function showError(message) {
    dom.cards.replaceChildren();
    const li = document.createElement("li");
    li.className = "error";
    li.setAttribute("role", "alert");
    li.textContent = message;
    dom.cards.append(li);
    text(dom.count, "unavailable");
  }

  function query() {
    const params = new URLSearchParams();
    if (dom.q.value.trim()) params.set("q", dom.q.value.trim());
    if (dom.type.value) params.set("type", dom.type.value);
    if (dom.constellation.value) params.set("constellation", dom.constellation.value);
    params.set("size", dom.size.value);
    params.set("page", String(page));
    return params.toString();
  }

  async function loadObjects() {
    dom.results.setAttribute("aria-busy", "true");
    try {
      const data = await getJSON(`${API}/objects?${query()}`);
      pages = Math.max(data.pages, 1);
      if (page > pages) {
        page = pages;
        return loadObjects();
      }

      dom.cards.replaceChildren(...data.items.map(buildCard));
      if (data.items.length === 0) {
        const li = document.createElement("li");
        li.className = "alerts empty";
        li.textContent = "No object matches these filters.";
        dom.cards.append(li);
      }
      text(dom.count, `${data.total} object${data.total === 1 ? "" : "s"} matched`);
      text(dom.pageLabel, `page ${data.page} of ${pages}`);
      dom.prev.disabled = data.page <= 1;
      dom.next.disabled = data.page >= pages;
    } catch (err) {
      showError(`Catalogue unavailable: ${err.message}`);
    } finally {
      dom.results.setAttribute("aria-busy", "false");
    }
  }

  async function loadStats() {
    try {
      const stats = await getJSON(`${API}/stats`);
      text(dom.banner, stats.banner || "Aspecta deep-sky catalogue");
      text(dom.version, stats.version || "—");
      text(dom.revision, stats.catalogue?.revision || "—");
      text(dom.objects, String(stats.catalogue?.objects ?? "—"));
      text(dom.uptime, formatUptime(stats.uptimeSeconds));

      fillSelect(dom.type, Object.keys(stats.countsByType || {}).sort(), humanType);
      fillSelect(dom.constellation, stats.constellations || []);

      dom.q.disabled = stats.searchEnabled === false;
      dom.q.placeholder = stats.searchEnabled === false
        ? "search disabled by configuration"
        : "orion, galaxy, Messier, Halley…";

      renderMix(stats.countsByType || {}, stats.catalogue?.objects || 0);
    } catch (err) {
      text(dom.banner, `Backend unreachable: ${err.message}`);
    }
  }

  function renderMix(counts, total) {
    const entries = Object.entries(counts).sort((a, b) => b[1] - a[1]);
    dom.mix.replaceChildren(...entries.map(([type, n]) => {
      const li = document.createElement("li");

      const row = document.createElement("div");
      row.className = "row";
      const label = document.createElement("span");
      label.textContent = humanType(type);
      const value = document.createElement("strong");
      value.textContent = String(n);
      row.append(label, value);

      const bar = document.createElement("div");
      bar.className = "bar";
      // Share of the catalogue, with a floor so a single-object type stays visible.
      bar.style.width = `${total ? Math.max((n / total) * 100, 4) : 0}%`;

      li.append(row, bar);
      return li;
    }));
  }

  function severityClass(alert) {
    if (alert.status === "resolved") return "resolved";
    if (["critical", "warning", "info"].includes(alert.severity)) return alert.severity;
    return "info";
  }

  async function loadAlerts() {
    try {
      const data = await getJSON(`${API}/alerts`);
      if (!data.items || data.items.length === 0) {
        const li = document.createElement("li");
        li.className = "empty";
        li.textContent = "No notification received yet. Alertmanager posts here as soon as a rule fires.";
        dom.alerts.replaceChildren(li);
        return;
      }
      dom.alerts.replaceChildren(...data.items.map((a) => {
        const li = document.createElement("li");

        const head = document.createElement("div");
        head.className = "name";
        const name = document.createElement("span");
        name.textContent = a.name || "unnamed alert";
        const badge = document.createElement("span");
        badge.className = `badge ${severityClass(a)}`;
        badge.textContent = a.status === "resolved" ? "resolved" : a.severity || "info";
        head.append(name, badge);

        const detail = document.createElement("div");
        detail.className = "detail";
        detail.textContent = a.summary || a.description || "no summary provided";

        li.append(head, detail);
        return li;
      }));
    } catch {
      /* The alert feed is auxiliary: a failure here must not disturb the page. */
    }
  }

  function onFilterChange() {
    page = 1;
    loadObjects();
  }

  dom.filters.addEventListener("submit", (e) => e.preventDefault());
  dom.q.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(onFilterChange, SEARCH_DEBOUNCE_MS);
  });
  [dom.type, dom.constellation, dom.size].forEach((n) => n.addEventListener("change", onFilterChange));
  dom.filters.addEventListener("reset", () => setTimeout(onFilterChange, 0));
  dom.prev.addEventListener("click", () => { if (page > 1) { page -= 1; loadObjects(); } });
  dom.next.addEventListener("click", () => { if (page < pages) { page += 1; loadObjects(); } });

  loadStats();
  loadObjects();
  loadAlerts();
  setInterval(loadAlerts, ALERT_REFRESH_MS);
  setInterval(loadStats, STATS_REFRESH_MS);
})();
