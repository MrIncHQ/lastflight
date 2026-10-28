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

    // ---------------- Farewell highway drive ----------------
    let tour = { size: 1, max: 12, per: 3, cars: 8 };

    function renderTourSize() {
        $('t-size').textContent = tour.size;
        const n = Math.min(Math.ceil(tour.size / tour.per), tour.cars);
        $('t-cars').textContent = `${n} car${n === 1 ? '' : 's'} (${tour.per} passengers each)`;
        $('t-minus').disabled = tour.size <= 1;
        $('t-plus').disabled = tour.size >= tour.max;
    }

    function openTour(d) {
        tour = { size: 1, max: d.maxGroup || 12, per: d.seatsPerCar || 3, cars: Math.max(1, d.carsFree || d.maxCars || 8) };
        tour.max = Math.min(tour.max, tour.per * tour.cars);
        $('t-min').textContent = d.minutes || 15;
        const note = $('t-note');
        const start = $('t-start');
        let msg = '';
        start.disabled = false;
        if (d.waiting) {
            // a group is already lined up at the curb: join it
            msg = d.joinable
                ? `Farewell cars are waiting at the curb with ${d.seatsFree} free seat${d.seatsFree === 1 ? '' : 's'}. Join them!`
                : 'The farewell cars at the curb are full. The next one can go once they have been on the road for a bit.';
            start.textContent = 'Join the drive';
            start.disabled = !d.joinable;
        } else if (!d.ok) {
            msg = d.reason === 'recent'
                ? `The last farewell car just left. The next one can go in ${d.wait}s.`
                : 'Every farewell car is out on the highway right now. Try again soon.';
            start.textContent = 'Start the drive';
            start.disabled = true;
        } else {
            start.textContent = 'Start the drive';
        }
        $('t-pick').classList.toggle('hidden', !!d.waiting);
        note.textContent = msg;
        note.classList.toggle('hidden', !msg);
        renderTourSize();
        show('tour');
    }

    $('t-minus').onclick = () => { tour.size = Math.max(1, tour.size - 1); renderTourSize(); };
    $('t-plus').onclick = () => { tour.size = Math.min(tour.max, tour.size + 1); renderTourSize(); };
    $('t-start').onclick = () => { hide('tour'); post('tourStart', { size: tour.size }); };
    $('t-cancel').onclick = () => post('close');

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
    let musicUser = 1;            // this player's own music volume (scroll wheel), 0..1
    let volTimer = null;

    // Title / artist read from the MP3's own ID3 tag, so swapped-in songs show
    // their real artist. Only the tag at the start of the file is downloaded.
    const tagCache = {};
    function readTags(file) {
        if (!file) return Promise.resolve({});
        if (tagCache[file]) return tagCache[file];
        tagCache[file] = (async () => {
            try {
                const res = await fetch(file);
                if (!res.ok || !res.body) return {};
                const reader = res.body.getReader();
                let buf = new Uint8Array(0);
                let need = 10;
                while (buf.length < need) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    const n = new Uint8Array(buf.length + value.length);
                    n.set(buf); n.set(value, buf.length); buf = n;
                    if (need === 10 && buf.length >= 10) {
                        if (buf[0] !== 0x49 || buf[1] !== 0x44 || buf[2] !== 0x33) break;   // no "ID3"
                        need = Math.min(10 + ((buf[6] << 21) | (buf[7] << 14) | (buf[8] << 7) | buf[9]), 8 * 1024 * 1024);
                    }
                }
                reader.cancel().catch(() => {});
                return parseId3(buf);
            } catch (_) { return {}; }
        })();
        return tagCache[file];
    }

    function parseId3(b) {
        const out = {};
        if (b.length < 10 || b[0] !== 0x49 || b[1] !== 0x44 || b[2] !== 0x33) return out;
        const v = b[3];
        if (v < 3) return out;                                  // ID3v2.2 uses 3-letter frames: skip
        const end = Math.min(b.length, 10 + ((b[6] << 21) | (b[7] << 14) | (b[8] << 7) | b[9]));
        const text = (d) => {
            const enc = d[0];
            let body = d.subarray(1);
            let label = 'iso-8859-1';
            if (enc === 3) label = 'utf-8';
            else if (enc === 2) label = 'utf-16be';
            else if (enc === 1) {
                label = body[0] === 0xFE && body[1] === 0xFF ? 'utf-16be' : 'utf-16le';
                if ((body[0] === 0xFF && body[1] === 0xFE) || (body[0] === 0xFE && body[1] === 0xFF)) body = body.subarray(2);
            }
            try { return new TextDecoder(label).decode(body).replace(/\0+$/g, '').split('\0')[0].trim(); } catch (_) { return ''; }
        };
        let i = 10;
        while (i + 10 <= end) {
            const id = String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);
            if (!/^[A-Z0-9]{4}$/.test(id)) break;
            const size = v === 4
                ? (b[i + 4] << 21) | (b[i + 5] << 14) | (b[i + 6] << 7) | b[i + 7]
                : ((b[i + 4] << 24) >>> 0) + (b[i + 5] << 16) + (b[i + 6] << 8) + b[i + 7];
            if (size <= 0 || i + 10 + size > end) break;
            if (id === 'TPE1') out.artist = text(b.subarray(i + 10, i + 10 + size));
            if (id === 'TIT2') out.title = text(b.subarray(i + 10, i + 10 + size));
            if (out.artist && out.title) break;
            i += 10 + size;
        }
        return out;
    }

    // Song title above the volume bar, "Music by" under it. A song without a
    // title tag shows its file name instead (OneLastRide.mp3 -> One Last Ride).
    function showArtist() {
        const by = $('vol-by');
        const title = $('vol-title');
        const file = playlist && playlist.file;
        if (!file) { by.classList.add('hidden'); title.classList.add('hidden'); return; }
        readTags(file).then((t) => {
            if (!playlist || playlist.file !== file) return;
            const name = t.title || file.split('/').pop().replace(/\.[^.]+$/, '')
                .replace(/[_-]+/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2').trim();
            title.textContent = name;
            title.classList.toggle('hidden', !name);
            by.textContent = t.artist ? `Music by: ${t.artist}` : '';
            by.classList.toggle('hidden', !t.artist);
        });
    }

    function setMusicVolume({ level = 1, show: pop = false }) {
        musicUser = Math.max(0, Math.min(1, level));
        if (playlist && tracks.music && !playlist.fading) tracks.music.volume = playlist.base * musicUser;
        if (!pop) return;
        showArtist();
        $('vol-pct').textContent = `${Math.round(musicUser * 100)}%`;
        $('vol-fill').style.width = `${musicUser * 100}%`;
        show('vol');
        clearTimeout(volTimer);
        volTimer = setTimeout(() => hide('vol'), 1500);
    }

    function stopTrack(kind) {
        if (kind === 'music' && playlist) { playlist.cancel = true; playlist = null; }
        const a = tracks[kind];
        if (a) { a.pause(); a.src = ''; delete tracks[kind]; }
    }

    // Songs back to back from `offset` seconds into the playlist. A missing
    // file is "played" silently for its duration so later songs stay in sync.
    function playPlaylist({ tracks: list = [], volume = 0.5, offset = 0 }) {
        stopTrack('music');
        const pl = { cancel: false, base: Math.max(0, Math.min(1, volume)) };
        playlist = pl;
        let i = 0;
        let off = Math.max(0, offset);
        while (i < list.length && off >= list[i].duration) { off -= list[i].duration; i += 1; }

        const start = (idx, startAt) => {
            if (pl.cancel || idx >= list.length) return;
            const t = list[idx];
            pl.file = t.file;
            readTags(t.file);                 // so "Music by" is ready when the volume pops up
            const a = new Audio(t.file);
            a.volume = pl.base * musicUser;
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
            $('b-key').textContent = d.key || cfg.keys.seatbelt || 'B';
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
        if (kind === 'music' && playlist) playlist.fading = true;   // the volume wheel stops fighting the fade
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
                if (active) {
                    btns = `<button class="rec" data-action="stop">Stop</button>`;
                    if (!s.insert) btns += `<button class="${s.auto ? 'on' : ''}" data-action="auto">Auto ${s.auto ? 'ON' : 'off'}</button>`;
                } else {
                    btns = `<button data-action="record" data-field="${f.key}">Record</button>
                            <button data-action="insert" data-field="${f.key}" ${n ? '' : 'disabled'}>Insert</button>`;
                }
                btns += `<button data-action="nearest" data-field="${f.key}" ${n ? '' : 'disabled'} title="Removes the point closest to where you are standing">Delete nearest</button>
                         <button data-action="undo" data-field="${f.key}" ${n ? '' : 'disabled'}>Undo</button>
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
                <div class="s-hint">${esc(f.hint || '')}${active ? (s.insert
                    ? ` &middot; <b>${esc(s.keys.point)}</b> inserts a point where you are`
                    : ` &middot; <b>${esc(s.keys.point)}</b> adds a point${s.auto ? ` (auto every ${f.spacing || s.spacing} m)` : ''}`) : ''}</div>
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
        ['desk', 'transport', 'tour', 'ready', 'seatbelt', 'buckle', 'hud', 'vol', 'landmark', 'farewell'].forEach(hide);
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
            case 'hidePanels': hide('desk'); hide('transport'); hide('tour'); clearInterval(etaTimer); break;
            case 'tour': openTour(data); break;
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
                $('landmark-quote').textContent = data.quote || '';
                $('landmark-quote').classList.toggle('hidden', !data.quote);
                el.classList.toggle('long', !!data.quote);   // quotes stay up longer so they can be read
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
            case 'musicVolume': setMusicVolume(data); break;
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
        } else if (!$('desk').classList.contains('hidden') || !$('transport').classList.contains('hidden')
            || !$('tour').classList.contains('hidden')) post('close');
        else if (!$('ready').classList.contains('hidden')) post('unfocus');
    });
})();
