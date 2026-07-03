// Renders ../web/favicon.svg into the iOS app icon (1024×1024 opaque PNG).
//
// iOS app icons must be a full, opaque square — the OS applies its own rounded
// mask. The favicon is a transparent water-drop SVG, so we composite it centred
// on the AkvaLink brand background (matches capacitor.config.json backgroundColor).
// Run AFTER `npx cap add ios`; it's chained into `add:ios` and `cap:ios`.
// Idempotent + safe to re-run.
import sharp from 'sharp';
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const APP = resolve(here, '..');
const WEB = resolve(APP, '..', 'web');

const SIZE = 1024;            // Apple's single universal app-icon size
const INNER = 760;            // drop artwork size within the square (leaves padding)
const BG = '#033f63';         // brand background (capacitor.config.json)

const svg = resolve(WEB, 'favicon.svg');
const iconPng = resolve(
  APP, 'ios', 'App', 'App', 'Assets.xcassets', 'AppIcon.appiconset', 'AppIcon-512@2x.png'
);

if (!existsSync(iconPng)) {
  console.log('ios-icon: no AppIcon-512@2x.png yet — run `npx cap add ios` first (on macOS). Skipping.');
  process.exit(0);
}

const drop = await sharp(await readFile(svg), { density: 400 })
  .resize(INNER, INNER, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png()
  .toBuffer();

const icon = await sharp({
  create: { width: SIZE, height: SIZE, channels: 4, background: BG },
})
  .composite([{ input: drop, gravity: 'center' }])
  .flatten({ background: BG }) // Apple rejects app icons that carry an alpha channel
  .removeAlpha()
  .png()
  .toBuffer();

await writeFile(iconPng, icon);
console.log(`ios-icon: wrote ${SIZE}×${SIZE} app icon from web/favicon.svg`);
