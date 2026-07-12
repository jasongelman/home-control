#!/usr/bin/env node
/**
 * Interactive TC2 auth test script.
 * Usage: node server/scripts/test-tc2-auth.mjs <username> <password>
 *
 * Tests each step of the auth flow with verbose output so we can see
 * exactly where it fails.
 */

import { createPublicKey, publicEncrypt, constants } from 'crypto';
import readline from 'readline';

const APP_CONFIG_URL = 'https://totalconnect2.com/application.config.json';
const TOKEN_URL      = 'https://rs.alarmnet.com/TC2API.Auth/token';
const API_BASE       = 'https://rs.alarmnet.com/TC2API.TCResource/';

const username = process.argv[2];
const password = process.argv[3];

if (!username || !password) {
  console.error('Usage: node test-tc2-auth.mjs <username> <password>');
  process.exit(1);
}

async function main() {
  // Step 1: Fetch app config
  console.log('\n=== Step 1: Fetch app config ===');
  const configRes = await fetch(APP_CONFIG_URL);
  console.log('Config status:', configRes.status);
  const config = await configRes.json();

  const appConfig = config.AppConfig?.[0];
  const rsaKey = appConfig?.tc2APIKey;
  const clientId = appConfig?.tc2ClientId;
  const brandEntry = config.brandInfo?.find(b => b.BrandName === 'totalconnect');
  const appId = String(brandEntry?.AppID ?? '');

  // Match Python: RevisionNumber + "." + last component of version
  const revNum = config.RevisionNumber ?? '3.53.1';
  const verStr = config.version ?? '0.0.0';
  const lastPart = verStr.split('.').pop() ?? '0';
  const appVersion = `${revNum}.${lastPart}`;

  console.log('clientId:', clientId);
  console.log('appId:', appId);
  console.log('appVersion:', appVersion);
  console.log('RSA key length:', rsaKey?.length);

  // Step 2: RSA encrypt credentials
  console.log('\n=== Step 2: RSA encrypt credentials ===');
  const pem = `-----BEGIN PUBLIC KEY-----\n${rsaKey.match(/.{1,64}/g).join('\n')}\n-----END PUBLIC KEY-----`;

  const encrypt = (plaintext) => {
    const encrypted = publicEncrypt(
      { key: pem, padding: constants.RSA_PKCS1_PADDING },
      Buffer.from(plaintext, 'utf8'),
    );
    return encrypted.toString('base64');
  };

  const encUsername = encrypt(username);
  const encPassword = encrypt(password);
  console.log('Encrypted username length:', encUsername.length);
  console.log('Encrypted password length:', encPassword.length);

  // Step 3: Token request — test BOTH approaches
  console.log('\n=== Step 3a: Token request (client_id in body — current approach) ===');
  {
    const body = new URLSearchParams({
      grant_type: 'password',
      client_id: clientId,
      username: encUsername,
      password: encPassword,
    }).toString();

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    console.log('Status:', res.status);
    const text = await res.text();
    console.log('Response:', text.substring(0, 200));

    if (res.status === 200) {
      const token = JSON.parse(text).access_token;
      console.log('\n--- Testing session details with this token ---');
      await testSessionDetails(token, appId, appVersion);
    }
  }

  console.log('\n=== Step 3b: Token request (client_id as Basic Auth — Python approach) ===');
  {
    const basicCreds = Buffer.from(`${clientId}:`).toString('base64');
    const body = new URLSearchParams({
      grant_type: 'password',
      username: encUsername,
      password: encPassword,
    }).toString();

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': `Basic ${basicCreds}`,
      },
      body,
    });
    console.log('Status:', res.status);
    const text = await res.text();
    console.log('Response:', text.substring(0, 200));

    if (res.status === 200) {
      const token = JSON.parse(text).access_token;
      console.log('\n--- Testing session details with this token ---');
      await testSessionDetails(token, appId, appVersion);
    }
  }

  console.log('\n=== Step 3c: Token request (client_id in body + Basic Auth) ===');
  {
    const basicCreds = Buffer.from(`${clientId}:`).toString('base64');
    const body = new URLSearchParams({
      grant_type: 'password',
      client_id: clientId,
      username: encUsername,
      password: encPassword,
    }).toString();

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        'Authorization': `Basic ${basicCreds}`,
      },
      body,
    });
    console.log('Status:', res.status);
    const text = await res.text();
    console.log('Response:', text.substring(0, 200));

    if (res.status === 200) {
      const token = JSON.parse(text).access_token;
      console.log('\n--- Testing session details with this token ---');
      await testSessionDetails(token, appId, appVersion);
    }
  }

  // Print full token response and test with locale param (matching Python client)
  console.log('\n=== Step 3d: Token with locale param (matching latest Python client) ===');
  {
    const body = new URLSearchParams({
      grant_type: 'password',
      client_id: clientId,
      username: encUsername,
      password: encPassword,
      locale: 'en-US',
    }).toString();

    const res = await fetch(TOKEN_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body,
    });
    const text = await res.text();
    console.log('Status:', res.status);
    const json = JSON.parse(text);
    console.log('Response keys:', Object.keys(json));
    console.log('Has refresh_token:', !!json.refresh_token);
    console.log('expires_in:', json.expires_in);

    const token = json.access_token;
    if (token) {
      const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString());
      console.log('\nDecoded token payload:', JSON.stringify(payload, null, 2));

      // Extract session ID from "ids" field (Python client approach)
      const ids = payload.ids;
      if (ids) {
        const parts = ids.split(';');
        console.log('\nids parts:', parts);
        console.log('Session ID (part[0]):', JSON.stringify(parts[0]));
      }

      console.log('\nTesting session details with Bearer token...');
      await testSessionDetails(token, appId, appVersion);
    }
  }
}

async function testSessionDetails(token, appId, appVersion) {
  // Test with just Bearer (what we do)
  const url = `${API_BASE}api/v3/authentication/sessiondetails?appId=${encodeURIComponent(appId)}&appVersion=${encodeURIComponent(appVersion)}`;
  console.log('URL:', url);

  console.log('\n--- Bearer only ---');
  const res1 = await fetch(url, {
    headers: { 'Authorization': `Bearer ${token}` },
  });
  console.log('Status:', res1.status);
  console.log('Response:', (await res1.text()).substring(0, 300));

  // Test with Bearer + Content-Type (sometimes needed)
  console.log('\n--- Bearer + Accept: application/json ---');
  const res2 = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'Accept': 'application/json',
    },
  });
  console.log('Status:', res2.status);
  console.log('Response:', (await res2.text()).substring(0, 300));

  // Test with Bearer + User-Agent matching requests library
  console.log('\n--- Bearer + python-requests User-Agent ---');
  const res3 = await fetch(url, {
    headers: {
      'Authorization': `Bearer ${token}`,
      'User-Agent': 'python-requests/2.31.0',
    },
  });
  console.log('Status:', res3.status);
  console.log('Response:', (await res3.text()).substring(0, 300));

  // Test with raw token (not "Bearer X" but just the token)
  console.log('\n--- Raw token as Authorization (no Bearer prefix) ---');
  const res4 = await fetch(url, {
    headers: {
      'Authorization': token,
    },
  });
  console.log('Status:', res4.status);
  console.log('Response:', (await res4.text()).substring(0, 300));
}

main().catch(console.error);
