import { deflateSync } from "node:zlib";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) crc = (crc >>> 1) ^ (0xedb88320 & -(crc & 1));
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, data) {
  const typeBytes = Buffer.from(type);
  const output = Buffer.alloc(12 + data.length);
  output.writeUInt32BE(data.length, 0);
  typeBytes.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(crc32(Buffer.concat([typeBytes, data])), 8 + data.length);
  return output;
}

function insideCapsule(x, y, left, top, right, bottom) {
  const radius = (right - left) / 2;
  const centerX = (left + right) / 2;
  const centerY = Math.max(top + radius, Math.min(bottom - radius, y));
  return (x - centerX) ** 2 + (y - centerY) ** 2 <= radius ** 2;
}

function nearLine(x, y, x1, y1, x2, y2, width) {
  const dx = x2 - x1;
  const dy = y2 - y1;
  const position = Math.max(0, Math.min(1, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)));
  return (x - (x1 + position * dx)) ** 2 + (y - (y1 + position * dy)) ** 2 <= (width / 2) ** 2;
}

function makePng(size) {
  const rows = Buffer.alloc((size * 4 + 1) * size);
  const scale = size / 512;
  const colors = { background: [16, 24, 39, 255], blue: [56, 189, 248, 255], white: [247, 248, 252, 255] };
  for (let y = 0; y < size; y += 1) {
    const row = y * (size * 4 + 1);
    rows[row] = 0;
    for (let x = 0; x < size; x += 1) {
      const px = x / scale;
      const py = y / scale;
      let color = colors.background;
      if (insideCapsule(px, py, 188, 92, 324, 336)) color = colors.blue;
      const bowl = py >= 250 && py <= 380 && Math.abs(Math.hypot((px - 256) / 114, (py - 260) / 114) - 1) < .075 && py >= 260;
      const stem = nearLine(px, py, 256, 372, 256, 436, 30);
      const base = nearLine(px, py, 194, 436, 318, 436, 30);
      if (bowl || stem || base) color = colors.white;
      const offset = row + 1 + x * 4;
      rows.set(color, offset);
    }
  }

  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(rows)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

await mkdir(resolve(root, "public"), { recursive: true });
for (const [name, size] of [["icon-192.png", 192], ["icon-512.png", 512], ["apple-touch-icon.png", 180]]) {
  await writeFile(resolve(root, "public", name), makePng(size));
  console.log(`Generated public/${name}`);
}
