# Ecobee / Thermostat Integration Design

## Context

The network scan identified 7 Ecobee devices (thermostats + remote sensors) across the home: Main Floor, Primary Suite, Upstairs, Attic Playroom, and additional sensors. HVAC is a core smart home pillar with no current integration in this app.

**Constraint:** Ecobee's developer program is closed — new API key registrations are not possible. This rules out the cloud API approach.

**Decision:** iOS-only via HomeKit. No server or web thermostat support. Thermostats are typically adjusted from a phone, and HomeKit provides local, low-latency access with no API key required.

## Architecture

```
HomeKit (local, on-device)
    └── iOS: EcobeeManager reads HMHomeManager → thermostat accessories
              ├── Current temp, target temp, mode, humidity
              ├── Remote sensors (temp + occupancy)
              └── Controls: set target temp, set mode
```

**No server or web component.** This is an intentional iOS-only feature — thermostats don't need web parity because they're controlled from the phone and the Home app.

## Data Model

### EcobeeThermostat
| Field | Type | Source |
|-------|------|--------|
| identifier | String | HMAccessory.uniqueIdentifier |
| name | String | HMAccessory.name |
| currentTemp | Double (°F) | HMCharacteristicTypeCurrentTemperature (converted from °C) |
| desiredHeat | Double (°F) | HMCharacteristicTypeHeatingThreshold or TargetTemperature |
| desiredCool | Double (°F) | HMCharacteristicTypeCoolingThreshold or TargetTemperature |
| hvacMode | HvacMode | HMCharacteristicTypeTargetHeatingCooling (0=off, 1=heat, 2=cool, 3=auto) |
| humidity | Int? | HMCharacteristicTypeCurrentRelativeHumidity (if available) |
| room | String? | HMAccessory.room?.name |

### EcobeeRemoteSensor
| Field | Type | Source |
|-------|------|--------|
| id | String | HMAccessory.uniqueIdentifier |
| name | String | HMAccessory.name |
| temp | Double? (°F) | HMCharacteristicTypeCurrentTemperature |
| occupancy | Bool | HMCharacteristicTypeOccupancyDetected |
| room | String? | HMAccessory.room?.name |

### HvacMode
`heat` | `cool` | `auto` | `off`

## iOS Implementation

### EcobeeManager.swift
- `@Observable class EcobeeManager: NSObject, @unchecked Sendable`
- Conforms to `HMHomeManagerDelegate`
- On `homeManagerDidUpdateHomes`, refreshes thermostat data
- Polls HomeKit characteristics every 60 seconds
- **Topology cache:** `Documents/ecobee-topology.json` — persists thermostat/sensor names so the UI has data immediately on launch

### Discovery
- Thermostats: accessories with `HMServiceTypeThermostat`
- Remote sensors: accessories with `HMServiceTypeTemperatureSensor` but no thermostat service
- Occupancy: accessories with `HMServiceTypeOccupancySensor`

### Controls
- `setTargetTemp(thermostatId, temp)` — writes to `HMCharacteristicTypeTargetTemperature` (°F → °C conversion)
- `setHeatCoolTargets(thermostatId, heat, cool)` — writes to heating/cooling threshold characteristics (auto mode)
- `setMode(thermostatId, mode)` — writes to `HMCharacteristicTypeTargetHeatingCooling`
- All controls do optimistic local state updates + 2s delayed re-poll

### App Wiring
```swift
@State private var ecobee = EcobeeManager()
// .environment(ecobee)
// .onChange(of: scenePhase) { ecobee.resume() }
```

### UI
- **ContentView:** ThermostatPill in the dashboard's unified control section, ThermostatDetailView sheet with setpoint controls, mode picker, sensor list
- **RoomDetailView:** Climate section showing thermostats and sensors assigned to that room (via HomeKit room mapping)
- **SettingsView:** Read-only status section showing discovered thermostats

## Verification

```bash
cd ios/LutronHome && xcodebuild -project LutronHome.xcodeproj -scheme LutronHome -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17' build
```

### Functional Testing
1. Ensure thermostats are added to the Home app
2. Launch app → thermostats should appear in dashboard
3. Tap thermostat → adjust setpoint → verify temp changes
4. Change mode → verify mode updates
5. Check RoomDetailView → sensors should appear in matching rooms
