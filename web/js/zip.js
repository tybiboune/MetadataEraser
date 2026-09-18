// Minimal ZIP (store method, no compression) writer - just enough to bundle already-
// processed image bytes into a single downloadable .zip client-side, with no external
// library and no server round-trip. CRC32 is required by the ZIP spec even for stored
// (uncompressed) entries.
(function (global) {
  'use strict';

  const CRC_TABLE = (() => {
    const table = new Uint32Array(256);
    for (let n = 0; n < 256; n++) {
      let c = n;
      for (let k = 0; k < 8; k++) {
        c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[n] = c >>> 0;
    }
    return table;
  })();

  function crc32(bytes) {
    let crc = 0xFFFFFFFF;
    for (let i = 0; i < bytes.length; i++) {
      crc = CRC_TABLE[(crc ^ bytes[i]) & 0xFF] ^ (crc >>> 8);
    }
    return (crc ^ 0xFFFFFFFF) >>> 0;
  }

  function dosDateTime(date) {
    const dosTime = ((date.getHours() & 0x1F) << 11) | ((date.getMinutes() & 0x3F) << 5) | ((date.getSeconds() >> 1) & 0x1F);
    const dosDate = (((date.getFullYear() - 1980) & 0x7F) << 9) | (((date.getMonth() + 1) & 0xF) << 5) | (date.getDate() & 0x1F);
    return { dosTime, dosDate };
  }

  function writeUint32LE(view, offset, value) { view.setUint32(offset, value, true); }
  function writeUint16LE(view, offset, value) { view.setUint16(offset, value, true); }

  /**
   * @param {Array<{name: string, data: Uint8Array}>} entries
   * @returns {Blob}
   */
  function buildZip(entries) {
    const encoder = new TextEncoder();
    const { dosTime, dosDate } = dosDateTime(new Date());
    const localParts = [];
    const centralParts = [];
    let offset = 0;

    for (const entry of entries) {
      const nameBytes = encoder.encode(entry.name);
      const data = entry.data;
      const crc = crc32(data);

      const localHeader = new ArrayBuffer(30);
      const lv = new DataView(localHeader);
      writeUint32LE(lv, 0, 0x04034b50);
      writeUint16LE(lv, 4, 20);
      writeUint16LE(lv, 6, 0);
      writeUint16LE(lv, 8, 0); // store, no compression
      writeUint16LE(lv, 10, dosTime);
      writeUint16LE(lv, 12, dosDate);
      writeUint32LE(lv, 14, crc);
      writeUint32LE(lv, 18, data.length);
      writeUint32LE(lv, 22, data.length);
      writeUint16LE(lv, 26, nameBytes.length);
      writeUint16LE(lv, 28, 0);

      localParts.push(new Uint8Array(localHeader), nameBytes, data);

      const centralHeader = new ArrayBuffer(46);
      const cv = new DataView(centralHeader);
      writeUint32LE(cv, 0, 0x02014b50);
      writeUint16LE(cv, 4, 20);
      writeUint16LE(cv, 6, 20);
      writeUint16LE(cv, 8, 0);
      writeUint16LE(cv, 10, 0);
      writeUint16LE(cv, 12, dosTime);
      writeUint16LE(cv, 14, dosDate);
      writeUint32LE(cv, 16, crc);
      writeUint32LE(cv, 20, data.length);
      writeUint32LE(cv, 24, data.length);
      writeUint16LE(cv, 28, nameBytes.length);
      writeUint16LE(cv, 30, 0);
      writeUint16LE(cv, 32, 0);
      writeUint16LE(cv, 34, 0);
      writeUint16LE(cv, 36, 0);
      writeUint32LE(cv, 38, 0);
      writeUint32LE(cv, 42, offset);

      centralParts.push(new Uint8Array(centralHeader), nameBytes);

      offset += localHeader.byteLength + nameBytes.length + data.length;
    }

    const centralStart = offset;
    let centralSize = 0;
    for (const part of centralParts) centralSize += part.length;

    const eocd = new ArrayBuffer(22);
    const ev = new DataView(eocd);
    writeUint32LE(ev, 0, 0x06054b50);
    writeUint16LE(ev, 4, 0);
    writeUint16LE(ev, 6, 0);
    writeUint16LE(ev, 8, entries.length);
    writeUint16LE(ev, 10, entries.length);
    writeUint32LE(ev, 12, centralSize);
    writeUint32LE(ev, 16, centralStart);
    writeUint16LE(ev, 20, 0);

    const allParts = [...localParts, ...centralParts, new Uint8Array(eocd)];
    return new Blob(allParts, { type: 'application/zip' });
  }

  global.MiniZip = { buildZip };
})(window);
