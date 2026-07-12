import type { WebSocket } from 'ws';
import type { DeviceStore } from '../state/DeviceStore.js';
import type { StateSync } from '../state/StateSync.js';
import type { LEAPConnection } from '../lutron/LEAPConnection.js';
import type { ClientMessage } from '../lutron/types.js';
import type { MyQPoller } from '../myq/MyQPoller.js';
import type { HomeConnectManager } from '../homeconnect/HomeConnectManager.js';
import type { SmartHQManager } from '../smarthq/SmartHQManager.js';
import type { MyUplinkManager } from '../myuplink/MyUplinkManager.js';
import type { TotalConnectPoller } from '../totalconnect/TotalConnectPoller.js';
import type { ChargePointPoller } from '../chargepoint/ChargePointPoller.js';
import type { SubZeroManager } from '../subzero/SubZeroManager.js';

export function handleWebSocket(
  ws: WebSocket,
  deviceStore: DeviceStore,
  stateSync: StateSync,
  connection: LEAPConnection,
  myqPoller: MyQPoller,
  alarmPoller: TotalConnectPoller,
  homeConnect?: HomeConnectManager,
  smartHQ?: SmartHQManager,
  myUplink?: MyUplinkManager,
  chargePointPoller?: ChargePointPoller,
  subZero?: SubZeroManager,
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
      dishwashers: homeConnect?.getDishwashers() ?? [],
      laundry: smartHQ?.getAppliances() ?? [],
      heatPumps: myUplink?.getHeatPumps() ?? [],
      homeConnectLinked: homeConnect?.isLinked ?? false,
      smartHQLinked: smartHQ?.isLinked ?? false,
      myUplinkLinked: myUplink?.isLinked ?? false,
      panels: alarmPoller.getPanels(),
      alarmConnected: alarmPoller.isConnected,
      chargers: chargePointPoller?.getChargers() ?? [],
      chargePointConnected: chargePointPoller?.isConnected ?? false,
      refrigerators: subZero?.getRefrigerators() ?? [],
      ovens: subZero?.getOvens() ?? [],
      subZeroLinked: subZero?.isLinked ?? false,
      keypads: connection.getKeypads(),
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

      case 'setLEDState':
        if (!connection.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'Not connected to processor' }));
          return;
        }
        try {
          await connection.setLEDState(msg.ledId, msg.state);
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

      case 'chargerAction':
        if (!chargePointPoller?.isConnected) {
          ws.send(JSON.stringify({ type: 'error', message: 'ChargePoint not connected' }));
          return;
        }
        try {
          if (msg.action === 'setAmperage') {
            await chargePointPoller.triggerSetAmperage(msg.chargerId, msg.value);
          }
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

      case 'subZeroAction':
        if (!subZero?.isLinked) {
          ws.send(JSON.stringify({ type: 'error', message: 'Sub-Zero not linked' }));
          return;
        }
        try {
          switch (msg.action) {
            case 'setFridgeTemp':
              await subZero.setFridgeTemp(msg.applianceId, msg.value as number);
              break;
            case 'setFreezerTemp':
              await subZero.setFreezerTemp(msg.applianceId, msg.value as number);
              break;
            case 'setCrisperTemp':
              await subZero.setCrisperTemp(msg.applianceId, msg.value as number);
              break;
            case 'setIceMaker':
              await subZero.setIceMaker(msg.applianceId, msg.value as boolean);
              break;
            case 'setMaxIce':
              await subZero.setMaxIce(msg.applianceId, msg.value as boolean);
              break;
            case 'setNightMode':
              await subZero.setNightMode(msg.applianceId, msg.value as boolean);
              break;
            case 'setHumidityControl':
              await subZero.setHumidityControl(msg.applianceId, msg.value as number);
              break;
            case 'toggleLight':
              await subZero.toggleLight(msg.applianceId, msg.value as boolean);
              break;
            case 'toggleOvenLight':
              await subZero.toggleOvenLight(msg.applianceId, msg.value as boolean);
              break;
            case 'setProperty':
              await subZero.setProperty(msg.applianceId, msg.property as string, msg.value);
              break;
            case 'refresh':
              await subZero.refreshSnapshot(msg.applianceId);
              break;
          }
        } catch (err) {
          ws.send(JSON.stringify({ type: 'error', message: String(err) }));
        }
        break;

    }
  });
}
