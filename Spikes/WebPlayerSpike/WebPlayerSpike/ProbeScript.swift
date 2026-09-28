/// Observes the real YouTube Music web player; the only action it performs
/// is clicking the page's own Song/Video control when asked.
enum ProbeScript {
    static let source = #"""
    (() => {
      if (window.__probe) return;
      // --- Observation-only instrumentation (installed at document start). ---
      // Every wrapper calls the original with the same arguments and returns its result;
      // it only records which event, if any, was being dispatched when the call happened.
      const ms = () => Date.now();
      const early = (kind, data) => {
        try { window.webkit.messageHandlers.probe.postMessage({ kind, at: ms(), vis: document.visibilityState, ...data }); } catch (e) {}
      };
      const cause = () => (window.event && window.event.type) || null;
      ['visibilitychange', 'pagehide', 'pageshow', 'freeze', 'resume', 'blur', 'focus'].forEach(type => {
        const target = (type === 'visibilitychange' || type === 'freeze' || type === 'resume') ? document : window;
        target.addEventListener(type, () => early('lifecycle', { type }), { capture: true });
      });
      const observe = (proto, name, label) => {
        const original = proto[name];
        if (typeof original !== 'function') return;
        proto[name] = function (...args) {
          early('call', { fn: label, arg: typeof args[0] === 'string' ? args[0].slice(0, 40) : null, cause: cause() });
          return original.apply(this, args);
        };
      };
      observe(HTMLMediaElement.prototype, 'load', 'media.load');
      observe(HTMLMediaElement.prototype, 'pause', 'media.pause');
      observe(HTMLMediaElement.prototype, 'removeAttribute', 'media.removeAttribute');
      const srcDesc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
      if (srcDesc && srcDesc.set) {
        Object.defineProperty(HTMLMediaElement.prototype, 'src', { ...srcDesc, set(value) {
          early('call', { fn: 'media.src=', kind: String(value).split(':')[0] || 'empty', cause: cause() });
          return srcDesc.set.call(this, value);
        } });
      }
      if (window.ManagedMediaSource) {
        observe(ManagedMediaSource.prototype, 'removeSourceBuffer', 'mms.removeSourceBuffer');
        observe(ManagedMediaSource.prototype, 'endOfStream', 'mms.endOfStream');
        observe(ManagedMediaSource.prototype, 'addSourceBuffer', 'mms.addSourceBuffer');
        observe(SourceBuffer.prototype, 'abort', 'sb.abort');
        const add = EventTarget.prototype.addEventListener;
        // Passive listeners on every MMS the page creates.
        const Original = ManagedMediaSource;
        const seen = new WeakSet();
        const watch = src => {
          if (seen.has(src)) return; seen.add(src);
          ['startstreaming', 'endstreaming', 'sourceopen', 'sourceclose', 'sourceended'].forEach(type =>
            add.call(src, type, () => early('mms', { type, streaming: src.streaming })));
        };
        const createObjectURL = URL.createObjectURL;
        URL.createObjectURL = function (obj) { if (obj instanceof Original) watch(obj); return createObjectURL.call(URL, obj); };
      }
      let nextElementID = 1;
      const post = (kind, data) => {
        try { window.webkit.messageHandlers.probe.postMessage({ kind, ...data }); } catch (e) {}
      };
      const player = () => document.getElementById('movie_player');
      const video = () => document.querySelector('video');

      const snapshot = () => {
        const v = video();
        if (v && !v.__probeID) v.__probeID = nextElementID++;
        const p = player();
        let data = null, state = null, apiTime = null;
        try { data = p && p.getVideoData ? p.getVideoData() : null; } catch (e) {}
        try { state = p && p.getPlayerState ? p.getPlayerState() : null; } catch (e) {}
        try { apiTime = p && p.getCurrentTime ? p.getCurrentTime() : null; } catch (e) {}
        const toggles = [...document.querySelectorAll('*')]
          .map(e => e.tagName.toLowerCase())
          .filter((t, i, a) => /toggle|switcher/.test(t) && a.indexOf(t) === i);
        return {
          href: /google\./.test(location.host) ? location.host + location.pathname
                : location.pathname + location.search.replace(/list=[^&]+/, 'list=…'),
          signedIn: !!document.querySelector('ytmusic-settings-button img, #avatar-btn, ytmusic-settings-button'),
          videoCount: document.querySelectorAll('video').length,
          elementID: v ? v.__probeID : null,
          srcKind: v ? (v.currentSrc || '').split(':')[0] : null,
          time: v ? Math.round(v.currentTime * 10) / 10 : null,
          paused: v ? v.paused : null,
          readyState: v ? v.readyState : null,
          size: v ? `${v.videoWidth}x${v.videoHeight}` : null,
          duration: v && isFinite(v.duration) ? Math.round(v.duration) : null,
          apiVideoID: data ? data.video_id : null,
          apiTime: apiTime != null ? Math.round(apiTime * 10) / 10 : null,
          apiState: state,
          toggleTags: toggles,
          ua: navigator.userAgent,
          mmsAAC: typeof window.ManagedMediaSource !== 'undefined' && ManagedMediaSource.isTypeSupported('audio/mp4; codecs="mp4a.40.2"'),
          mmsOpus: typeof window.ManagedMediaSource !== 'undefined' && ManagedMediaSource.isTypeSupported('audio/webm; codecs="opus"'),
          mse: typeof window.MediaSource !== 'undefined',
          mms: typeof window.ManagedMediaSource !== 'undefined',
        };
      };

      window.__probe = {
        snapshot: () => post('snapshot', snapshot()),
        // Clicks the page's own Song/Video control (whichever label is not active).
        toggle: () => {
          const root = document.querySelector('ytmusic-av-toggle') ||
            [...document.querySelectorAll('*')].find(e => /av-toggle|audio-video/.test(e.tagName.toLowerCase()));
          if (!root) { post('toggle', { ok: false, reason: 'no toggle element' }); return; }
          const buttons = [...root.querySelectorAll('button, [role=tab], [role=button], tp-yt-paper-tab, yt-formatted-string')];
          const labels = buttons.map(b => (b.textContent || '').trim()).filter(Boolean);
          const isActive = b => b.getAttribute('aria-selected') === 'true' || b.getAttribute('aria-pressed') === 'true'
                                || /(^|\s)(selected|iron-selected|active)(\s|$)/.test(b.className);
          const target = buttons.find(b => !isActive(b) && (b.textContent || '').trim());
          post('toggle', { ok: !!target, tag: root.tagName.toLowerCase(), labels, clicked: target ? (target.textContent || '').trim() : null,
                           before: snapshot() });
          if (target) target.click();
        },
        play: () => { const v = video(); if (v) v.play().then(() => post('play', { ok: true })).catch(e => post('play', { ok: false, reason: String(e) })); else post('play', { ok: false, reason: 'no video' }); },
      };

      // Media events on every <video> the page creates, and the player's own state changes.
      const watched = new WeakSet();
      let stateHooked = false;
      const hook = () => {
        document.querySelectorAll('video').forEach(v => {
          if (watched.has(v)) return;
          watched.add(v);
          if (!v.__probeID) v.__probeID = nextElementID++;
          ['error', 'ended', 'playing', 'pause', 'waiting', 'stalled', 'emptied', 'loadedmetadata', 'seeked'].forEach(type =>
            v.addEventListener(type, () => post('media', {
              type, elementID: v.__probeID, time: Math.round(v.currentTime * 10) / 10,
              error: v.error ? `${v.error.code} ${v.error.message || ''}` : null,
              apiVideoID: (() => { try { return player().getVideoData().video_id; } catch (e) { return null; } })(),
            })));
        });
        const p = player();
        if (!stateHooked && p && p.addEventListener) {
          stateHooked = true;
          p.addEventListener('onStateChange', s => post('state', { state: s, time: (() => { try { return Math.round(p.getCurrentTime() * 10) / 10; } catch (e) { return null; } })() }));
          p.addEventListener('onError', e => post('playerError', { code: e }));
        }
      };

      let last = '';
      setInterval(() => {
        hook();
        const s = snapshot();
        const key = JSON.stringify([s.href, s.elementID, s.apiVideoID, s.srcKind, s.paused, s.size, s.toggleTags, Math.floor((s.time || 0) / 5)]);
        if (key !== last) { last = key; post('tick', s); }
      }, 1000);
      post('installed', { href: location.pathname });
    })();
    """#
}
