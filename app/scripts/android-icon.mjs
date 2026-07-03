// Renders ../web/favicon.svg into the Android launcher icons.
//
// Mirrors scripts/ios-icon.mjs so both apps show the same brand mark. Android
// needs several densities plus adaptive icons:
//   - mipmap-<d>/ic_launcher.png        legacy square (opaque brand bg)
//   - mipmap-<d>/ic_launcher_round.png  legacy round  (brand bg, circular)
//   - mipmap-<d>/ic_launcher_foreground.png  adaptive foreground (transparent)
//   - values/ic_launcher_background.xml  adaptive background colour (brand)
// Run AFTER `npx cap add android`; it's chained into `add:android` and
// `cap:android`. Idempotent + safe to re-run.
import sharp from 'sharp';
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(here, '..');
const WEB = resolve(APP, '..', 'web');
const RES = resolve(APP, 'android', 'app', 'src', 'main', 'res');

const BG = '#033f63'; // brand background (capacitor.config.json)

// px sizes per density: [legacy launcher, adaptive foreground (108dp full-bleed)]
const DENSITIES = {
  mdpi: [48, 108],
  hdpi: [72, 162],
  xhdpi: [96, 216],
  xxhdpi: [144, 324],
  xxxhdpi: [192, 432],
};

const svgPath = resolve(WEB, 'favicon.svg');

if (!existsSync(RES)) {
  console.log('android-icon: no android/app/src/main/res yet — run `npx cap add android` first. Skipping.');
  process.exit(0);
}

const svg = await readFile(svgPath);

// Render the drop at a given pixel size on a transparent canvas.
const drop = (px) =>
  sharp(svg, { density: 400 })
    .resize(px, px, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
    .png()
    .toBuffer();

const circleMask = (size) =>
  Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}">` +
    `<circle cx="${size / 2}" cy="${size / 2}" r="${size / 2}" fill="#fff"/></svg>`
  );

for (const [density, [launcher, fg]] of Object.entries(DENSITIES)) {
  const dir = resolve(RES, `mipmap-${density}`);

  // Legacy square: drop (~72%) centred on an opaque brand square.
  const square = await sharp({ create: { width: launcher, height: launcher, channels: 4, background: BG } })
    .composite([{ input: await drop(Math.round(launcher * 0.72)), gravity: 'center' }])
    .png()
    .toBuffer();
  await writeFile(resolve(dir, 'ic_launcher.png'), square);

  // Legacy round: same square clipped to a circle (transparent corners).
  const round = await sharp(square)
    .composite([{ input: circleMask(launcher), blend: 'dest-in' }])
    .png()
    .toBuffer();
  await writeFile(resolve(dir, 'ic_launcher_round.png'), round);

  // Adaptive foreground: drop in the ~66% safe zone on a transparent canvas.
  const foreground = await sharp({ create: { width: fg, height: fg, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
    .composite([{ input: await drop(Math.round(fg * 0.6)), gravity: 'center' }])
    .png()
    .toBuffer();
  await writeFile(resolve(dir, 'ic_launcher_foreground.png'), foreground);
}

// Adaptive background colour → brand (default template ships white).
await writeFile(
  resolve(RES, 'values', 'ic_launcher_background.xml'),
  '<?xml version="1.0" encoding="utf-8"?>\n' +
  '<resources>\n' +
  `    <color name="ic_launcher_background">${BG}</color>\n` +
  '</resources>\n',
  'utf8'
);

console.log(`android-icon: wrote launcher icons (${Object.keys(DENSITIES).length} densities) from web/favicon.svg`);
