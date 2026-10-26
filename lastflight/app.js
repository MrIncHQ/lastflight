// Last Flight NUI: check-in, transport, readiness, HUD, audio, farewell.
(() => {
    const RES = typeof GetParentResourceName === 'function' ? GetParentResourceName() : 'lastflight';
    const $ = (id) => document.getElementById(id);
    const post = (name, data = {}) =>
        fetch(`https://${RES}/${name}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }).catch(() => {});

    let cfg = { flight: 'LS-VI-001', destination: 'Vice City', keys: { ready: 'G', camera: 'H' } };
    let desk = null;
    let etaTimer = null;
    let readyTimer = null;
    let readyState = false;

    const fmt = (s) => {
        s = Math.max(0, Math.floor(s));
        return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
    };
    const show = (id) => $(id).classList.remove('hidden');
    const hide = (id) => $(id).classList.add('hidden');

    // ---------------- Toasts ----------------
    function toast({ msg, kind = 'info', duration = 6000 }) {
        const el = document.createElement('div');
        el.className = `toast ${kind}`;
        el.textContent = msg;
        $('toasts').appendChild(el);
        setTimeout(() => { el.classList.add('out'); setTimeout(() => el.remove(), 350); }, duration);
    }

    // ---------------- Desk ----------------
    function renderDesk(info, resultMsg, ok) {
        desk = info;
        $('desk-airport').textContent = info.airport || cfg.airport || '';
        $('desk-flight').textContent = info.flight;
        $('desk-dest').textContent = info.destination;
        $('desk-dest2').textContent = info.destination;
        $('desk-price').textContent = `$${info.price}`;

        const body = $('desk-body');
        const buy = $('btn-buy');
        body.innerHTML = '';
        clearInterval(etaTimer);
        buy.disabled = false;
        buy.textContent = 'Purchase Ticket';
        buy.onclick = () => { buy.disabled = true; post('buy'); };

        const note = (html, cls = '') => { body.innerHTML = `<div class="notice ${cls}">${html}</div>`; };

        if (resultMsg && ok === false) note(resultMsg, 'err');

        if (info.completed && info.status === 'none') {
            note('Our records show you have already taken the last flight. Thank you for flying with us!', 'warn');
            buy.disabled = true;
        } else if (info.status === 'boarding') {
            note(`Ticket <b>#${info.ticketId}</b> confirmed. Boarding is open for flight <b>${info.flight}</b>.`);
            buy.textContent = 'Get to the Gate';
            buy.onclick = () => openTransport(info);
        } else if (info.status === 'queued') {
            const box = (label) =>
                note(`Your flight to ${info.destination} is being prepared.<span class="eta" id="eta">${label}</span>`, 'warn');
            if (typeof info.eta === 'number') {
                let left = info.eta;
                box(left <= 0 ? 'Boarding shortly' : `Estimated boarding in ${fmt(left)}`);
                etaTimer = setInterval(() => {
                    left -= 1;
                    const el = $('eta');
                    if (el) el.textContent = left <= 0 ? 'Boarding shortly' : `Estimated boarding in ${fmt(left)}`;
                }, 1000);
            } else {
                box('Awaiting aircraft return');
            }
            buy.textContent = 'Ticket Held';
            buy.disabled = true;
        } else if (info.status === 'aboard') {
            note('You are already aboard. Enjoy the flight!');
            buy.disabled = true;
        }
        hide('transport');
        show('desk');
    }

    function openTransport(info) {
        hide('desk');
        $('opt-drive').classList.toggle('hidden', info.drive === false);
        $('opt-shuttle').classList.toggle('hidden', info.shuttle === false);
        show('transport');
    }

    $('btn-cancel').onclick = () => post('close');
    $('btn-later').onclick = () => post('close');
    $('opt-drive').onclick = () => post('transport', { choice: 'drive' });
    $('opt-shuttle').onclick = () => post('transport', { choice: 'shuttle' });

    // ---------------- Readiness ----------------
    function renderManifest(d) {
        $('r-ready').textContent = d.ready;
        $('r-total').textContent = d.total;
        $('r-bar').style.width = d.total > 0 ? `${(d.ready / d.total) * 100}%` : '0%';
        $('r-status').textContent = d.status;
        if (d.key) $('r-key').textContent = d.key;

        clearInterval(readyTimer);
        const t = $('r-timer');
        if (typeof d.timer === 'number') {
            let left = d.timer;
            t.textContent = fmt(left);
            readyTimer = setInterval(() => { left -= 1; t.textContent = fmt(left); }, 1000);
        } else {
            t.textContent = '';
        }
        readyState = !!d.youReady;
        const btn = $('btn-ready');
        btn.classList.toggle('is-ready', readyState);
        btn.textContent = readyState ? 'READY - TAP TO CANCEL' : 'READY FOR MY NEW ADVENTURE';
        btn.disabled = !!d.locked;
    }
    $('btn-ready').onclick = () => post('ready', { value: !readyState });

    // ---------------- Audio ----------------
    const tracks = {};
    const preloaded = {};

    let playlist = null;

    function stopTrack(kind) {
        if (kind === 'music' && playlist) { playlist.cancel = true; playlist = null; }
        const a = tracks[kind];
        if (a) { a.pause(); a.src = ''; delete tracks[kind]; }
    }

    // Songs back to back from `offset` seconds into the playlist. A missing
    // file is "played" silently for its duration so later songs stay in sync.
    function playPlaylist({ tracks: list = [], volume = 0.5, offset = 0 }) {
        stopTrack('music');
        const pl = { cancel: false };
        playlist = pl;
        let i = 0;
        let off = Math.max(0, offset);
        while (i < list.length && off >= list[i].duration) { off -= list[i].duration; i += 1; }

        const start = (idx, startAt) => {
            if (pl.cancel || idx >= list.length) return;
            const t = list[idx];
            const a = new Audio(t.file);
            a.volume = Math.max(0, Math.min(1, volume));
            tracks.music = a;
            let moved = false;
            const next = () => { if (moved || pl.cancel) return; moved = true; start(idx + 1, 0); };
            const missing = () => setTimeout(next, Math.max(0, t.duration - startAt) * 1000);
            a.onended = next;
            a.onerror = missing;
            if (startAt > 0) {
                a.addEventListener('loadedmetadata', () => { try { a.currentTime = startAt; } catch (_) { /* ignore */ } }, { once: true });
            }
            a.play().catch(missing);
        };
        start(i, off);
    }

    // ---------------- Seatbelt buckle prompt ----------------
    function renderBuckle(d) {
        const el = $('buckle');
        if (d.show === false) { hide('buckle'); return; }
        if (d.show) {
            el.classList.remove('done');
            el.classList.toggle('info', !!d.info);   // warning only, no key to press
            $('b-key').textContent = d.key || cfg.keys.ready;
            $('b-title').textContent = 'FASTEN YOUR SEATBELT';
            $('b-count').textContent = '';
            show('buckle');
        }
        if (d.done) {
            el.classList.add('done');
            $('b-title').textContent = 'SEATBELT FASTENED';
        }
        if (typeof d.count === 'number') {
            $('b-count').textContent = `${d.count} / ${d.total} passengers buckled${d.note ? ` · ${d.note}` : ''}`;
        }
    }

    function playTrack({ kind, file, volume = 1, loop = false, fallback = 0, report = false }) {
        stopTrack(kind);
        let done = false;
        const finish = () => { if (done) return; done = true; if (report) post('audioDone', { kind }); };
        const failed = () => {
            if (done) return;
            if (report) setTimeout(finish, (fallback || 1) * 1000);
            else done = true;
        };
        const a = new Audio(file);
        a.volume = Math.max(0, Math.min(1, volume));
        a.loop = loop;
        a.onended = finish;
        a.onerror = failed;
        tracks[kind] = a;
        a.play().catch(failed);
        // media that never starts (missing file, blocked codec) still completes via fallback
        setTimeout(() => { if (!done && a.currentTime === 0) { a.pause(); failed(); } }, 6000);
    }

    function fadeTrack(kind, duration) {
        const a = tracks[kind];
        if (!a) return;
        const start = a.volume;
        const steps = Math.max(1, Math.floor(duration / 100));
        let i = 0;
        const iv = setInterval(() => {
            i += 1;
            a.volume = Math.max(0, start * (1 - i / steps));
            if (i >= steps) { clearInterval(iv); stopTrack(kind); }
        }, 100);
    }

    // ---------------- Admin setup editor ----------------
    const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const coordText = (p) => p
        ? `${p.x.toFixed(1)}, ${p.y.toFixed(1)}, ${p.z.toFixed(1)}${p.w !== undefined ? ` &middot; ${Math.round(p.w)}&deg;` : ''}`
        : '<i>not set</i>';

    function renderSetup(s) {
        const panel = $('setup');
        if (!s.show) { hide('setup'); return; }
        show('setup');
        panel.classList.toggle('collapsed', !s.focused);
        $('s-key-panel').textContent = s.keys.panel;
        $('s-key-panel2').textContent = s.keys.panel;

        // farewell mode: test / live_return / live_kick
        const modeBox = $('s-mode');
        const back = s.returnTo === 'city' ? 'Legion Square' : 'the airport';
        const cur = (s.modes && s.modes[s.mode]) || { label: s.mode, desc: '' };
        modeBox.className = `s-mode ${s.mode}`;
        $('s-mode-title').textContent = cur.label;
        $('s-mode-desc').textContent = s.mode === 'live_kick' ? cur.desc : `${cur.desc} (returns to ${back})`;
        const short = { test: 'Test', live_return: 'Live - Return', live_kick: 'Live - Kick' };
        $('s-mode-btns').innerHTML = (s.modeOrder || []).map((m) =>
            `<button class="s-switch ${m === s.mode ? 'on' : ''}" data-action="mode" data-mode="${m}">${short[m] || m}</button>`).join('');

        const st = $('s-state');
        st.className = 's-state' + (s.dirty ? ' dirty' : s.saved ? ' saved' : '');
        st.textContent = s.dirty ? 'Unsaved changes' : s.saved ? 'Saved layout active' : 'Using config.lua';

        let html = '';
        let group = '';
        for (const f of s.fields) {
            if (f.group !== group) { group = f.group; html += `<div class="s-group">${esc(group.toUpperCase())}</div>`; }
            const v = s.draft[f.key];
            const active = s.active === f.key;
            let btns;
            let val;
            if (f.kind === 'list') {
                const n = (v || []).length;
                val = `${n} point${n === 1 ? '' : 's'}`;
                btns = active
                    ? `<button class="rec" data-action="stop">Stop</button>
                       <button class="${s.auto ? 'on' : ''}" data-action="auto">Auto ${s.auto ? 'ON' : 'off'}</button>`
                    : `<button data-action="record" data-field="${f.key}">Record</button>`;
                btns += `<button data-action="undo" data-field="${f.key}" ${n ? '' : 'disabled'}>Undo</button>
                         <button data-action="clear" data-field="${f.key}" ${n ? '' : 'disabled'}>Clear</button>
                         <button data-action="go" data-field="${f.key}" ${n ? '' : 'disabled'}>Go</button>`;
            } else {
                val = coordText(v);
                btns = `<button data-action="set" data-field="${f.key}">Set here</button>
                        <button data-action="go" data-field="${f.key}" ${v ? '' : 'disabled'}>Go</button>`;
            }
            html += `<div class="s-row ${active ? 'active' : ''}">
                <div class="s-top"><span class="s-label">${esc(f.label)}</span><div class="s-btns">${btns}</div></div>
                <div class="s-val">${val}</div>
                <div class="s-hint">${esc(f.hint || '')}${active ? ` &middot; <b>${esc(s.keys.point)}</b> adds a point${s.auto ? ` (auto every ${s.spacing} m)` : ''}` : ''}</div>
            </div>`;
        }
        $('s-body').innerHTML = html;

        const roll = s.stats.roll;
        $('s-stats').innerHTML =
            `<span>Taxi distance: <b>${s.stats.taxi || 0} m</b></span>` +
            `<span>Takeoff roll: <b class="${roll !== undefined && roll < 300 ? 'bad' : ''}">${roll !== undefined ? roll + ' m' : '-'}</b>${roll !== undefined && roll < 300 ? ' (needs 300+)' : ''}</span>`;
        $('s-route').textContent = s.route ? `Current route: ${s.route}` : '';
        $('s-busy').classList.toggle('hidden', !s.busy);
        $('s-save').disabled = !!s.busy || (roll !== undefined && roll < 300);
    }

    $('setup').addEventListener('click', (e) => {
        const b = e.target.closest('button[data-action]');
        if (!b || b.disabled) return;
        const action = b.dataset.action;
        if (action === 'factory' && !b.dataset.armed) {   // NUI has no confirm(): ask for a second click
            b.dataset.armed = '1';
            b.textContent = 'Click again to confirm';
            setTimeout(() => { delete b.dataset.armed; b.textContent = 'Factory reset'; }, 3000);
            return;
        }
        if (action === 'mode' && b.classList.contains('on')) return;
        post('setupAction', { action, field: b.dataset.field, mode: b.dataset.mode });
    });

    // ---------------- Fade / farewell ----------------
    function fade(to, duration) {
        const f = $('fade');
        f.style.transitionDuration = `${duration}ms`;
        requestAnimationFrame(() => { f.style.opacity = to; });
    }

    function resetAll() {
        ['desk', 'transport', 'ready', 'seatbelt', 'buckle', 'hud', 'landmark', 'farewell'].forEach(hide);
        clearInterval(etaTimer);
        clearInterval(readyTimer);
        Object.keys(tracks).forEach(stopTrack);
        const f = $('fade');
        f.style.transitionDuration = '0ms';
        f.style.opacity = 0;
    }

    // ---------------- Messages ----------------
    window.addEventListener('message', (e) => {
        const { action, data = {} } = e.data || {};
        switch (action) {
            case 'config':
                cfg = { ...cfg, ...data };
                $('r-key').textContent = cfg.keys.ready;
                $('h-key').textContent = cfg.keys.camera;
                $('h-flight').textContent = cfg.flight;
                $('h-dest').textContent = (cfg.destination || '').toUpperCase();
                if (data.farewell) {
                    $('fw-msg').textContent = data.farewell.message;
                    $('fw-sub').textContent = data.farewell.subMessage || '';
                    $('fw-msg').style.fontFamily = data.farewell.font;
                    $('fw-msg').style.color = data.farewell.color;
                }
                break;
            case 'desk': renderDesk(data); break;
            case 'ticketResult':
                if (data.ok && data.info && data.info.status === 'boarding') openTransport(data.info);
                else renderDesk(data.info, data.msg, data.ok);
                break;
            case 'hidePanels': hide('desk'); hide('transport'); clearInterval(etaTimer); break;
            case 'readyShow':
                $('r-flight').textContent = data.flight;
                $('r-dest').textContent = data.destination;
                show('ready');
                break;
            case 'readyHide': hide('ready'); clearInterval(readyTimer); break;
            case 'manifest': renderManifest(data); break;
            case 'seatbelt': data.on ? show('seatbelt') : hide('seatbelt'); break;
            case 'hud':
                if (!data.show) { hide('hud'); break; }
                if (data.camLabel) $('h-camlabel').textContent = data.camLabel;
                $('h-cam').classList.toggle('hidden', !data.toggle);
                $('h-cam-sep').classList.toggle('hidden', !data.toggle);
                show('hud');
                break;
            case 'hudTime': $('h-time').textContent = fmt(data.remaining); break;
            case 'landmark': {
                const el = $('landmark');
                $('landmark-label').textContent = data.label;
                el.classList.add('hidden');
                void el.offsetWidth;          // restart animation
                el.classList.remove('hidden');
                break;
            }
            case 'preload':
                (Array.isArray(data) ? data : []).forEach((t) => {
                    if (preloaded[t.file]) return;
                    const a = new Audio();
                    a.preload = 'auto';
                    a.src = t.file;
                    preloaded[t.file] = a;
                });
                break;
            case 'audio': playTrack(data); break;
            case 'playlist': playPlaylist(data); break;
            case 'buckle': renderBuckle(data); break;
            case 'audioFade': fadeTrack(data.kind, data.duration || 1000); break;
            case 'fade': fade(data.to, data.duration || 1000); break;
            case 'farewell': data.show ? show('farewell') : hide('farewell'); break;
            case 'toast': toast(data); break;
            case 'copy': {
                const c = $('clip');
                c.value = data.text || '';
                c.select();
                try { document.execCommand('copy'); } catch (_) { /* not critical */ }
                break;
            }
            case 'setup': renderSetup(data); break;
            case 'reset': resetAll(); break;
        }
    });

    window.addEventListener('keyup', (e) => {
        if (e.key !== 'Escape') return;
        if (!$('setup').classList.contains('hidden') && !$('setup').classList.contains('collapsed')) {
            post('setupAction', { action: 'close' });
        } else if (!$('desk').classList.contains('hidden') || !$('transport').classList.contains('hidden')) post('close');
        else if (!$('ready').classList.contains('hidden')) post('unfocus');
    });
})();
