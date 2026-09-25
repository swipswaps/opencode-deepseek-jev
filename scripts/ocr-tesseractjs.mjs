// ocr-tesseractjs.mjs — local OCR via tesseract.js (WASM), no apt/pip/API.
// Same engine as receipts-ocr's browser side (src/services/ocrService.ts).
// Downscales oversized images (area-average) before OCR so very tall
// screenshots don't stall the detector.
//
// Usage:
//   node scripts/ocr-tesseractjs.mjs <image> [lang]   # OCR to stdout
//   node scripts/ocr-tesseractjs.mjs --self-test      # verify downscale only
//
// Install: npm install tesseract.js pngjs

import { createWorker } from "tesseract.js";
import { readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import pngjs from "pngjs";

const { PNG } = pngjs;
const MAX_SIDE = 2000;

function downscalePng(buf) {
  let png;
  try {
    png = PNG.sync.read(buf);
  } catch {
    return buf;
  }
  const { width, height } = png;
  const scale = Math.min(1, MAX_SIDE / Math.max(width, height));
  if (scale >= 1) return buf;
  const nw = Math.max(1, Math.round(width * scale));
  const nh = Math.max(1, Math.round(height * scale));
  const out = new PNG({ width: nw, height: nh });
  for (let y = 0; y < nh; y++) {
    const y0 = Math.floor(y / scale);
    const y1 = Math.min(height - 1, Math.floor((y + 1) / scale));
    for (let x = 0; x < nw; x++) {
      const x0 = Math.floor(x / scale);
      const x1 = Math.min(width - 1, Math.floor((x + 1) / scale));
      let r = 0, g = 0, b = 0, a = 0, n = 0;
      for (let sy = y0; sy <= y1; sy++) {
        for (let sx = x0; sx <= x1; sx++) {
          const i = (sy * width + sx) << 2;
          r += png.data[i]; g += png.data[i + 1]; b += png.data[i + 2]; a += png.data[i + 3]; n++;
        }
      }
      const o = (y * nw + x) << 2;
      out.data[o] = r / n; out.data[o + 1] = g / n; out.data[o + 2] = b / n; out.data[o + 3] = a / n;
    }
  }
  return PNG.sync.write(out);
}

function selfTest() {
  const big = new PNG({ width: 822, height: 6300 });
  const buf = PNG.sync.write(big);
  const out = downscalePng(buf);
  const r = PNG.sync.read(out);
  console.log("downscale 822x6300 -> " + r.width + "x" + r.height);
  process.exit(r.height <= MAX_SIDE && r.width <= MAX_SIDE ? 0 : 1);
}

if (process.argv[2] === "--self-test") {
  selfTest();
} else {
  const img = process.argv[2];
  const lang = process.argv[3] || "eng";
  if (!img) {
    console.error("usage: node ocr-tesseractjs.mjs <image> [lang] | --self-test");
    process.exit(2);
  }
  const raw = readFileSync(img);
  const buf = downscalePng(raw);
  const worker = await createWorker(lang, 1, { cachePath: join(tmpdir(), "tesseract-cache") });
  try {
    const { data } = await worker.recognize(buf);
    process.stdout.write(data.text + "\n");
  } finally {
    await worker.terminate();
  }
}
