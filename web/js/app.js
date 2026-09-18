(function () {
  'use strict';

  const dropzone = document.getElementById('dropzone');
  const fileInput = document.getElementById('fileInput');
  const results = document.getElementById('results');
  const fileList = document.getElementById('fileList');
  const resultsSummary = document.getElementById('resultsSummary');
  const downloadAllBtn = document.getElementById('downloadAllBtn');
  const addMoreBtn = document.getElementById('addMoreBtn');
  const convertAllBtn = document.getElementById('convertAllBtn');
  const clearBtn = document.getElementById('clearBtn');
  const toastsEl = document.getElementById('toasts');
  const cardTemplate = document.getElementById('fileCardTemplate');
  const convertToggle = document.getElementById('convertToggle');

  /** @type {Map<string, {name:string, li:HTMLElement, cleanedBytes:Uint8Array|null, ok:boolean}>} */
  const items = new Map();
  let seq = 0;

  // ---------------- Theme ----------------
  // Always launches in light (day) mode - the toggle only affects the current
  // session and is intentionally not remembered across app launches.
  const themeToggle = document.getElementById('themeToggle');
  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
  }
  applyTheme('light');
  themeToggle.addEventListener('click', () => {
    const current = document.documentElement.getAttribute('data-theme') || 'light';
    applyTheme(current === 'dark' ? 'light' : 'dark');
  });

  // ---------------- PNG->JPEG conversion toggle ----------------
  (function initConvertToggle() {
    let saved = null;
    try { saved = localStorage.getItem('metadataEraserConvertPngToJpeg'); } catch (e) { /* ignore */ }
    convertToggle.checked = saved === 'true';
  })();
  convertToggle.addEventListener('change', () => {
    try { localStorage.setItem('metadataEraserConvertPngToJpeg', convertToggle.checked ? 'true' : 'false'); } catch (e) { /* private mode */ }
  });

  // ---------------- Self-update ----------------
  const updateBtn = document.getElementById('updateBtn');
  const updateDot = document.getElementById('updateDot');
  const updateIcon = updateBtn.querySelector('.icon-update');

  function reloadWithCacheBust() {
    window.location.href = window.location.pathname + '?v=' + Date.now();
  }

  async function waitForBackendAndReload() {
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 600));
      try {
        const r = await fetch('/api/ping', { cache: 'no-store' });
        if (r.ok) { reloadWithCacheBust(); return; }
      } catch (err) { /* backend is mid-restart between processes - keep polling */ }
    }
    showToast('The app is taking longer than expected to restart — try reloading the page manually.', 'error');
  }

  async function checkForUpdate() {
    const res = await fetch('/api/update/check', { cache: 'no-store' });
    if (!res.ok) {
      const body = await res.json().catch(() => null);
      throw new Error((body && body.error) || `Server error (${res.status}).`);
    }
    return res.json();
  }

  async function applyUpdate() {
    if (updateBtn.disabled) return;
    updateBtn.disabled = true;
    updateIcon.classList.add('spin');
    try {
      const status = await checkForUpdate();
      updateDot.hidden = status.upToDate;
      if (status.upToDate) {
        showToast("You're already up to date.", 'success');
        return;
      }

      const count = status.changedFiles.length;
      showToast(`Downloading ${count} updated file${count === 1 ? '' : 's'}…`);
      const applyRes = await fetch('/api/update/apply', { method: 'POST' });
      if (!applyRes.ok) {
        const body = await applyRes.json().catch(() => null);
        throw new Error((body && body.error) || `Server error (${applyRes.status}).`);
      }
      const result = await applyRes.json();
      updateDot.hidden = true;

      if (result.backendChanged) {
        showToast('Update downloaded — restarting the app…', 'success');
        // The restart response may never arrive if the backend swaps ports mid-reply - that's
        // expected, not an error, so the wait-and-reload loop below is what actually matters.
        fetch('/api/update/restart', { method: 'POST' }).catch(() => { /* expected */ });
        await waitForBackendAndReload();
      } else if (result.frontendChanged) {
        showToast('Update downloaded — reloading…', 'success');
        setTimeout(reloadWithCacheBust, 800);
      } else {
        showToast('Update downloaded.', 'success');
      }
    } catch (err) {
      showToast('Update failed: ' + err.message, 'error');
    } finally {
      updateBtn.disabled = false;
      updateIcon.classList.remove('spin');
    }
  }

  updateBtn.addEventListener('click', applyUpdate);

  // A quiet check on launch just flags the dot - it never downloads or restarts anything
  // without the user clicking the button themselves.
  checkForUpdate().then((status) => { updateDot.hidden = status.upToDate; }).catch(() => { /* offline, or the repo API is unreachable - stay quiet */ });

  // ---------------- Toasts ----------------
  function showToast(message, kind) {
    const el = document.createElement('div');
    el.className = 'toast' + (kind ? ` toast-${kind}` : '');
    el.textContent = message;
    toastsEl.appendChild(el);
    setTimeout(() => el.remove(), 4200);
  }

  // ---------------- Helpers ----------------
  function formatBytes(n) {
    if (n < 1024) return `${n} B`;
    if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
    return `${(n / (1024 * 1024)).toFixed(2)} MB`;
  }

  function base64ToBytes(base64) {
    const binary = atob(base64);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  }

  function cleanedFileName(originalName, format) {
    const dot = originalName.lastIndexOf('.');
    const base = dot > 0 ? originalName.slice(0, dot) : originalName;
    // format-driven, not a reuse of the original extension - a converted PNG must come
    // out named .jpg, not sd_style_clean.png containing JPEG bytes.
    const ext = format === 'png' ? '.png' : '.jpg';
    return `${base}_clean${ext}`;
  }

  function triggerDownload(bytes, name, mime) {
    const blob = new Blob([bytes], { type: mime || 'application/octet-stream' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
  }

  function updateSummaryAndDownloadState() {
    const all = Array.from(items.values());
    const done = all.filter((i) => i.cleanedBytes || i.ok === false);
    const okCount = all.filter((i) => i.cleanedBytes).length;
    const errorCount = all.filter((i) => i.ok === false).length;

    if (all.length === 0) {
      resultsSummary.textContent = '';
    } else if (done.length < all.length) {
      resultsSummary.innerHTML = `Processing <strong>${all.length}</strong> file${all.length === 1 ? '' : 's'}…`;
    } else {
      let text = `<strong>${okCount}</strong> file${okCount === 1 ? '' : 's'} cleaned`;
      if (errorCount > 0) text += ` &middot; <strong>${errorCount}</strong> failed`;
      resultsSummary.innerHTML = text;
    }
    downloadAllBtn.disabled = okCount === 0;
    const pngCount = all.filter((i) => i.cleanedBytes && i.result && i.result.format === 'png').length;
    convertAllBtn.disabled = pngCount === 0;
  }

  // ---------------- Rendering ----------------
  function renderChips(container, entries, extraChipHtml) {
    container.innerHTML = '';
    if (extraChipHtml) container.insertAdjacentHTML('beforeend', extraChipHtml);
    for (const entry of entries) {
      const chip = document.createElement('span');
      chip.className = 'chip' + (entry.isAi ? ' chip-ai' : '');
      chip.textContent = entry.isAi ? `⚠ ${entry.label}` : entry.label;
      container.appendChild(chip);
    }
  }

  function createCard(id, name, sizeLabel) {
    const frag = cardTemplate.content.cloneNode(true);
    const li = frag.querySelector('.file-card');
    li.dataset.id = id;
    const guessedExt = name.split('.').pop().toLowerCase();
    const icon = li.querySelector('[data-role="icon"]');
    icon.textContent = guessedExt.toUpperCase().slice(0, 4);
    icon.dataset.format = /^jpe?g$/.test(guessedExt) ? 'jpeg' : 'png';
    li.querySelector('[data-role="name"]').textContent = name;
    li.querySelector('[data-role="meta"]').textContent = sizeLabel;
    const status = li.querySelector('[data-role="status"]');
    status.innerHTML = '<span class="spinner" aria-hidden="true"></span><span>Scanning…</span>';
    status.className = 'file-status status-processing';
    const downloadBtn = li.querySelector('[data-role="download"]');
    downloadBtn.disabled = true;
    fileList.appendChild(li);
    return li;
  }

  function markSuccess(li, entry, result) {
    li.classList.remove('has-error');
    const meta = li.querySelector('[data-role="meta"]');
    const saved = result.originalSize - result.cleanedSize;
    const savedLabel = saved > 0 ? ` &middot; <span class="size-saved">${formatBytes(saved)} smaller</span>` : '';
    const formatLabel = result.convertedFrom
      ? `${result.convertedFrom.toUpperCase()} → ${result.format.toUpperCase()}`
      : result.format.toUpperCase();
    meta.innerHTML = `${formatLabel} &middot; ${formatBytes(result.originalSize)} → ${formatBytes(result.cleanedSize)}${savedLabel}`;

    // Reflect the actual output format on the file's badge icon, not just what was
    // dropped in - a converted PNG should read "JPG", not still show "PNG".
    const icon = li.querySelector('[data-role="icon"]');
    icon.textContent = result.format === 'png' ? 'PNG' : 'JPG';
    icon.dataset.format = result.format;

    const chipsEl = li.querySelector('[data-role="chips"]');
    if (result.before.length === 0) {
      renderChips(chipsEl, [], '<span class="chip chip-clean">✓ Already clean</span>');
    } else {
      const aiCount = result.before.filter((b) => b.isAi).length;
      const badge = aiCount > 0
        ? `<span class="chip chip-clean">✓ ${result.before.length} item${result.before.length === 1 ? '' : 's'} removed (${aiCount} AI-related)</span>`
        : `<span class="chip chip-clean">✓ ${result.before.length} item${result.before.length === 1 ? '' : 's'} removed</span>`;
      renderChips(chipsEl, result.before, badge);
    }

    const status = li.querySelector('[data-role="status"]');
    status.className = 'file-status status-ok';
    status.innerHTML = '<span aria-hidden="true">✓</span><span>Cleaned</span>';

    const downloadBtn = li.querySelector('[data-role="download"]');
    downloadBtn.disabled = false;
    downloadBtn.onclick = () => {
      triggerDownload(entry.cleanedBytes, cleanedFileName(result.name, result.format), result.format === 'png' ? 'image/png' : 'image/jpeg');
    };

    const inspectBtn = li.querySelector('[data-role="inspect"]');
    const details = Array.isArray(result.details) ? result.details : [];
    if (details.length > 0) {
      inspectBtn.hidden = false;
      inspectBtn.onclick = () => toggleInspector(li, details);
    }
  }

  function toggleInspector(li, details) {
    const panel = li.querySelector('[data-role="inspector"]');
    const btn = li.querySelector('[data-role="inspect"]');
    const isOpen = !panel.hidden;
    if (isOpen) {
      panel.hidden = true;
      btn.setAttribute('aria-expanded', 'false');
      return;
    }
    if (!panel.dataset.rendered) {
      renderInspector(li, details);
      panel.dataset.rendered = '1';
    }
    panel.hidden = false;
    btn.setAttribute('aria-expanded', 'true');
  }

  function renderInspector(li, details) {
    const body = li.querySelector('[data-role="inspector-body"]');
    const count = li.querySelector('[data-role="inspector-count"]');
    count.textContent = `${details.length} item${details.length === 1 ? '' : 's'}`;
    body.innerHTML = '';
    if (details.length === 0) {
      const empty = document.createElement('p');
      empty.className = 'metadata-table-empty';
      empty.textContent = 'No metadata found in this file.';
      body.appendChild(empty);
      return;
    }
    for (const item of details) {
      const dt = document.createElement('dt');
      dt.textContent = item.key;
      if (item.isAi) dt.classList.add('key-ai');
      const dd = document.createElement('dd');
      dd.textContent = item.value;
      if (item.isAi) dd.classList.add('value-ai');
      body.appendChild(dt);
      body.appendChild(dd);
    }
  }

  function markError(li, message) {
    li.classList.add('has-error');
    const status = li.querySelector('[data-role="status"]');
    status.className = 'file-status status-error';
    status.innerHTML = '<span aria-hidden="true">✕</span><span>Failed</span>';
    const main = li.querySelector('.file-card-main');
    const detail = document.createElement('p');
    detail.className = 'file-error-detail';
    detail.textContent = message;
    li.appendChild(detail);
    main.querySelector('[data-role="download"]').remove();
  }

  // ---------------- Completion celebration ----------------
  const celebrationEl = document.getElementById('celebration');
  const celebrationLineEl = document.getElementById('celebrationLine');
  const poeticLines = [
    'No longer remembers where it came from.',
    'Every trace, let go on the wind.',
    'Clean as morning light on paper.',
    'It carries only what you can see.',
    'The ghosts have gone quiet.',
    'Nothing hidden. Nothing left to find.',
    'Unburdened, and a little lighter.',
  ];
  let celebrationTimer = null;
  function celebrateCompletion() {
    if (!celebrationEl) return;
    celebrationLineEl.textContent = poeticLines[Math.floor(Math.random() * poeticLines.length)];
    celebrationEl.hidden = false;
    celebrationEl.classList.remove('play');
    void celebrationEl.offsetWidth; // restart the CSS animation on repeat triggers
    celebrationEl.classList.add('play');
    clearTimeout(celebrationTimer);
    celebrationTimer = setTimeout(() => {
      celebrationEl.hidden = true;
      celebrationEl.classList.remove('play');
    }, 3400);
  }

  // ---------------- Upload / processing ----------------
  // Shared by the initial drop/pick upload and the "Convert PNGs to JPEG" re-submit:
  // both send a batch of {id, file} to /api/strip and apply the results to `items`.
  async function submitBatch(batch, convertPngToJpeg) {
    const formData = new FormData();
    for (const { file } of batch) formData.append('files', file, file.name);
    formData.append('convertPngToJpeg', convertPngToJpeg ? 'true' : 'false');

    let response;
    try {
      response = await fetch('/api/strip', { method: 'POST', body: formData });
    } catch (err) {
      for (const { id } of batch) {
        const entry = items.get(id);
        entry.ok = false;
        markError(entry.li, 'Could not reach the local backend.');
      }
      updateSummaryAndDownloadState();
      showToast('Network error contacting the backend.', 'error');
      return;
    }

    if (!response.ok) {
      let message = `Server error (${response.status}).`;
      try { const body = await response.json(); if (body && body.error) message = body.error; } catch (e) { /* ignore */ }
      for (const { id } of batch) {
        const entry = items.get(id);
        entry.ok = false;
        markError(entry.li, message);
      }
      updateSummaryAndDownloadState();
      showToast(message, 'error');
      return;
    }

    const payload = await response.json();
    const resultsByName = new Map();
    for (const r of payload.results) {
      if (!resultsByName.has(r.name)) resultsByName.set(r.name, []);
      resultsByName.get(r.name).push(r);
    }

    let batchSuccessCount = 0;
    for (const { id, file } of batch) {
      const entry = items.get(id);
      const queue = resultsByName.get(file.name) || [];
      const result = queue.shift();
      if (!result) {
        entry.ok = false;
        markError(entry.li, 'No result returned for this file.');
        continue;
      }
      if (result.ok) {
        entry.ok = true;
        entry.cleanedBytes = base64ToBytes(result.cleanedBase64);
        entry.result = result;
        markSuccess(entry.li, entry, result);
        batchSuccessCount++;
      } else {
        entry.ok = false;
        markError(entry.li, result.error || 'Unknown error.');
      }
    }
    updateSummaryAndDownloadState();
    if (batchSuccessCount > 0) celebrateCompletion();
  }

  async function processFiles(fileArray) {
    const valid = fileArray.filter((f) => f.type === 'image/png' || f.type === 'image/jpeg' || /\.(png|jpe?g)$/i.test(f.name));
    const rejected = fileArray.length - valid.length;
    if (rejected > 0) showToast(`${rejected} file${rejected === 1 ? '' : 's'} skipped (not PNG/JPEG).`, 'error');
    if (valid.length === 0) return;

    results.hidden = false;

    const batch = valid.map((file) => {
      const id = `f${++seq}`;
      const li = createCard(id, file.name, formatBytes(file.size));
      const entry = { name: file.name, file, li, cleanedBytes: null, ok: null };
      items.set(id, entry);
      return { id, file };
    });
    updateSummaryAndDownloadState();

    await submitBatch(batch, convertToggle.checked);
  }

  async function convertAllPngsToJpeg() {
    const batch = [];
    for (const [id, entry] of items.entries()) {
      if (entry.cleanedBytes && entry.result && entry.result.format === 'png') {
        batch.push({ id, file: entry.file });
      }
    }
    if (batch.length === 0) return;

    convertAllBtn.disabled = true;
    for (const { id } of batch) {
      const entry = items.get(id);
      const status = entry.li.querySelector('[data-role="status"]');
      status.className = 'file-status status-processing';
      status.innerHTML = '<span class="spinner" aria-hidden="true"></span><span>Converting…</span>';
    }

    await submitBatch(batch, true);
  }

  // ---------------- Drag & drop / picker ----------------
  dropzone.addEventListener('click', () => fileInput.click());
  dropzone.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fileInput.click(); }
  });
  fileInput.addEventListener('change', () => {
    if (fileInput.files.length) processFiles(Array.from(fileInput.files));
    fileInput.value = '';
  });

  ['dragenter', 'dragover'].forEach((evt) => {
    dropzone.addEventListener(evt, (e) => {
      e.preventDefault();
      e.stopPropagation();
      dropzone.classList.add('drag-active');
    });
  });
  ['dragleave', 'dragend'].forEach((evt) => {
    dropzone.addEventListener(evt, (e) => {
      e.preventDefault();
      dropzone.classList.remove('drag-active');
    });
  });
  dropzone.addEventListener('drop', (e) => {
    e.preventDefault();
    e.stopPropagation();
    dropzone.classList.remove('drag-active');
    const files = Array.from(e.dataTransfer.files || []);
    if (files.length) processFiles(files);
  });

  // Prevent the browser from navigating to a dropped file if the user misses the zone.
  ['dragover', 'drop'].forEach((evt) => {
    window.addEventListener(evt, (e) => e.preventDefault());
  });

  addMoreBtn.addEventListener('click', () => fileInput.click());

  convertAllBtn.addEventListener('click', () => { convertAllPngsToJpeg(); });

  clearBtn.addEventListener('click', () => {
    items.clear();
    fileList.innerHTML = '';
    results.hidden = true;
    clearTimeout(celebrationTimer);
    celebrationEl.hidden = true;
    celebrationEl.classList.remove('play');
    updateSummaryAndDownloadState();
  });

  downloadAllBtn.addEventListener('click', () => {
    const entries = [];
    const usedNames = new Set();
    for (const entry of items.values()) {
      if (!entry.cleanedBytes) continue;
      let name = cleanedFileName(entry.name, entry.result.format);
      let n = 1;
      while (usedNames.has(name)) {
        const dot = name.lastIndexOf('.');
        name = dot > 0 ? `${name.slice(0, dot)}_${n}${name.slice(dot)}` : `${name}_${n}`;
        n++;
      }
      usedNames.add(name);
      entries.push({ name, data: entry.cleanedBytes });
    }
    if (entries.length === 0) return;
    const zipBlob = window.MiniZip.buildZip(entries);
    const url = URL.createObjectURL(zipBlob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'cleaned-images.zip';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
  });

  // ---------------- Heartbeat (lets the PowerShell host know the tab is alive) ----------------
  function sendHeartbeat() {
    fetch('/api/heartbeat', { method: 'POST' }).catch(() => { /* backend may be shutting down */ });
  }
  sendHeartbeat();
  setInterval(sendHeartbeat, 15000);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') sendHeartbeat();
  });
  window.addEventListener('pagehide', () => {
    try { navigator.sendBeacon('/api/heartbeat'); } catch (e) { /* ignore */ }
  });
})();
