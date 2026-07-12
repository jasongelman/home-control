#!/usr/bin/env npx tsx
// Test LED state writes and explore inactive level control.
// Usage: cd server && npx tsx scripts/probe-leap-devices.mts

import { LEAPClient } from '../src/lutron/LEAPClient.js';
import { loadCert, hasCert } from '../src/lutron/LEAPCertManager.js';
import { readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const CONFIG_PATH = join(__dirname, '..', 'data', 'config.json');
const config = JSON.parse(readFileSync(CONFIG_PATH, 'utf-8'));
const ip = config.processor?.ip;

if (!ip) { console.error('No processor IP'); process.exit(1); }

const cert = hasCert() ? loadCert() : null;
const client = new LEAPClient(ip, 8081, true, {
  cert: cert?.certPem, key: cert?.keyPem, ca: cert?.caCertPem,
});
await client.connect();
console.log('Connected!\n');

async function send(msg: any): Promise<any> {
  try {
    return await client.send(msg);
  } catch (e: any) {
    return { error: e.message };
  }
}

async function query(url: string): Promise<any> {
  return send({ CommuniqueType: 'ReadRequest', Header: { Url: url } });
}

// ═══ 1. Read all LED statuses for Living Room Alisse ═══
console.log('═══ Living Room Alisse LED States ═══');
const buttons = [
  { id: 566, led: 559, name: 'Lights On' },
  { id: 570, led: 560, name: 'Lights Dim' },
  { id: 574, led: 561, name: 'Lights Off' },
  { id: 578, led: 562, name: 'Shades' },
  { id: 582, led: 563, name: 'Drapes' },
  { id: 586, led: 564, name: 'Superdim' },
];
for (const b of buttons) {
  const resp = await query(`/led/${b.led}/status`);
  const state = resp?.Body?.LEDStatus?.State || 'unknown';
  console.log(`  LED ${b.led} (${b.name}): ${state}`);
}

// ═══ 2. Try setting LED state to On/Off ═══
console.log('\n═══ LED State Write Tests (LED 559 - Lights On) ═══');

// Try setting State to "On"
const write1 = await send({
  CommuniqueType: 'UpdateRequest',
  Header: { Url: '/led/559/status' },
  Body: {
    LEDStatus: {
      State: 'On',
    },
  },
});
console.log('Set State=On:', JSON.stringify(write1?.Header, null, 2));
console.log('  Body:', JSON.stringify(write1?.Body, null, 2));

// Read back
const read1 = await query('/led/559/status');
console.log('Read back:', read1?.Body?.LEDStatus?.State);

// Try setting State to "Off"
const write2 = await send({
  CommuniqueType: 'UpdateRequest',
  Header: { Url: '/led/559/status' },
  Body: {
    LEDStatus: {
      State: 'Off',
    },
  },
});
console.log('\nSet State=Off:', JSON.stringify(write2?.Header, null, 2));

// ═══ 3. Try setting inactive level (different approaches) ═══
console.log('\n═══ Inactive Level Tests ═══');

// Try updating the LED definition itself
const write3 = await send({
  CommuniqueType: 'UpdateRequest',
  Header: { Url: '/led/559' },
  Body: {
    LED: {
      InactiveLevel: 25,
    },
  },
});
console.log('Set LED InactiveLevel=25:', JSON.stringify(write3, null, 2));

// Try updating via device
const write4 = await send({
  CommuniqueType: 'UpdateRequest',
  Header: { Url: '/device/552' },
  Body: {
    Device: {
      InactiveLevel: 25,
    },
  },
});
console.log('\nSet Device InactiveLevel=25:', JSON.stringify(write4, null, 2));

// Try querying the device for any settings/properties
console.log('\n═══ Device Properties Exploration ═══');
for (const sub of ['property', 'settings', 'configuration', 'componentstatus']) {
  const resp = await query(`/device/552/${sub}`);
  const status = resp?.Header?.StatusCode || resp?.error;
  if (!status?.includes('400') && !status?.includes('not supported')) {
    console.log(`/device/552/${sub}:`, JSON.stringify(resp?.Body, null, 2));
  } else {
    console.log(`/device/552/${sub}: ${status}`);
  }
}

// ═══ 4. Try /buttongroup properties ═══
console.log('\n═══ Button Group Properties ═══');
const bgDetail = await query('/buttongroup/565');
console.log('/buttongroup/565:', JSON.stringify(bgDetail?.Body, null, 2));

// Try updating button group with inactive level
const write5 = await send({
  CommuniqueType: 'UpdateRequest',
  Header: { Url: '/buttongroup/565' },
  Body: {
    ButtonGroup: {
      InactiveLEDLevel: 25,
    },
  },
});
console.log('\nSet ButtonGroup InactiveLEDLevel=25:', JSON.stringify(write5, null, 2));

// ═══ 5. Explore Sunnata keypad LEDs (device 4261) for comparison ═══
console.log('\n═══ Sunnata Keypad LEDs ═══');
const sunnataButtons = await query('/device/4261/buttongroup');
const sunnBtns = sunnataButtons?.Body?.ButtonGroups?.[0]?.Buttons || [];
for (const btnRef of sunnBtns) {
  const btn = await query(btnRef.href);
  const b = btn?.Body?.Button;
  if (b) {
    const led = b.AssociatedLED?.href || 'none';
    console.log(`  ${b.Name} "${b.Engraving?.Text || '?'}" — LED: ${led}`);
    if (led !== 'none') {
      const ledStatus = await query(`${led}/status`);
      console.log(`    LED state: ${ledStatus?.Body?.LEDStatus?.State || '?'}`);
    }
  }
}

// ═══ 6. Full list of all Alisse keypads ═══
console.log('\n═══ All Alisse Keypads Summary ═══');
const allAreas = (await query('/area'))?.Body?.Areas || [];
for (const area of allAreas) {
  const areaId = area.href?.match(/\/area\/(\d+)/)?.[1];
  if (!areaId) continue;
  const csResp = await query(`/area/${areaId}/associatedcontrolstation`);
  const stations = csResp?.Body?.ControlStations || [];
  for (const cs of stations) {
    const ganged = cs.AssociatedGangedDevices || [];
    for (const g of ganged) {
      if (g.Device?.DeviceType === 'AlisseKeypad') {
        // Get buttons for this device
        const devId = g.Device.href;
        const bgResp = await query(`${devId}/buttongroup`);
        const groups = bgResp?.Body?.ButtonGroups || [];
        const btnCount = groups.reduce((acc: number, bg: any) =>
          acc + (bg.Buttons?.length || 0), 0);
        console.log(`  ${area.Name}: ${cs.Name} (${devId}) — ${btnCount} buttons`);
      }
    }
  }
}

console.log('\n═══ Done ═══');
client.disconnect();
process.exit(0);
