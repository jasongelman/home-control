import type { WebSocket } from 'ws';
import type { DeviceStore } from '../state/DeviceStore.js';
import type { StateSync } from '../state/StateSync.js';
import type { LEAPConnection } from '../lutron/LEAPConnection.js';
import type { ClientMessage } from '../lutron/types.js';
import type { MyQPoller } from '../myq/MyQPoller.js';
import type { TotalConnectPoller } from '../totalconnect/TotalConnectPoller.js';

export function handleWebSocket(
  ws: WebSocket,
  deviceStore: DeviceStore,
  stateSync: StateSync,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  alarmPoller: TotalConnectPoller,
): void {
  stateSync.addClient(ws);

  // Send full state + processor/garage/alarm status on connect
  ws.send(
    JSON.stringify({
      type: 'fullState',
      devices: deviceStore.getAllDevices(),
      processorConnected: connection.isConnected,
      doors: myqPoller.getDoors(),
      myqConnected: myqPoller.isConnected,
      panels: alarmPoller.getPanels(),
      alarmConnected: alarmPoller.isConnected,
    }),
  );

  ws.on('message', async (data) => {
    let msg: ClientMessage;
    try {
      msg = JSON.parse(data.toString());
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
      return;
    }

    switch (msg.type) {
      case 'ping':
        ws.send(JSON.stringify({ type: 'pong' }));
        break;

      case 'setLevel':
        if (!connection.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Not connected to processor' }));
          return;
        }
        try {
          await connection.setLevel(msg.deviceId, msg.level, msg.fadeTime);
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'pressButton':
        if (!connection.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Not connected' }));
          return;
        }
        try {
          await connection.pressVirtualButton(msg.component);
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'releaseButton':
        if (!connection.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Not connected' }));
          return;
        }
        try {
          await connection.releaseVirtualButton(msg.component);
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'queryDevice':
        if (!connection.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Not connected' }));
          return;
        }
        try {
          const level = await connection.queryZoneLevel(msg.deviceId);
          ws.send(
            JSON.stringify({ type: 'state', deviceId: msg.deviceId, level, timestamp: Date.now() }),
          );
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'garageAction':
        if (!myqPoller.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'MyQ not connected' }));
          return;
        }
        try {
          await myqPoller.triggerAction(msg.serial, msg.action);
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'alarmAction':
        if (!alarmPoller.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Alarm not connected' }));
          return;
        }
        try {
          await alarmPoller.triggerAction(msg.locationId, msg.action);
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;
    }
  });
}
