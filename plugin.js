function createPlugin(host) {
  const service = "0000180d-0000-1000-8000-00805f9b34fb";
  const temperatureCharacteristic = "00002a37-0000-1000-8000-00805f9b34fb";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const silenceMs = 10000;
  const maxBuffered = 64;

  function bytesOf(data) {
    if (typeof data !== "string" || data.length % 4 !== 0) return [];
    const bytes = [];
    for (let i = 0; i < data.length; i += 4) {
      const a = alphabet.indexOf(data[i]);
      const b = alphabet.indexOf(data[i + 1]);
      const c = data[i + 2] === "=" ? 0 : alphabet.indexOf(data[i + 2]);
      const d = data[i + 3] === "=" ? 0 : alphabet.indexOf(data[i + 3]);
      if (a < 0 || b < 0 || c < 0 || d < 0) return [];
      bytes.push((a << 2) | (b >> 4));
      if (data[i + 2] !== "=") bytes.push(((b & 15) << 4) | (c >> 2));
      if (data[i + 3] !== "=") bytes.push(((c & 3) << 6) | d);
    }
    return bytes;
  }

  function float32le(b0, b1, b2, b3) {
    const bits = ((b3 << 24) | (b2 << 16) | (b1 << 8) | b0) >>> 0;
    const sign = bits >>> 31 ? -1 : 1;
    const exponent = (bits >>> 23) & 0xff;
    const fraction = bits & 0x7fffff;
    if (exponent === 0xff) return NaN;
    if (exponent === 0) return sign * fraction * Math.pow(2, -149);
    return sign * (1 + fraction / 0x800000) * Math.pow(2, exponent - 127);
  }

  function celsiusFrom(b0, b1, b2, b3) {
    const celsius = Math.round(float32le(b0, b1, b2, b3)) / 10;
    return Number.isFinite(celsius) && celsius >= -50 && celsius <= 150 ? celsius : null;
  }

  function takeFrames(buffer) {
    const readings = [];
    let i = 0;
    while (buffer.length - i >= 7) {
      if (buffer[i] === 0xaa && buffer[i + 5] === 0xbb && buffer[i + 6] === 0x85) {
        const celsius = celsiusFrom(buffer[i + 1], buffer[i + 2], buffer[i + 3], buffer[i + 4]);
        if (celsius !== null) readings.push(celsius);
        i += 7;
      } else {
        i += 1;
      }
    }
    buffer.splice(0, i);
    if (buffer.length > maxBuffered) buffer.splice(0, buffer.length - maxBuffered);
    return readings;
  }

  return {
    id: "lebrew-temp.reaplugin",
    onLoad() {
      return host.devices.bindDriver("lebrew", {
        create() {
          let active;
          function stop(state) {
            if (!state || state.stopped) return;
            state.stopped = true;
            clearTimeout(state.timer);
          }
          return {
            vendor: "LEBREW",
            dataChannels: [{key: "temperature", type: "number", unit: "°C"}],
            commands: [],
            async connect(session) {
              const state = {session, stopped: false, timer: null, buffer: []};
              active = state;
              let ready;
              let failed;
              let settled = false;
              const firstReading = new Promise((resolve, reject) => {ready = resolve; failed = reject;});
              firstReading.catch(() => {});
              function succeed() {
                if (!settled) {
                  settled = true;
                  ready();
                }
              }
              function fail(error) {
                if (!settled) {
                  settled = true;
                  failed(error);
                }
              }
              function watchSilence() {
                clearTimeout(state.timer);
                state.timer = setTimeout(() => {
                  stop(state);
                  fail(new Error("LEBREW TEMP stopped sending temperature"));
                  session.reportDisconnected().catch(() => {});
                }, silenceMs);
              }
              try {
                const services = await session.gatt.discoverServices();
                if (!services.includes(service)) throw new Error("LEBREW TEMP service unavailable");
                session.gatt.onDisconnect(() => {
                  stop(state);
                  fail(new Error("LEBREW TEMP disconnected before the first reading"));
                });
                await session.gatt.subscribe(service, temperatureCharacteristic, async data => {
                  if (state.stopped) return;
                  const bytes = bytesOf(data);
                  for (let i = 0; i < bytes.length; i++) state.buffer.push(bytes[i]);
                  const readings = takeFrames(state.buffer);
                  if (readings.length === 0) return;
                  watchSilence();
                  await session.publish({temperature: readings[readings.length - 1]});
                  if (!state.stopped) succeed();
                });
                if (!state.stopped && state.timer === null) watchSilence();
                await firstReading;
              } catch (error) {
                stop(state);
                fail(error);
                throw error;
              }
            },
            disconnect() { stop(active); },
            async execute(command) {
              throw new Error("Unknown LEBREW TEMP command: " + command.commandId);
            }
          };
        }
      });
    }
  };
}
