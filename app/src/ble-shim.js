// navigator.bluetooth shim backed by @capacitor-community/bluetooth-le.
//
// The AkvaLink landing page (web/index.html) talks the standard Web Bluetooth
// API. Native WebViews (iOS WKWebView, Android WebView) have no Web Bluetooth,
// so this shim implements the exact subset the page uses on top of the native
// BleClient plugin. When running in a real browser (Chrome/Edge) it does
// nothing and the page keeps using the browser's own navigator.bluetooth.
//
// Subset implemented (all the page touches):
//   navigator.bluetooth.requestDevice({ filters:[{namePrefix}], optionalServices })
//   navigator.bluetooth.getDevices()
//   device.name, device.gatt, device.addEventListener('gattserverdisconnected')
//   gatt.connect() / disconnect() / connected / getPrimaryService(uuid)
//   service.getCharacteristic(uuid)
//   char.readValue() -> DataView
//   char.writeValue(BufferSource) / writeValueWithoutResponse(BufferSource)
//   char.startNotifications() + addEventListener('characteristicvaluechanged')

import { BleClient } from '@capacitor-community/bluetooth-le';
import { Capacitor } from '@capacitor/core';

const BASE_UUID = '-0000-1000-8000-00805f9b34fb';
const STORE_KEY = 'akvalink.lastDeviceId';

// Normalise Web Bluetooth UUIDs (16-bit numbers or short/long strings) to the
// full lowercase 128-bit string BleClient expects.
function uuid(v) {
  if (typeof v === 'number') {
    return ('0000' + v.toString(16)).slice(-8).toLowerCase() + BASE_UUID;
  }
  const s = String(v).toLowerCase();
  if (/^0x[0-9a-f]+$/.test(s)) return uuid(parseInt(s, 16));
  if (/^[0-9a-f]{4}$/.test(s)) return '0000' + s + BASE_UUID;
  return s;
}

function toDataView(src) {
  if (src instanceof DataView) return src;
  if (src instanceof ArrayBuffer) return new DataView(src);
  if (ArrayBuffer.isView(src)) return new DataView(src.buffer, src.byteOffset, src.byteLength);
  throw new TypeError('AkvaLink BLE shim: unsupported write value');
}

function installShim() {
  let initialized = false;
  const ensureInit = async () => {
    if (!initialized) {
      await BleClient.initialize({ androidNeverForLocation: true });
      initialized = true;
    }
  };

  class Characteristic {
    constructor(deviceId, service, charUuid) {
      this._deviceId = deviceId;
      this._service = service;
      this.uuid = charUuid;
      this._listeners = new Set();
      this._notifying = false;
      // Bound method — its presence is how the page feature-detects no-response writes.
      this.writeValueWithoutResponse = this._writeNoRsp.bind(this);
    }
    readValue() {
      return BleClient.read(this._deviceId, this._service, this.uuid);
    }
    writeValue(value) {
      return BleClient.write(this._deviceId, this._service, this.uuid, toDataView(value));
    }
    _writeNoRsp(value) {
      return BleClient.writeWithoutResponse(this._deviceId, this._service, this.uuid, toDataView(value));
    }
    async startNotifications() {
      if (!this._notifying) {
        await BleClient.startNotifications(this._deviceId, this._service, this.uuid, (value) => {
          const ev = { target: { value } };
          this._listeners.forEach((cb) => { try { cb(ev); } catch (_) { /* ignore */ } });
        });
        this._notifying = true;
      }
      return this;
    }
    addEventListener(type, cb) {
      if (type === 'characteristicvaluechanged') this._listeners.add(cb);
    }
    removeEventListener(type, cb) {
      if (type === 'characteristicvaluechanged') this._listeners.delete(cb);
    }
  }

  class Service {
    constructor(deviceId, serviceUuid) {
      this._deviceId = deviceId;
      this.uuid = serviceUuid;
    }
    async getCharacteristic(u) {
      return new Characteristic(this._deviceId, this.uuid, uuid(u));
    }
  }

  class Server {
    constructor(device) {
      this._device = device;
      this.connected = false;
    }
    async connect() {
      await ensureInit();
      await BleClient.connect(this._device.id, () => {
        this.connected = false;
        this._device._emitDisconnect();
      });
      this.connected = true;
      return this;
    }
    async disconnect() {
      try { await BleClient.disconnect(this._device.id); } catch (_) { /* already gone */ }
      this.connected = false;
    }
    async getPrimaryService(u) {
      return new Service(this._device.id, uuid(u));
    }
  }

  class Device {
    constructor(id, name) {
      this.id = id;
      this.name = name || 'AkvaLink';
      this.gatt = new Server(this);
      this._disconnectListeners = new Set();
    }
    addEventListener(type, cb) {
      if (type === 'gattserverdisconnected') this._disconnectListeners.add(cb);
    }
    removeEventListener(type, cb) {
      if (type === 'gattserverdisconnected') this._disconnectListeners.delete(cb);
    }
    _emitDisconnect() {
      const ev = { target: this };
      this._disconnectListeners.forEach((cb) => { try { cb(ev); } catch (_) { /* ignore */ } });
    }
  }

  const bluetooth = {
    async requestDevice(options = {}) {
      await ensureInit();
      const filters = options.filters || [];
      let namePrefix;
      let services;
      for (const f of filters) {
        if (!namePrefix && f && f.namePrefix) namePrefix = f.namePrefix;
        if (!services && f && f.services && f.services.length) services = f.services.map(uuid);
      }
      const optionalServices = (options.optionalServices || []).map(uuid);
      const res = await BleClient.requestDevice({ services, namePrefix, optionalServices });
      try { localStorage.setItem(STORE_KEY, res.deviceId); } catch (_) { /* ignore */ }
      return new Device(res.deviceId, res.name);
    },
    async getDevices() {
      await ensureInit();
      let id = null;
      try { id = localStorage.getItem(STORE_KEY); } catch (_) { /* ignore */ }
      if (!id) return [];
      try {
        const devs = await BleClient.getDevices([id]);
        return devs.map((d) => new Device(d.deviceId, d.name));
      } catch (_) {
        return [];
      }
    },
  };

  try {
    Object.defineProperty(navigator, 'bluetooth', { value: bluetooth, configurable: true });
  } catch (_) {
    navigator.bluetooth = bluetooth;
  }
}

// Only take over on a native platform; browsers keep their real Web Bluetooth.
if (Capacitor.isNativePlatform()) {
  installShim();
}
