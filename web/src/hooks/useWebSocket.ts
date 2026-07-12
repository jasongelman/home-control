import { useEffect, useRef, useCallback, useState } from 'react';
import type { ServerMessage, ClientMessage, DeviceState, ConnectionStatus, MyQDoor, DishwasherStatus, LaundryAppliance, HeatPumpStatus, AlarmPanel, ChargePointCharger, SubZeroRefrigerator, WolfOven, KeypadInfo } from '../types/index.js';

const RECONNECT_DELAY = 3000;
const PING_INTERVAL = 30000;

export function useWebSocket() {
  const wsRef = useRef<WebSocket | null>(null);
  const pingRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const reconnectRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const mountedRef = useRef(false);
  const [devices, setDevices] = useState<Map<number, DeviceState>>(new Map());
  const [connectionStatus, setConnectionStatus] = useState<ConnectionStatus>('connecting');
  const [processorConnected, setProcessorConnected] = useState(false);
  const [doors, setDoors] = useState<Map<string, MyQDoor>>(new Map());
  const [myqConnected, setMyqConnected] = useState(false);
  const [dishwashers, setDishwashers] = useState<DishwasherStatus[]>([]);
  const [laundry, setLaundry] = useState<LaundryAppliance[]>([]);
  const [heatPumps, setHeatPumps] = useState<HeatPumpStatus[]>([]);
  const [homeConnectLinked, setHomeConnectLinked] = useState(false);
  const [smartHQLinked, setSmartHQLinked] = useState(false);
  const [myUplinkLinked, setMyUplinkLinked] = useState(false);
  const [panels, setPanels] = useState<Map<string, AlarmPanel>>(new Map());
  const [alarmConnected, setAlarmConnected] = useState(false);
  const [chargers, setChargers] = useState<ChargePointCharger[]>([]);
  const [chargePointConnected, setChargePointConnected] = useState(false);
  const [refrigerators, setRefrigerators] = useState<SubZeroRefrigerator[]>([]);
  const [ovens, setOvens] = useState<WolfOven[]>([]);
  const [subZeroLinked, setSubZeroLinked] = useState(false);
  const [keypads, setKeypads] = useState<KeypadInfo[]>([]);

  const send = useCallback((msg: ClientMessage) => {
    if (wsRef.current?.readyState === WebSocket.OPEN) {
      wsRef.current.send(JSON.stringify(msg));
    }
  }, []);

  const triggerGarage = useCallback(
    (serial: string, action: 'open' | 'close') => {
      send({ type: 'garageAction', serial, action });
    },
    [send],
  );

  const triggerAlarm = useCallback(
    (locationId: string, action: 'armAway' | 'armHome' | 'armNight' | 'disarm') => {
      send({ type: 'alarmAction', locationId, action });
    },
    [send],
  );

  const setChargerAmperage = useCallback(
    (chargerId: string, amps: number) => {
      send({ type: 'chargerAction', chargerId, action: 'setAmperage', value: amps });
    },
    [send],
  );

  const subZeroCommand = useCallback(
    (applianceId: string, action: string, value: unknown) => {
      send({ type: 'subZeroAction', applianceId, action: action as 'setFridgeTemp', value });
    },
    [send],
  );

  const setLEDState = useCallback(
    (ledId: number, state: 'On' | 'Off') => {
      send({ type: 'setLEDState', ledId, state });
    },
    [send],
  );

  const setLevel = useCallback(
    (deviceId: number, level: number, fadeTime?: number) => {
      send({ type: 'setLevel', deviceId, level, fadeTime });
    },
    [send],
  );

  const pressButton = useCallback(
    (deviceId: number, component: number) => {
      send({ type: 'pressButton', deviceId, component });
    },
    [send],
  );

  const releaseButton = useCallback(
    (deviceId: number, component: number) => {
      send({ type: 'releaseButton', deviceId, component });
    },
    [send],
  );

  // Fetch processor status via REST (reliable, no StrictMode issues)
  useEffect(() => {
    const checkStatus = () => {
      fetch('/api/status')
        .then((r) => r.json())
        .then((data) => { if (mountedRef.current) setProcessorConnected(!!data.connected); })
        .catch(() => {});
    };
    checkStatus();
    const interval = setInterval(checkStatus, 5000);
    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    mountedRef.current = true;

    function connect() {
      if (!mountedRef.current) return;

      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const host = import.meta.env.DEV ? `${window.location.hostname}:3001` : window.location.host;
      const wsUrl = `${protocol}//${host}/ws`;

      const ws = new WebSocket(wsUrl);
      wsRef.current = ws;

      ws.onopen = () => {
        if (!mountedRef.current) { ws.close(); return; }
        setConnectionStatus('connected');
        pingRef.current = setInterval(() => {
          if (wsRef.current?.readyState === WebSocket.OPEN) {
            wsRef.current.send(JSON.stringify({ type: 'ping' }));
          }
        }, PING_INTERVAL);
      };

      ws.onmessage = (event) => {
        if (!mountedRef.current) return;
        const msg = JSON.parse(event.data) as ServerMessage;

        switch (msg.type) {
          case 'fullState':
            setDevices(new Map(msg.devices.map((d) => [d.integrationId, d])));
            setProcessorConnected(msg.processorConnected);
            setDoors(new Map(msg.doors.map((d) => [d.serial, d])));
            setMyqConnected(msg.myqConnected);
            setDishwashers(msg.dishwashers ?? []);
            setLaundry(msg.laundry ?? []);
            setHeatPumps(msg.heatPumps ?? []);
            setHomeConnectLinked(msg.homeConnectLinked ?? false);
            setSmartHQLinked(msg.smartHQLinked ?? false);
            setMyUplinkLinked(msg.myUplinkLinked ?? false);
            setPanels(new Map(msg.panels.map((p) => [p.locationId, p])));
            setAlarmConnected(msg.alarmConnected);
            setChargers(msg.chargers ?? []);
            setChargePointConnected(msg.chargePointConnected ?? false);
            setRefrigerators(msg.refrigerators ?? []);
            setOvens(msg.ovens ?? []);
            setSubZeroLinked(msg.subZeroLinked ?? false);
            setKeypads(msg.keypads ?? []);
            break;

          case 'state':
            setDevices((prev) => {
              const next = new Map(prev);
              const device = next.get(msg.deviceId);
              if (device) {
                next.set(msg.deviceId, { ...device, level: msg.level, lastUpdated: msg.timestamp });
              }
              return next;
            });
            break;

          case 'connected':
            setProcessorConnected(true);
            break;

          case 'disconnected':
            setProcessorConnected(false);
            break;

          case 'garageState':
            setDoors(new Map(msg.doors.map((d) => [d.serial, d])));
            setMyqConnected(msg.myqConnected);
            break;

          case 'applianceState':
            setDishwashers(msg.dishwashers);
            setLaundry(msg.laundry);
            setHeatPumps(msg.heatPumps);
            break;

          case 'alarmState':
            setPanels(new Map(msg.panels.map((p) => [p.locationId, p])));
            setAlarmConnected(msg.alarmConnected);
            break;

          case 'chargerState':
            setChargers(msg.chargers);
            setChargePointConnected(msg.chargePointConnected);
            break;

          case 'subZeroState':
            setRefrigerators(msg.refrigerators);
            setOvens(msg.ovens);
            setSubZeroLinked(msg.subZeroLinked);
            break;

          case 'keypadsState':
            setKeypads(msg.keypads ?? []);
            break;

          case 'ledState':
            setKeypads((prev) => prev.map((kp) =>
              kp.deviceId !== msg.keypadId ? kp : {
                ...kp,
                buttons: kp.buttons.map((b) => b.ledId === msg.ledId ? { ...b, ledState: msg.state } : b),
              },
            ));
            break;

        }
      };

      ws.onclose = () => {
        if (pingRef.current) { clearInterval(pingRef.current); pingRef.current = null; }
        if (!mountedRef.current) return;
        setConnectionStatus('disconnected');
        reconnectRef.current = setTimeout(connect, RECONNECT_DELAY);
      };

      ws.onerror = () => {
        ws.close();
      };
    }

    connect();

    return () => {
      mountedRef.current = false;
      if (reconnectRef.current) { clearTimeout(reconnectRef.current); reconnectRef.current = null; }
      if (pingRef.current) { clearInterval(pingRef.current); pingRef.current = null; }
      if (wsRef.current) { wsRef.current.close(); wsRef.current = null; }
    };
  }, []);

  return {
    devices,
    connectionStatus,
    processorConnected,
    setLevel,
    pressButton,
    releaseButton,
    doors,
    myqConnected,
    triggerGarage,
    dishwashers,
    laundry,
    heatPumps,
    homeConnectLinked,
    smartHQLinked,
    myUplinkLinked,
    panels,
    alarmConnected,
    triggerAlarm,
    chargers,
    chargePointConnected,
    setChargerAmperage,
    refrigerators,
    ovens,
    subZeroLinked,
    subZeroCommand,
    keypads,
    setLEDState,
  };
}
