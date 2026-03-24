import * as net from 'net';

// Mock Lutron HomeWorks processor for offline development
// Simulates LIP protocol on port 23 (or custom port via env)

const PORT = parseInt(process.env.MOCK_PORT || '2300', 10);
const USERNAME = 'lutron';
const PASSWORD = 'integration';

// Simulated device levels (integration ID -> level)
const devices = new Map<number, number>();
for (let i = 1; i <= 20; i++) {
  devices.set(i, Math.round(Math.random() * 100));
}

const server = net.createServer((socket) => {
  console.log('Client connected');
  let authenticated = false;
  let awaitingPassword = false;
  let buffer = '';

  socket.write('login: ');

  socket.on('data', (data) => {
    buffer += data.toString();
    const lines = buffer.split('\r\n');
    buffer = lines.pop() || '';

    for (const line of lines) {
      const trimmed = line.trim();
      if (!trimmed) continue;

      if (!authenticated) {
        if (!awaitingPassword) {
          if (trimmed === USERNAME) {
            awaitingPassword = true;
            socket.write('password: ');
          } else {
            socket.write('login: ');
          }
        } else {
          if (trimmed === PASSWORD) {
            authenticated = true;
            socket.write('\r\nGNET> ');
            console.log('Client authenticated');
          } else {
            awaitingPassword = false;
            socket.write('login: ');
          }
        }
        continue;
      }

      // Handle commands
      if (trimmed.startsWith('#OUTPUT,')) {
        // #OUTPUT,<id>,1,<level>[,<fade>]
        const parts = trimmed.substring(8).split(',');
        const id = parseInt(parts[0], 10);
        const level = parseFloat(parts[2]);
        devices.set(id, level);
        // Echo back as state change to all clients
        socket.write(`~OUTPUT,${id},1,${level.toFixed(2)}\r\n`);
        socket.write('GNET> ');
        console.log(`Set device ${id} to ${level}%`);
      } else if (trimmed.startsWith('?OUTPUT,')) {
        // ?OUTPUT,<id>,1
        const parts = trimmed.substring(8).split(',');
        const id = parseInt(parts[0], 10);
        const level = devices.get(id);
        if (level !== undefined) {
          socket.write(`~OUTPUT,${id},1,${level.toFixed(2)}\r\n`);
        }
        socket.write('GNET> ');
      } else if (trimmed.startsWith('#DEVICE,')) {
        // #DEVICE,<id>,<component>,<action>
        const parts = trimmed.substring(8).split(',');
        socket.write(`~DEVICE,${parts[0]},${parts[1]},${parts[2]}\r\n`);
        socket.write('GNET> ');
        console.log(`Device event: ${trimmed}`);
      } else if (trimmed.startsWith('#MONITORING,')) {
        socket.write('GNET> ');
        console.log('Monitoring enabled');
      } else {
        socket.write('GNET> ');
      }
    }
  });

  socket.on('close', () => console.log('Client disconnected'));
  socket.on('error', (err) => console.error('Socket error:', err.message));
});

server.listen(PORT, () => {
  console.log(`Mock Lutron processor running on port ${PORT}`);
  console.log(`Simulating ${devices.size} devices`);
  console.log(`Login: ${USERNAME} / ${PASSWORD}`);
});
