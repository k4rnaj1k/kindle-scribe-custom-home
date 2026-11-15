// usage: node fb2png.js <input.raw.gz> <out.png> [width] [height]
const fs = require("fs");
const zlib = require("zlib");
const inp = process.argv[2];
const out = process.argv[3];
const W = parseInt(process.argv[4] || "1872", 10);
const H = parseInt(process.argv[5] || "2480", 10);
let raw;
if (inp.endsWith(".gz")) raw = zlib.gunzipSync(fs.readFileSync(inp));
else raw = fs.readFileSync(inp);
if (raw.length < W * H) throw new Error(`raw too small: ${raw.length} < ${W*H}`);

// build raw PNG scanlines: filter byte 0 + row
const stride = W + 1;
const img = Buffer.alloc(stride * H);
for (let y = 0; y < H; y++) {
  img[y * stride] = 0;
  raw.copy(img, y * stride + 1, y * W, y * W + W);
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
  const t = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  const c = crc32(Buffer.concat([t, data]));
  crc.writeUInt32BE(c >>> 0, 0);
  return Buffer.concat([len, t, data, crc]);
}
function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
  }
  return ~c;
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(W, 0); ihdr.writeUInt32BE(H, 4);
ihdr[8] = 8; ihdr[9] = 0; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
const png = Buffer.concat([
  Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(img, {level: 9})),
  chunk("IEND", Buffer.alloc(0)),
]);
fs.writeFileSync(out, png);
console.log("wrote", out, png.length, "bytes", W + "x" + H);
