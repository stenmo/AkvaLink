// App entry. Order matters: install the native BLE shim (which defines
// navigator.bluetooth on iOS/Android) BEFORE the page logic runs, so the
// reused web/ UI finds Web Bluetooth and works unchanged.
import './ble-shim.js';
import './page.js';
