import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/sensor.dart';
import 'package:reaprime/src/plugins/plugin_ble_registry.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';

import '../helpers/plugin_ble_fixture.dart';
import 'plugin_test_helpers.dart';

const dir = String.fromEnvironment(
  'LEBREW_DIR',
  defaultValue: r'C:\Users\pc\Documents\workspace\lebrew-temp-plugin',
);
const svc = '0000180d-0000-1000-8000-00805f9b34fb';
const chr = '00002a37-0000-1000-8000-00805f9b34fb';

PluginManifest manifest() => PluginManifest.fromJson(
  jsonDecode(File('$dir/manifest.json').readAsStringSync()),
);

class LebrewTransport extends PluginBleFixtureTransport {
  LebrewTransport(super.physicalId, {this.hasService = true});
  final bool hasService;
  final subscribed = Completer<void>();
  final subscriptions = <String>[];

  @override
  Future<List<String>> discoverServices() async => hasService ? [svc] : [];

  @override
  Future<void> subscribe(
    String service,
    String characteristic,
    void Function(Uint8List) callback,
  ) async {
    subscriptions.add('$service/$characteristic');
    subscribers[characteristic] = callback;
    if (!subscribed.isCompleted) subscribed.complete();
  }

  void emit(List<int> bytes) => subscribers[chr]!(Uint8List.fromList(bytes));
}

List<int> frame(double celsius) {
  final f = ByteData(4)..setFloat32(0, celsius * 10, Endian.little);
  return [0xAA, ...f.buffer.asUint8List(), 0xBB, 0x85];
}

void main() {
  late PluginManager manager;
  final transports = <LebrewTransport>[];

  setUp(() async {
    transports.clear();
    manager = PluginManager(kvStore: FakeKeyValueStoreService());
    await manager.loadPlugin(
      id: manifest().id,
      manifest: manifest(),
      settings: {},
      jsCode: File('$dir/plugin.js').readAsStringSync(),
    );
  });
  tearDown(() => manager.dispose());

  Future<Sensor> candidate({String name = 'LEBREW TEMP', bool hasService = true}) async {
    final evidence = BleAdvertisementEvidence(name: name, nameComplete: true);
    return await manager.bleService.createCandidate(
          driver: manager.bleService.registry.decide(evidence).drivers.single,
          physicalId: '8C:BF:EA:5A:6B:F6',
          evidence: evidence,
          admit: () => true,
          createTransport: () {
            final t = LebrewTransport('8C:BF:EA:5A:6B:F6', hasService: hasService);
            transports.add(t);
            return t;
          },
        )
        as Sensor;
  }

  test('matches only the LEBREW TEMP advertisement name', () {
    final r = manager.bleService.registry;
    expect(r.decide(BleAdvertisementEvidence(name: 'LEBREW TEMP', nameComplete: true)).drivers, hasLength(1));
    expect(r.decide(BleAdvertisementEvidence(name: 'lebrew temp', nameComplete: true)).drivers, hasLength(1));
    expect(r.decide(BleAdvertisementEvidence(name: 'LEBREW TEMP 2', nameComplete: true)).drivers, isEmpty);
    expect(r.decide(BleAdvertisementEvidence(name: 'Polar H10', nameComplete: true, serviceUuids: ['180d'], servicesComplete: true)).drivers, isEmpty);
  });

  test('reads the spec frames as temperature, across split and noisy notifications', () async {
    final sensor = await candidate();
    expect(sensor.deviceId, 'plugin:lebrew-temp.reaplugin:lebrew:8c:bf:ea:5a:6b:f6');
    expect(sensor.info.vendor, 'LEBREW');
    expect(sensor.info.dataChannels.single.key, 'temperature');
    expect(sensor.info.dataChannels.single.type, 'number');
    final got = <double>[];
    final sub = sensor.data.listen((d) => got.add((d['temperature'] as num).toDouble()));
    final connect = sensor.onConnect();
    await transports.single.subscribed.future;
    expect(transports.single.subscriptions, ['$svc/$chr']);
    final t = transports.single;
    t.emit([0x00, 0x13, 0xAA]);
    t.emit([0x84, 0x8E, 0x46, 0x43]);
    t.emit([0xBB, 0x85]);
    await connect;
    t.emit([0xAA, 0xC8, 0x4D, 0x5D, 0x43, 0xBB, 0x85, ...frame(65.0)]);
    t.emit(frame(200));
    t.emit(frame(-60));
    t.emit([0xAA, 0, 0, 0xC0, 0x7F, 0xBB, 0x85]);
    t.emit(frame(58.3));
    await pumpEventQueue();
    expect(got, [19.9, 65.0, 58.3]);
    await sub.cancel();
    await sensor.disconnect();
  });

  test('fails to connect without the temperature service', () async {
    final sensor = await candidate(hasService: false);
    await expectLater(sensor.onConnect(), throwsA(anything));
    await sensor.disconnect();
  });
}
