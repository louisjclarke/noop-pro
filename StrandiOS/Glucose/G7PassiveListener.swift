#if os(iOS)
import Foundation
import CoreBluetooth
import StrandGlucose
import os.log

/// Listens to a Dexcom G7 / ONE+ sensor that the official Dexcom app on this iPhone is already paired
/// with. Approach after LoopKit's G7SensorKit (MIT): iOS bonds the sensor to the *phone*, so a second
/// app can connect to the same peripheral and subscribe to its notifications once the Dexcom app has
/// authenticated the session. NOOP Pro never writes to the sensor — no auth, no commands, no
/// calibration — so it cannot disturb the Dexcom app's session or its alarms.
///
/// Requirements on the phone: the Dexcom G7 app installed, signed in and receiving readings; Bluetooth
/// on; NOOP Pro allowed Bluetooth. The sensor connects for a few seconds every 5 minutes, and iOS wakes
/// NOOP Pro in the background for each connection (bluetooth-central background mode).
final class G7PassiveListener: NSObject {
    enum State: Equatable {
        case off, unauthorized, searching, connected(String), receiving(String)

        var label: String {
            switch self {
            case .off: return "Bluetooth off"
            case .unauthorized: return "Bluetooth not allowed"
            case .searching: return "Waiting for the sensor's next 5-minute check-in"
            case .connected(let n): return "Connected to \(n) — waiting for the Dexcom app to authenticate"
            case .receiving(let n): return "Receiving from \(n)"
            }
        }
    }

    var onReadings: (([GlucoseReading]) -> Void)?
    var onState: ((State) -> Void)?

    private let log = Logger(subsystem: "nooppro", category: "G7")
    private let queue = DispatchQueue(label: "nooppro.g7.ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var activation: [String: Date] = [:]
    private var backfill: [UUID: [G7BackfillMessage]] = [:]
    private var enabled = false
    /// Last time each peripheral delivered glucose, so an expired sensor stops being reconnected once
    /// its replacement is live.
    private var lastGlucose: [UUID: Date] = [:]

    private let cgmService = CBUUID(string: G7UUID.cgmService)
    private let advService = CBUUID(string: G7UUID.advertisementService)
    private let authChar = CBUUID(string: G7UUID.authentication)
    private let controlChar = CBUUID(string: G7UUID.control)
    private let backfillChar = CBUUID(string: G7UUID.backfill)

    private static let activationKey = "nooppro.g7.activation"

    override init() {
        super.init()
        if let saved = UserDefaults.standard.dictionary(forKey: Self.activationKey) as? [String: Double] {
            activation = saved.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    func start() {
        queue.async {
            self.enabled = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionRestoreIdentifierKey: "nooppro.g7.passive",
                                                          CBCentralManagerOptionShowPowerAlertKey: false])
            } else {
                self.beginObserving()
            }
        }
    }

    func stop() {
        queue.async {
            self.enabled = false
            guard let central = self.central else { return }
            central.stopScan()
            for p in self.peripherals.values { central.cancelPeripheralConnection(p) }
            self.peripherals.removeAll()
            self.publish(.searching)
        }
    }

    private func publish(_ s: State) {
        DispatchQueue.main.async { self.onState?(s) }
    }

    private func beginObserving() {
        guard enabled, central.state == .poweredOn else { return }
        for p in central.retrieveConnectedPeripherals(withServices: [advService, cgmService]) where G7UUID.isDexcomSensorName(p.name) {
            adopt(p)
        }
        central.registerForConnectionEvents(options: [.serviceUUIDs: [advService, cgmService]])
        if !central.isScanning {
            central.scanForPeripherals(withServices: [advService], options: nil)
        }
        if peripherals.isEmpty { publish(.searching) }
    }

    private func adopt(_ p: CBPeripheral) {
        guard enabled, G7UUID.isDexcomSensorName(p.name) else { return }
        peripherals[p.identifier] = p
        p.delegate = self
        if p.state == .connected {
            p.discoverServices([cgmService])
        } else if p.state != .connecting {
            // A pending connect never times out; iOS completes it at the sensor's next check-in and wakes
            // the app to handle it.
            central.connect(p, options: nil)
        }
    }

    private func saveActivation() {
        UserDefaults.standard.set(activation.mapValues { $0.timeIntervalSince1970 }, forKey: Self.activationKey)
    }

    private func flushBackfill(_ p: CBPeripheral) {
        guard let msgs = backfill.removeValue(forKey: p.identifier), !msgs.isEmpty,
              let name = p.name, let act = activation[name] else { return }
        let readings = msgs.compactMap { $0.reading(activation: act, sensorId: name) }
        log.info("G7 backfill: \(readings.count) readings")
        if !readings.isEmpty { DispatchQueue.main.async { self.onReadings?(readings) } }
    }
}

extension G7PassiveListener: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: beginObserving()
        case .unauthorized: publish(.unauthorized)
        default: publish(.off)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        enabled = true
        for p in restored where G7UUID.isDexcomSensorName(p.name) {
            peripherals[p.identifier] = p
            p.delegate = self
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard G7UUID.isDexcomSensorName(name), peripherals[peripheral.identifier] == nil else { return }
        log.info("Discovered \(name ?? "?", privacy: .public)")
        adopt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        guard event == .peerConnected else { return }
        adopt(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        publish(.connected(peripheral.name ?? "sensor"))
        peripheral.discoverServices([cgmService])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        flushBackfill(peripheral)
        // Re-arm straight away so the next 5-minute check-in is caught, foreground or not.
        if enabled, peripherals[peripheral.identifier] != nil { central.connect(peripheral, options: nil) }
        if peripherals.values.allSatisfy({ $0.state != .connected }) { publish(.searching) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if enabled { central.connect(peripheral, options: nil) }
    }
}

extension G7PassiveListener: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == cgmService }) else { return }
        peripheral.discoverCharacteristics([authChar, controlChar, backfillChar], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Watch the Dexcom app's auth handshake first; only an authenticated session will deliver
        // glucose on the control characteristic.
        if let auth = service.characteristics?.first(where: { $0.uuid == authChar }) {
            peripheral.setNotifyValue(true, for: auth)
        }
        // Safety net: if we joined after the Dexcom app had already finished authenticating, the auth
        // status notification has been and gone. Subscribing to control on an unauthenticated link is
        // simply refused by the sensor, so trying after a short wait costs nothing.
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak peripheral] in
            guard let self, let p = peripheral, p.state == .connected,
                  let control = service.characteristics?.first(where: { $0.uuid == self.controlChar }),
                  !control.isNotifying else { return }
            p.setNotifyValue(true, for: control)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let name = peripheral.name ?? "DXCM"
        switch characteristic.uuid {
        case authChar:
            if let s = G7AuthStatus(data: data), s.isAuthenticated, s.isBonded,
               let control = characteristic.service?.characteristics?.first(where: { $0.uuid == controlChar }) {
                peripheral.setNotifyValue(true, for: control)
            }
        case controlChar:
            guard let event = G7ControlEvent(data: data) else { return }
            switch event {
            case .glucose(let m):
                let now = Date()
                lastGlucose[peripheral.identifier] = now
                // A newer sensor is live: stop re-arming connections to sensors silent for 2 h+.
                for (id, p) in peripherals where id != peripheral.identifier {
                    if (lastGlucose[id] ?? .distantPast) < now.addingTimeInterval(-7200) {
                        central.cancelPeripheralConnection(p)
                        peripherals.removeValue(forKey: id)
                    }
                }
                activation[name] = m.activationDate(receivedAt: now)
                saveActivation()
                publish(.receiving(name))
                if let bf = characteristic.service?.characteristics?.first(where: { $0.uuid == backfillChar }), !bf.isNotifying {
                    peripheral.setNotifyValue(true, for: bf)
                }
                if let r = m.reading(receivedAt: now, sensorId: name) {
                    DispatchQueue.main.async { self.onReadings?([r]) }
                } else {
                    log.info("G7 message without reliable glucose: state \(m.state.label, privacy: .public)")
                }
            case .backfillFinished, .sessionStopped:
                flushBackfill(peripheral)
            default:
                break
            }
        case backfillChar:
            if let m = G7BackfillMessage(data: data) { backfill[peripheral.identifier, default: []].append(m) }
        default:
            break
        }
    }
}
#endif
