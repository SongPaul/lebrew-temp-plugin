# LEBREW TEMP Thermometer for Decaid

A Decaid plugin that reads the LEBREW TEMP ("Brewmaster") BLE thermometer as a
sensor. It publishes one channel, `temperature` in °C.

Decaid's steam sequencer uses any connected sensor with a numeric
`temperature` channel. With this plugin, steaming records milk temperature,
and a workflow's `steamSettings.stopAtTemperature` stops the steam at that
temperature. Skins read the value from `GET /api/v1/sensors` and
`/ws/v1/sensors/:id/snapshot`.

## Protocol

- Matched by the advertised name `LEBREW TEMP`, compared without case. The
  service `0x180D` is the standard heart rate number, so it is not used to
  match.
- Subscribes to `0x2A37` on service `0x180D`.
- Frame: `AA`, float32 little endian of °C × 10, then `BB 85` (7 bytes).
  Notifications are buffered, so frames split across or packed into
  notifications are both read.
- Readings below −50 °C, above 150 °C, NaN and infinity are dropped.
- The connection is ready on the first valid reading. Ten seconds without one
  reports the device as disconnected.
- Only the last reading in a notification is published. The device sends
  about three per second.

Bean display (fonts and flavour JSON) and calibration are not implemented.

## Limits

- The thermometer accepts one connection. While the official app or another
  app is connected, it stops advertising and Decaid cannot find it.
- No real hardware has been tested with this plugin yet.

## Install

Install it from the Decaid plugin page with **Install plugin → GitHub
Release**, **ZIP file** or **Folder snapshot**. A GitHub release must be
tagged `v<version>` matching `manifest.json`, with one `.zip` asset holding
`manifest.json` and `plugin.js`.

## Test

`test/lebrew_temp_host_test.dart` runs the plugin on Decaid's own plugin
engine with a fake BLE transport. Copy it into a Decaid checkout at
`test/plugins/` and run:

```powershell
$env:Path = "C:\flutter\bin;<decaid>\build\windows\x64\runner\Debug;$env:Path"
flutter test test/plugins/lebrew_temp_host_test.dart --dart-define=LEBREW_DIR=<this folder>
```

On Windows, `quickjs_c_bridge.dll` from a Decaid Windows build must be on the
path.

---

# 한국어

LEBREW TEMP(Brewmaster) 블루투스 온도계를 Decaid 센서로 읽는 플러그인입니다.
`temperature`(°C) 채널 하나를 보냅니다.

- 스팀할 때 우유 온도가 기록되고, 워크플로의 `stopAtTemperature`에 닿으면
  스팀이 멈춥니다.
- 기기는 한 번에 한 앱에만 연결됩니다. 공식 앱이 연결돼 있으면 Decaid가 찾지
  못합니다.
- 원두 표시와 온도 보정은 아직 없습니다. 실기기 검증도 아직입니다.
