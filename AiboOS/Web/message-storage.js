/* AiboOS local-first message vault — iOS 15-compatible IndexedDB + lossless LZW.
 * Message history stays in device storage. 2.5 GiB is an APP POLICY limit,
 * not an iOS guaranteed allocation. If persistence fails, never ACK delivery.
 * This prototype is not an end-to-end encrypted messenger.
 */
(function () {
  'use strict';
  const LIMIT = Math.floor(2.5 * 1024 * 1024 * 1024);
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  let db = null, state = null, used = 0, available = false;
  let writes = Promise.resolve();
  function keyFor(conv, message) {
    return conv + '/' + String(Number(message.ts) || 0).padStart(16, '0') +
      '/' + String(message.from || '') + '/' + String(message.id || '');
  }
  function sizeFor(row) {
    return 160 + encoder.encode(String(row.name || '')).length +
      encoder.encode(String(row.id || '')).length +
      encoder.encode(String(row.text || '')).length +
      (row.packed ? row.packed.byteLength : 0);
  }
  // Encode UTF-8 with 16-bit LZW dictionary codes. Works on old iOS WebKit.
  function pack(text) {
    const bytes = encoder.encode(text);
    if (bytes.length < 80) return null;
    const dict = new Map();
    let w = String.fromCharCode(bytes[0]), next = 256;
    const codes = [];
    for (let i = 1; i < bytes.length; i++) {
      const c = String.fromCharCode(bytes[i]), pair = w + c;
      if (dict.has(pair)) { w = pair; continue; }
      codes.push(w.length === 1 ? w.charCodeAt(0) : dict.get(w));
      if (next < 65535) dict.set(pair, next++);
      w = c;
    }
    codes.push(w.length === 1 ? w.charCodeAt(0) : dict.get(w));
    const packed = new Uint8Array(codes.length * 2);
    for (let i = 0; i < codes.length; i++) {
      packed[i * 2] = codes[i] & 255;
      packed[i * 2 + 1] = codes[i] >>> 8;
    }
    return packed.length + 24 < bytes.length ? packed : null;
  }
  function unpack(packed) {
    const bytes = new Uint8Array(packed);
    if (!bytes.length || bytes.length % 2) throw Error('Corrupt compressed message');
    const get = i => bytes[2 * i] | (bytes[2 * i + 1] << 8);
    const dict = new Map(), first = get(0);
    if (first > 255) throw Error('Corrupt compressed message');
    let w = String.fromCharCode(first), next = 256;
    const parts = [w];
    for (let i = 1; i < bytes.length / 2; i++) {
      const code = get(i);
      const entry = code < 256 ? String.fromCharCode(code) :
        dict.has(code) ? dict.get(code) : code === next ? w + w[0] : null;
      if (entry === null) throw Error('Corrupt compressed message');
      parts.push(entry);
      if (next < 65535) dict.set(next++, w + entry[0]);
      w = entry;
    }
    const binary = parts.join(''), result = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) result[i] = binary.charCodeAt(i);
    return decoder.decode(result);
  }
  function requestGet(key) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction('messages', 'readonly');
      const req = tx.objectStore('messages').get(key);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => reject(req.error || Error('Message read failed'));
    });
  }
  function writeRow(row) {
    return new Promise((resolve, reject) => {
      const tx = db.transaction('messages', 'readwrite');
      tx.objectStore('messages').put(row);
      tx.oncomplete = () => resolve(true);
      tx.onerror = () => reject(tx.error || Error('Message storage failed'));
      tx.onabort = () => reject(tx.error || Error('Message storage unavailable'));
    });
  }
  function enqueue(fn) {
    const task = writes.then(fn);
    writes = task.catch(() => {});
    return task;
  }
  async function compactUnread() {
    if (!available) return 0;
    let saved = 0, scanned = 0;
    await new Promise((resolve, reject) => {
      const tx = db.transaction('messages', 'readwrite');
      const idx = tx.objectStore('messages').index('unread');
      const cursor = idx.openCursor(IDBKeyRange.only(1));
      cursor.onsuccess = () => {
        const c = cursor.result;
        if (!c || scanned >= 1000) return;
        scanned++;
        const m = c.value;
        if (m.text && !m.packed) {
          const packed = pack(m.text);
          if (packed) {
            const previous = m.bytes || sizeFor(m);
            m.text = ''; m.packed = packed; m.codec = 'lzw16';
            m.bytes = sizeFor(m);
            saved += Math.max(0, previous - m.bytes);
            c.update(m);
          }
        }
        c.continue();
      };
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error || Error('Compression failed'));
      tx.onabort = () => reject(tx.error || Error('Compression cancelled'));
    });
    used = Math.max(0, used - saved);
    if (state) { state.messageBytes = used; saveState(); }
    return saved;
  }
  function saveState() {
    try { if (typeof window.save === 'function') window.save(); }
    catch (e) { console.warn('Could not update vault metadata', e); }
  }
  async function saveRow(conv, message) {
    if (!available) throw Error('Phone message storage is not available');
    const key = keyFor(conv, message), old = await requestGet(key);
    const row = {
      key, conv, ts: Number(message.ts) || Date.now(),
      id: String(message.id || ''), from: String(message.from || ''),
      to: String(message.to || ''), name: String(message.name || '').slice(0, 48),
      text: String(message.text || ''), codec: '', packed: null,
      unread: message.unread ? 1 : 0,
      delivery: String(message.delivery || ''), deliveryError: String(message.deliveryError || '')
    };
    if (old && old.packed && !row.text) {
      row.packed = old.packed; row.codec = old.codec;
    }
    row.bytes = sizeFor(row);
    const oldBytes = old ? (old.bytes || sizeFor(old)) : 0;
    if (used + row.bytes - oldBytes > LIMIT * 0.9) {
      await compactUnread();
    }
    if (used + row.bytes - oldBytes > LIMIT) {
      throw Error('AiboOS message storage is full (2.5 GB policy limit)');
    }
    // Durable IDB transaction, not an optimistic localStorage write.
    await writeRow(row);
    used = Math.max(0, used + row.bytes - oldBytes);
    state.messageBytes = used;
    saveState();
    return true;
  }
  async function initialize(S, idb) {
    state = S;
    db = await idb();
    if (!db || !db.objectStoreNames.contains('messages')) {
      console.warn('Phone message vault is unavailable; retaining legacy localStorage history');
      return false;
    }
    available = true;
    used = Math.max(0, Number(S.messageBytes) || 0);
    const original = S.localMsgs || {};
    // Do not remove the old localStorage copy until EVERY old message has
    // committed to IndexedDB. Repeated migration is safe: keys are stable.
    try {
      for (const conv of Object.keys(original)) {
        for (const message of original[conv] || []) {
          if (!message || !message.id) continue;
          await enqueue(() => saveRow(conv, message));
          rememberThread(conv, message);
        }
      }
    } catch (e) {
      console.warn('Phone message migration failed — leaving legacy backup intact', e);
      available = false;
      return false;
    }
    // Future saves store only small metadata in localStorage; bodies live in IDB.
    Object.defineProperty(S, 'localMsgs', {
      value: original, writable: true, configurable: true, enumerable: false
    });
    if (typeof window.saveNow === 'function') window.saveNow();
    return true;
  }
  function rememberThread(conv, m) {
    if (!state) return;
    state.messageThreads = state.messageThreads || {};
    const other = String(m.from) === String(state.aiboId) ? m.to : m.from;
    const last = state.messageThreads[other];
    if (!last || (last.ts || 0) <= (m.ts || 0))
      state.messageThreads[other] = {
        with: String(other), last: String(m.text || '').slice(0, 180), ts: m.ts
      };
  }
  function persist(conv, message) {
    return enqueue(() => saveRow(conv, message));
  }
  function has(conv, message) {
    if (!available) return Promise.resolve(false);
    return requestGet(keyFor(conv, message)).then(Boolean);
  }
  async function recent(conv, count = 250) {
    if (!available) return [];
    const rows = await new Promise((resolve, reject) => {
      const result = [];
      const tx = db.transaction('messages', 'readonly');
      const cur = tx.objectStore('messages').index('conv')
        .openCursor(IDBKeyRange.only(conv), 'prev');
      cur.onsuccess = () => {
        const cursor = cur.result;
        if (!cursor || result.length >= count) return;
        result.push(cursor.value);
        cursor.continue();
      };
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => reject(tx.error || Error('Could not read message history'));
    });
    return rows.reverse().map(row => {
      let text = row.text;
      if (row.packed && row.codec === 'lzw16') text = unpack(row.packed);
      return {
        id: row.id, conv: row.conv, from: row.from, to: row.to,
        ts: row.ts, text, name: row.name, unread: !!row.unread,
        delivery: row.delivery, deliveryError: row.deliveryError
      };
    });
  }
  function markRead(conv) {
    if (!available) return Promise.resolve(false);
    return enqueue(async () => {
      await new Promise((resolve, reject) => {
        const tx = db.transaction('messages', 'readwrite');
        const cursor = tx.objectStore('messages').index('conv')
          .openCursor(IDBKeyRange.only(conv));
        cursor.onsuccess = () => {
          const c = cursor.result;
          if (!c) return;
          const m = c.value;
          if (m.unread) { m.unread = 0; c.update(m); }
          c.continue();
        };
        tx.oncomplete = () => resolve();
        tx.onerror = () => reject(tx.error || Error('Could not mark messages read'));
      });
      return true;
    });
  }
  window.PhoneMsgStore = {
    limit: LIMIT, get ready() { return available; },
    get bytes() { return used; }, init: initialize, persist,
    has, recent, markRead, compactUnread: () => enqueue(compactUnread),
    rememberThread, pack, unpack
  };
})();
