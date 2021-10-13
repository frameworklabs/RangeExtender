// RangeExtender

import Pappe
import CoreBluetooth

/// The hidden implementation class ffor the RangeExtender.
///
/// This separate implementation class is used to hide the needed CoreBluetooth protocol adoptions from the API class.
final class RangeExtenderImpl : NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    private weak var parent: RangeExtender!

    private var central: CBCentralManager!
    private var peripherals: [CBPeripheral] = []
    private var ranger: CBPeripheral? {
        willSet {
            if let ranger = ranger {
                ranger.delegate = nil
            }
        }
        didSet {
            if let ranger = ranger {
                ranger.delegate = self
            }
        }
    }
    private var lastRangerID: UUID?
    private var rangeService: CBService? {
        ranger?.services?.first { $0.uuid == CBUUID.rangeServiceUUID }
    }
    private var batteryService: CBService? {
        ranger?.services?.first { $0.uuid == CBUUID.batteryServiceUUID }
    }
    private var rangeCharacteristics: CBCharacteristic? {
        rangeService?.characteristics?.first { $0.uuid == CBUUID.rangeCharacteristicsUUID }
    }
    private var batteryCharacteristics: CBCharacteristic? {
        batteryService?.characteristics?.first { $0.uuid == CBUUID.batteryCharacteristicsUUID }
    }
   
    private enum Request {
        case none
        case start
        case stop
    }
    private var request: Request = .none
    
    private var error: Error?
    private var connectionError: Error?
    
    private var range: Int?
    private var battery: Int?
    
    private var timerSource: DispatchSourceTimer?
    private var isTimerExpired = false
    
    private var isTicking = false

    init(rangeExtender: RangeExtender) {
        parent = rangeExtender
    }
    
    func start() {
        request = .start
        tick()
    }
    
    func stop() {
        request = .stop
        tick()
    }

    private lazy var proc = Module { name in

        activity (name.Main, []) { val in
            `repeat` {
                `if` { self.request != .start } then: {
                    `await` { self.request == .start }
                }
                `exec` {
                    self.request = .none
                    self.parent.state_ = .starting
                }
                `when` { self.request == .stop || self.error != nil } abort: {
                    `exec` { self.central = CBCentralManager(delegate: self, queue: self.parent.queue) }
                    `defer` {
                        self.central.delegate = nil
                        self.central = nil
                    }
                    `await` { self.central.state != .unknown }

                    `if` { self.central.state == .poweredOn } then: {
                        when { self.central.state != .poweredOn } abort: {

                            `exec` { val.ok = false }
                            `if` { self.lastRangerID != nil } then: {
                                `exec` { self.ranger = self.central.retrievePeripherals(withIdentifiers: [self.lastRangerID!]).first }
                                run (name.Connect, []) { val.ok = $0 }
                            }
                            `if` { val.ok == false } then: {
                                exec { self.lastRangerID = nil }
                                run (name.Scan, [])
                                run (name.Connect, []) { val.ok = $0 }
                            }

                            `if` { val.ok } then: {
                                `when` { self.ranger?.state != .connected } abort: {
                                    `exec` { self.parent.state_ = .connected }
                                    `if` { self.rangeService == nil || self.batteryService == nil } then: {
                                        `exec` { self.ranger!.discoverServices([.rangeServiceUUID, .batteryServiceUUID]) }
                                        `await` { self.rangeService != nil && self.batteryService != nil}
                                    }
                                    `if` { self.rangeCharacteristics == nil || self.batteryCharacteristics == nil } then: {
                                        `exec` {
                                            self.ranger!.discoverCharacteristics([.rangeCharacteristicsUUID], for: self.rangeService!)
                                            self.ranger!.discoverCharacteristics([.batteryCharacteristicsUUID], for: self.batteryService!)
                                        }
                                        `await` { self.rangeCharacteristics != nil && self.batteryCharacteristics != nil }
                                    }

                                    `exec` {
                                        self.ranger!.setNotifyValue(true, for: self.rangeCharacteristics!)
                                        self.ranger!.setNotifyValue(true, for: self.batteryCharacteristics!)
                                    }
                                    `cobegin` {
                                        with {
                                            exec { self.ranger!.readValue(for: self.rangeCharacteristics!) }
                                            every { self.range != nil } do: {
                                                self.parent.range_ = self.range
                                                self.range = nil
                                            }
                                        }
                                        with {
                                            exec { self.ranger!.readValue(for: self.batteryCharacteristics!) }
                                            every { self.battery != nil } do: {
                                                self.parent.battery_ = self.battery
                                                self.battery = nil
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                `exec` {
                    self.ranger = nil
                    self.error = nil
                    self.connectionError = nil
                    self.request = .none
                    self.parent.state_ = .stopped
                    self.parent.range_ = nil
                    self.parent.battery_ = nil
                }
            }
        }

        activity (name.Scan, []) { val in
            `exec` {
                self.parent.state_ = .scanning
                self.central.scanForPeripherals(withServices: [.rangeServiceUUID])
            }
            `defer` {
                self.central.stopScan()
                self.peripherals.removeAll()
            }
            `await` { !self.peripherals.isEmpty }
            `exec` { self.ranger = self.peripherals.first }
        }

        activity (name.Connect, []) { val in
            `exec` { val.connected = false }
            `cobegin` {
                with (.weak) {
                    `exec` {
                        self.parent.state_ = .connecting
                        self.connectionError = nil
                        self.central.connect(self.ranger!)
                    }
                    `await` { self.ranger?.state == .connected || self.connectionError != nil }
                    `exec` {
                        val.connected = self.connectionError == nil
                        if val.connected {
                            self.lastRangerID = self.ranger?.identifier
                        }
                    }
                }
                with (.weak) {
                    run (name.Wait, [12]) // Timeout on the ranger is 10 seconds, so we are on the safe side with 12 secs here.
                }
            }
            `if` { !val.connected } then: {
                exec { self.central.cancelPeripheralConnection(self.ranger!) }
            }
            `return` { val.connected }
        }

        activity (name.Wait, [name.secs]) { val in
            `exec` { self.startTimer(secs: val.secs) }
            `defer` { self.cancelTimer() }
            `await` { self.isTimerExpired }
        }

    }.makeProcessor()
    
    private func tick() {
        precondition(!isTicking)
        dispatchPrecondition(condition: .onQueue(parent.queue))
        
        isTicking = true
        try! self.proc?.tick([], [])
        isTicking = false
    }
    
    private func startTimer(secs: Int) {
        precondition(timerSource == nil)

        isTimerExpired = false
        timerSource = DispatchSource.makeTimerSource(queue: parent.queue)
        guard let timerSource = timerSource else { return }
        timerSource.setEventHandler { [unowned self] in
            self.isTimerExpired = true
            self.timerSource = nil
            self.tick()
        }
        timerSource.schedule(deadline: DispatchTime.now().advanced(by: .seconds(secs)))
        timerSource.activate()
    }
    
    private func cancelTimer() {
        if let timerSource = timerSource {
            timerSource.cancel()
            self.timerSource = nil
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        tick()
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        peripherals.append(peripheral)
        tick()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        tick()
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.connectionError = error
        tick()
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        self.error = error
        tick()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        self.error = error
        tick()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        self.error = error
        tick()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            self.error = error
        } else if characteristic == rangeCharacteristics {
            self.range = characteristic.range
        } else if characteristic == batteryCharacteristics {
            self.battery = characteristic.battery
        }
        tick()
    }
}

extension CBUUID {
    static let rangeServiceUUID = CBUUID(string: "337c1e7b-b79f-4253-8ab7-66d59edbfb73")
    static let batteryServiceUUID = CBUUID(string: "180f")
    static let rangeCharacteristicsUUID = CBUUID(string: "b5791522-10cf-45ae-a308-9a37ffa329d8")
    static let batteryCharacteristicsUUID = CBUUID(string: "2a19")
}

extension CBCharacteristic {
    var range: Int? {
        guard let data = value, data.count == 2 else { return nil }
        let low: UInt8 = data[0]
        let high: UInt8 = data[1]
        return Int(high) << 8 | Int(low)
    }
    var battery: Int? {
        guard let data = value, data.count == 1 else { return nil }
        return Int(data[0])
    }
}
