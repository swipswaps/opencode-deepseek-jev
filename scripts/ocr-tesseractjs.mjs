// ocr-tesseractjs.mjs — local OCR via tesseract.js (WASM), no apt/pip/API.
// Same engine as receipts-ocr's browser side (src/services/ocrService.ts).
//
// Usage: node scripts/ocr-tesseractjs.mjs <image> [lang]
// Install: npm install tesseract.js   (first run downloads WASM + lang data, cached)

import { createWorker } from "tesseract.js";
import { tmpdir } from "node:os";
import { join } from "node:path";

const img = process.argv[2];
const lang = process.argv[3] || "eng";
if (!img) {
  console.error("usage: node ocr-tesseractjs.mjs <image> [lang]");
  process.exit(2);
}

const worker = await createWorker(lang, 1, { cachePath: join(tmpdir(), "tesseract-cache") });
try {
  const { data } = await worker.recognize(img);
  process.stdout.write(data.text + "\n");
} finally {
  await worker.terminate();
}
