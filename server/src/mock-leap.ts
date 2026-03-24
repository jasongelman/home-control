/**
 * mock-leap.ts — LEAP protocol server for local development.
 *
 * Simulates a HomeWorks QS processor on port 2301 (plain TCP).
 * Responds to: /login, /area, /zone, /virtualbutton,
 *              /zone/status (subscribe), /zone/{id}/commandprocessor
 *
 * Run standalone:  npm run mock:leap --workspace=server
 */
import net from 'net';

const PORT = parseInt(process.env.MOCK_LEAP_PORT ?? '2301', 10);

// ── Static topology ──────────────────────────────────────────────────────────

const AREAS = [
  { href: '/area/1', Name: 'Living Room', IsLeaf: true },
  { href: '/area/2', Name: 'Kitchen', IsLeaf: true },
  { href: '/area/3', Name: 'Primary Bedroom', IsLeaf: true },
  { href: '/area/4', Name: 'Office', IsLeaf: true },
  { href: '/area/5', Name: 'Dining Room', IsLeaf: true },
  { href: '/area/6', Name: 'Entry', IsLeaf: true },
];

const ZONES = [
  // Living Room
  { href: '/zone/11', Name: 'Overhead', ControlType: 'Dimmed', AssociatedArea: { href: '/area/1' } },
  { href: '/zone/12', Name: 'Floor Lamps', ControlType: 'Dimmed', AssociatedArea: { href: '/area/1' } },
  { href: '/zone/13', Name: 'Shades', ControlType: 'Shade', AssociatedArea: { href: '/area/1' } },
  // Kitchen
  { href: '/zone/21', Name: 'Overhead', ControlType: 'Dimmed', AssociatedArea: { href: '/area/2' } },
  { href: '/zone/22', Name: 'Under Cabinet', ControlType: 'Switched', AssociatedArea: { href: '/area/2' } },
  // Primary Bedroom
  { href: '/zone/31', Name: 'Overhead', ControlType: 'Dimmed', AssociatedArea: { href: '/area/3' } },
  { href: '/zone/32', Name: 'Bedside Lamps', ControlType: 'Dimmed', AssociatedArea: { href: '/area/3' } },
  { href: '/zone/33', Name: 'Blackout Shades', ControlType: 'Shade', AssociatedArea: { href: '/area/3' } },
  // Office
  { href: '/zone/41', Name: 'Desk Light', ControlType: 'Dimmed', AssociatedArea: { href: '/area/4' } },
  { href: '/zone/42', Name: 'Overhead', ControlType: 'Dimmed', AssociatedArea: { href: '/area/4' } },
  // Dining Room
  { href: '/zone/51', Name: 'Chandelier', ControlType: 'Dimmed', AssociatedArea: { href: '/area/5' } },
  { href: '/zone/52', Name: 'Sconces', ControlType: 'Dimmed', AssociatedArea: { href: '/area/5' } },
  // Entry
  { href: '/zone/61', Name: 'Overhead', ControlType: 'Switched', AssociatedArea: { href: '/area/6' } },
];

const VIRTUAL_BUTTONS = [
  { href: '/virtualbutton/101', Name: 'All On', IsProgrammed: true, AssociatedArea: { href: '/area/1' } },
  { href: '/virtualbutton/102', Name: 'All Off', IsProgrammed: true, AssociatedArea: { href: '/area/1' } },
  { href: '/virtualbutton/103', Name: 'Movie Mode', IsProgrammed: true, AssociatedArea: { href: '/area/1' } },
  { href: '/virtualbutton/104', Name: 'Good Night', IsProgrammed: true, AssociatedArea: { href: '/area/6' } },
];

// Initial zone levels
const zoneLevels = new Map<number, number>();
for (const z of ZONES) {
  const id = hrefToId(z.href);
  zoneLevels.set(id, Math.round(Math.random() * 80 + 10));
}

// ── Server ────────────────────────────────────────────────────────────────────

const subscribers = new Set<net.Socket>();

const server = net.createServer((socket) => {
  const addr = `${socket.remoteAddress}:${socket.remotePort}`;
  console.log(`[LEAP mock] Client connected: ${addr}`);

  let buffer = '';

  socket.on('data', (chunk: Buffer) => {
    buffer += chunk.toString('utf8');
    const lines = buffer.split('\n');
    buffer = lines.pop() ?? '';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      try {
        handleMessage(socket, JSON.parse(trimmed));
      } catch {
        // ignore
      }
    }
  });

  socket.on('close', () => {
    subscribers.delete(socket);
    console.log(`[LEAP mock] Client disconnected: ${addr}`);
  });

  socket.on('error', () => {
    subscribers.delete(socket);
  });
});

function handleMessage(socket: net.Socket, msg: Record<string, unknown>): void {
  const type = msg.CommuniqueType as string;
  const header = msg.Header as { Url?: string; ClientTag?: string } | undefined;
  const url = header?.Url ?? '';
  const tag = header?.ClientTag;

  // ── Login ──────────────────────────────────────────────────────────────────
  if (type === 'CreateRequest' && url === '/login') {
    const body = msg.Body as { Login?: { LoginId?: string; Password?: string } } | undefined;
    const user = body?.Login?.LoginId ?? '';
    const pass = body?.Login?.Password ?? '';

    if (user === 'lutron' && pass === 'integration') {
      send(socket, {
        CommuniqueType: 'CreateResponse',
        Header: { ClientTag: tag, MessageBodyType: 'OneLoginResponse', StatusCode: '200 OK', Url: url },
        Body: { Login: { ContextType: 'Application', LoginId: user } },
      });
    } else {
      send(socket, {
        CommuniqueType: 'CreateResponse',
        Header: { ClientTag: tag, StatusCode: '401 Unauthorized', Url: url },
      });
    }
    return;
  }

  // ── Read areas ────────────────────────────────────────────────────────────
  if (type === 'ReadRequest' && url === '/area') {
    send(socket, {
      CommuniqueType: 'ReadResponse',
      Header: { ClientTag: tag, MessageBodyType: 'MultipleAreaDefinition', StatusCode: '200 OK', Url: url },
      Body: { Areas: AREAS },
    });
    return;
  }

  // ── Read zones ────────────────────────────────────────────────────────────
  if (type === 'ReadRequest' && url === '/zone') {
    send(socket, {
      CommuniqueType: 'ReadResponse',
      Header: { ClientTag: tag, MessageBodyType: 'MultipleZoneDefinition', StatusCode: '200 OK', Url: url },
      Body: { Zones: ZONES },
    });
    return;
  }

  // ── Read virtual buttons ──────────────────────────────────────────────────
  if (type === 'ReadRequest' && url === '/virtualbutton') {
    send(socket, {
      CommuniqueType: 'ReadResponse',
      Header: { ClientTag: tag, MessageBodyType: 'MultipleVirtualButtonDefinition', StatusCode: '200 OK', Url: url },
      Body: { VirtualButtons: VIRTUAL_BUTTONS },
    });
    return;
  }

  // ── Subscribe to zone status ───────────────────────────────────────────────
  if (type === 'SubscribeRequest' && url === '/zone/status') {
    subscribers.add(socket);
    const statuses = ZONES.map((z) => {
      const id = hrefToId(z.href);
      return { href: `${z.href}/status`, Zone: { href: z.href }, Level: zoneLevels.get(id) ?? 0 };
    });
    send(socket, {
      CommuniqueType: 'SubscribeResponse',
      Header: { ClientTag: tag, MessageBodyType: 'MultipleZoneStatus', StatusCode: '200 OK', Url: url },
      Body: { ZoneStatuses: statuses },
    });
    return;
  }

  // ── Read single zone status ────────────────────────────────────────────────
  const zoneStatusMatch = url.match(/^\/zone\/(\d+)\/status$/);
  if (type === 'ReadRequest' && zoneStatusMatch) {
    const id = parseInt(zoneStatusMatch[1], 10);
    send(socket, {
      CommuniqueType: 'ReadResponse',
      Header: { ClientTag: tag, MessageBodyType: 'OneZoneStatus', StatusCode: '200 OK', Url: url },
      Body: { ZoneStatus: { href: url, Zone: { href: `/zone/${id}` }, Level: zoneLevels.get(id) ?? 0 } },
    });
    return;
  }

  // ── Control zone (GoToLevel) ───────────────────────────────────────────────
  const zoneCtrlMatch = url.match(/^\/zone\/(\d+)\/commandprocessor$/);
  if (type === 'CreateRequest' && zoneCtrlMatch) {
    const id = parseInt(zoneCtrlMatch[1], 10);
    const body = msg.Body as { Command?: { CommandType?: string; Parameter?: Array<{ Type: string; Value: number }> } } | undefined;
    if (body?.Command?.CommandType === 'GoToLevel') {
      const level = body.Command.Parameter?.find((p) => p.Type === 'Level')?.Value ?? 0;
      zoneLevels.set(id, level);
      send(socket, {
        CommuniqueType: 'CreateResponse',
        Header: { ClientTag: tag, StatusCode: '200 OK', Url: url },
      });
      // Broadcast status update to all subscribers
      broadcastZoneStatus(id, level);
    }
    return;
  }

  // ── Virtual button command ─────────────────────────────────────────────────
  const btnMatch = url.match(/^\/virtualbutton\/(\d+)\/commandprocessor$/);
  if (type === 'CreateRequest' && btnMatch) {
    send(socket, {
      CommuniqueType: 'CreateResponse',
      Header: { ClientTag: tag, StatusCode: '200 OK', Url: url },
    });
    return;
  }

  // ── Fallback ───────────────────────────────────────────────────────────────
  send(socket, {
    CommuniqueType: type.replace('Request', 'Response'),
    Header: { ClientTag: tag, StatusCode: '404 Not Found', Url: url },
  });
}

function broadcastZoneStatus(zoneId: number, level: number): void {
  const msg = {
    CommuniqueType: 'ReadResponse',
    Header: { MessageBodyType: 'MultipleZoneStatus', StatusCode: '200 OK', Url: '/zone/status' },
    Body: {
      ZoneStatuses: [
        { href: `/zone/${zoneId}/status`, Zone: { href: `/zone/${zoneId}` }, Level: level },
      ],
    },
  };
  for (const sock of subscribers) {
    if (!sock.destroyed) send(sock, msg);
  }
}

function send(socket: net.Socket, msg: Record<string, unknown>): void {
  if (!socket.destroyed) {
    socket.write(JSON.stringify(msg) + '\r\n');
  }
}

function hrefToId(href: string): number {
  const parts = href.split('/');
  return parseInt(parts[parts.length - 1], 10) || 0;
}

server.listen(PORT, () => {
  console.log(`[LEAP mock] Listening on port ${PORT}`);
  console.log(`[LEAP mock] ${AREAS.length} areas, ${ZONES.length} zones, ${VIRTUAL_BUTTONS.length} virtual buttons`);
  console.log(`[LEAP mock] Credentials: lutron / integration`);
});
