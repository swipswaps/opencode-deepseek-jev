#!/usr/bin/env node
import { mkdirSync, writeFileSync } from "node:fs";
import { PNG } from "pngjs";

const out = new URL("./pwa/", import.meta.url);
mkdirSync(out, { recursive: true });

const BG = [13, 17, 23];
const BAR = [
  [46, 160, 67],
  [88, 166, 255],
  [210, 168, 255],
];
const FG = [230, 237, 243];
const DANGER = [248, 81, 73];

function put(png, x, y, rgb, a = 255) {
  if (x < 0 || y < 0 || x >= png.width || y >= png.height) return;
  const i = (png.width * y + x) << 2;
  png.data[i] = rgb[0];
  png.data[i + 1] = rgb[1];
  png.data[i + 2] = rgb[2];
  png.data[i + 3] = a;
}

function rect(png, x0, y0, w, h, rgb) {
  for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) put(png, x, y, rgb);
}

function dot(png, cx, cy, r, rgb) {
  const rr = r * r;
  for (let y = Math.floor(cy - r); y <= Math.ceil(cy + r); y++) {
    for (let x = Math.floor(cx - r); x <= Math.ceil(cx + r); x++) {
      const dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= rr) put(png, x, y, rgb);
    }
  }
}

function line(png, x0, y0, x1, y1, width, rgb) {
  const dx = x1 - x0, dy = y1 - y0;
  const steps = Math.max(Math.abs(dx), Math.abs(dy));
  const r = width / 2;
  for (let i = 0; i <= steps; i++) {
    const t = steps ? i / steps : 0;
    dot(png, x0 + dx * t, y0 + dy * t, r, rgb);
  }
}

function make(size) {
  const png = new PNG({ width: size, height: size });
  rect(png, 0, 0, size, size, BG);
  const pad = Math.round(size * 0.1);
  rect(png, pad, pad, size - pad * 2, size - pad * 2, [22, 27, 34]);

  const baseY = Math.round(size * 0.78);
  for (let i = 0; i < 3; i++) {
    const w = Math.round(size * 0.11);
    const x = Math.round(size * (0.28 + i * 0.16)) - Math.round(w / 2);
    const top = Math.round(size * [0.58, 0.47, 0.36][i]);
    rect(png, x, top, w, baseY - top, BAR[i]);
  }

  const pts = [
    [0.24, 0.55],
    [0.4, 0.45],
    [0.56, 0.5],
    [0.72, 0.3],
  ].map(([x, y]) => [Math.round(size * x), Math.round(size * y)]);
  for (let i = 1; i < pts.length; i++) {
    line(png, pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], Math.max(2, Math.round(size * 0.018)), FG);
  }
  for (const [x, y] of pts) dot(png, x, y, Math.max(2, Math.round(size * 0.022)), FG);
  dot(png, pts[3][0], pts[3][1], Math.max(2, Math.round(size * 0.016)), DANGER);

  writeFileSync(new URL(`icon-${size}.png`, out), PNG.sync.write(png));
}

for (const s of [192, 512]) make(s);
console.log("pwa-icons: wrote icon-192.png and icon-512.png");
