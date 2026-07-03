// Adds the iOS Bluetooth usage strings to ios/App/App/Info.plist.
//
// Apple requires a usage-description string or the app crashes the moment it
// touches Bluetooth (and App Review rejects it). Capacitor doesn't inject these
// from config, so run this AFTER `npx cap add ios` (it's also chained into
// `npm run cap:ios`). Idempotent + safe to run on any OS; it just edits XML.
import { readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const plist = resolve(here, '..', 'ios', 'App', 'App', 'Info.plist');

if (!existsSync(plist)) {
  console.log('ios-permissions: no ios/App/App/Info.plist yet — run `npx cap add ios` first (on macOS). Skipping.');
  process.exit(0);
}

const keys = {
  NSBluetoothAlwaysUsageDescription:
    'AkvaLink connects to your nearby sensor over Bluetooth to show live temperature and update firmware.',
  NSBluetoothPeripheralUsageDescription:
    'AkvaLink connects to your nearby sensor over Bluetooth.',
};

let xml = await readFile(plist, 'utf8');
let added = 0;
for (const [key, desc] of Object.entries(keys)) {
  if (xml.includes(`<key>${key}</key>`)) continue;
  const entry = `\t<key>${key}</key>\n\t<string>${desc}</string>\n`;
  xml = xml.replace(/<\/dict>\s*<\/plist>\s*$/, `${entry}</dict>\n</plist>\n`);
  added += 1;
}

if (added > 0) {
  await writeFile(plist, xml, 'utf8');
  console.log(`ios-permissions: added ${added} Bluetooth usage string(s) to Info.plist`);
} else {
  console.log('ios-permissions: Bluetooth usage strings already present — nothing to do');
}
