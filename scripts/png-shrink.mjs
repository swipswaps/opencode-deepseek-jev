#!/usr/bin/env node
// png-shrink.mjs — downscale a PNG to fit a byte budget (box filter).
// Uses the repo-pinned pngjs (no apt/pip). Overwrites the input file.
// Usage: node scripts/png-shrink.mjs <file.png> [scale=0.75] [budget=153600]
// Screenshots are opaque UI: output colorType 2 (RGB, no alpha) which the
// repo-pinned pngjs packs much smaller than its RGBA default.
import { readFileSync, writeFileSync, statSync } from "node:fs";
import { PNG } from "pngjs";

const file = process.argv[2];
const scale = Number(process.argv[3] || "0.75");
const budget = Number(process.argv[4] || "153600");
if (!file) { process.stderr.write("usage: node scripts/png-shrink.mjs <file.png> [scale] [budget]\n"); process.exit(2); }
const before = statSync(file).size;
const src = PNG.sync.read(readFileSync(file));
const w = Math.max(1, Math.floor(src.width * scale));
const h = Math.max(1, Math.floor(src.height * scale));
const out = new PNG({ width: w, height: h });
const sx = src.width / w;
const sy = src.height / h;
for (let y = 0; y < h; y++) {
  for (let x = 0; x < w; x++) {
    let r = 0, g = 0, b = 0, a = 0, n = 0;
    for (let yy = Math.floor(y * sy); yy < Math.min(src.height, Math.ceil((y + 1) * sy)); yy++) {
      for (let xx = Math.floor(x * sx); xx < Math.min(src.width, Math.ceil((x + 1) * sx)); xx++) {
        const i = (yy * src.width + xx) * 4;
        r += src.data[i]; g += src.data[i + 1]; b += src.data[i + 2]; a += src.data[i + 3]; n++;
      }
    }
    const o = (y * w + x) * 4;
    out.data[o] = r / n; out.data[o + 1] = g / n; out.data[o + 2] = b / n; out.data[o + 3] = a / n;
  }
}
writeFileSync(file, PNG.sync.write(out, { colorType: 2 }));
const after = statSync(file).size;
process.stdout.write("shrink: " + before + " -> " + after + " bytes (budget " + budget + ")\n");
process.exit(after <= budget ? 0 : 1);
