import type { DoorState, MyQDoor } from './types.js';

// Publicly reverse-engineered App ID used by the community.
// If Chamberlain rotates this, update here.
const APP_ID = 'JVM/G9Nwih5BwKgNCjLxiFUQxQijAebyyg8QUHr7JOrP+LYa64pT';
const BASE_URL = 'https://api.myqdevice.com/api/v5.2';

function myqHeaders(token?: string): Record<string, string> {
  const h: Record<string, string> = {
    'MyQApplicationId': APP_ID,
    'Content-Type': 'application/json',
  };
  if (token) h['SecurityToken'] = token;
  return h;
}

export interface MyQSession {
  token: string;
  accountId: string;
}

export async function login(email: string, password: string): Promise<MyQSession> {
  const res = await fetch(`${BASE_URL}/Login`, {
    method: 'POST',
    headers: myqHeaders(),
    body: JSON.stringify({ Username: email, Password: password, BrandId: '2' }),
  });

  if (!res.ok) {
    const text = await res.text().catch(() => '');
    throw new Error(`MyQ login failed: ${res.status} ${res.statusText}${text ? ` — ${text}` : ''}`);
  }

  const data = await res.json() as { SecurityToken?: string };
  if (!data.SecurityToken) throw new Error('MyQ login: no SecurityToken in response');

  const token = data.SecurityToken;

  const accountRes = await fetch(`${BASE_URL}/My`, { headers: myqHeaders(token) });
  if (!accountRes.ok) {
    throw new Error(`MyQ account fetch failed: ${accountRes.status}`);
  }

  const accountData = await accountRes.json() as { Account?: { Id?: string } };
  const accountId = accountData.Account?.Id;
  if (!accountId) throw new Error('MyQ: no account ID in response');

  return { token, accountId };
}

export async function getDoors(session: MyQSession): Promise<MyQDoor[]> {
  const res = await fetch(`${BASE_URL}/accounts/${session.accountId}/devices`, {
    headers: myqHeaders(session.token),
  });

  if (!res.ok) throw new Error(`MyQ devices fetch failed: ${res.status}`);

  const data = await res.json() as {
    items?: Array<{
      serial_number: string;
      name: string;
      device_family: string;
      state: { door_state?: string };
    }>;
  };

  return (data.items ?? [])
    .filter((item) => item.device_family === 'garagedoor')
    .map((item) => ({
      serial: item.serial_number,
      name: item.name,
      state: (item.state?.door_state ?? 'unknown') as DoorState,
      lastUpdated: Date.now(),
    }));
}

export async function setDoorAction(
  session: MyQSession,
  serial: string,
  action: 'open' | 'close',
): Promise<void> {
  const res = await fetch(
    `${BASE_URL}/accounts/${session.accountId}/devices/${serial}/actions`,
    {
      method: 'PUT',
      headers: myqHeaders(session.token),
      body: JSON.stringify({ action_type: action }),
    },
  );

  if (!res.ok) {
    throw new Error(`MyQ action failed: ${res.status} ${res.statusText}`);
  }
}
