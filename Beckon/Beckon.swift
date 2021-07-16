//
//  Beckon.swift
//  Beckon
//

import Foundation

import CoreBluetooth
import RxSwift
import RxFeedback
import UserNotifications

fileprivate let BECKON_RESTORE_PERIPHERAL_NOTIFICATION = "BeckonDidRestorePeripheral"
fileprivate let BECKON_RESTORE_PERIPHERAL_USER_INFO = "BeckonRestorePeripheral"

class NoopBluetoothDelegate: NSObject, CBCentralManagerDelegate {
    static let shared = NoopBluetoothDelegate()
    
    private override init() {
        super.init()
    }
    
    var holdPeripherals = [CBPeripheral]()
    
    private func sendNotification(peripheral: CBPeripheral) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let name = Notification.Name(BECKON_RESTORE_PERIPHERAL_NOTIFICATION)
            let m = Notification(name: name, object: nil, userInfo: [BECKON_RESTORE_PERIPHERAL_USER_INFO : peripheral])
            NotificationCenter.default.post(m)
        }
    }
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripheralsObject = dict[CBCentralManagerRestoredStatePeripheralsKey] {
            let peripherals = peripheralsObject as! Array<CBPeripheral>
            
            DispatchQueue.main.async {
                for peripheral in peripherals {
                    if central.state == .poweredOn {
                        debug("[RxBt] Restoring state while powered on")
                        self.sendNotification(peripheral: peripheral)
                    } else {
                        debug("[RxBt] Restoring state while __NOT__ POWERED ON")
                        self.holdPeripherals.append(peripheral)
                    }
                }
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            debug("[RxBt] didUpdateState on centralManager during poweredOn")
            
            for peripheral in holdPeripherals {
                self.sendNotification(peripheral: peripheral)
            }
            
            holdPeripherals.removeAll()
        } else {
            debug("[RxBt] didUpdateState on centralManager during \(central.state.debugDescription)")
        }
    }
}

/**
 Describes any data connected to a device that you want to save locally.
 
 Supply your implementation to your Beckon instance and add/remove devices
 using `Beckon.settingsStore`.
 */
public protocol DeviceMetadata: Codable {
    var uuid: UUID { get set }
}

public struct DiscoveredDevice: DeviceMetadata {
    public var uuid: UUID
}

/**
 Manages local data regarding Beckon devices.
 
 Whenever Beckon finds one of the bluetooth devices whose data is in the
 SettingsStore, it will automatically connect to it.
 */
public class SettingsStore<Metadata: DeviceMetadata> {
    // Should be completely rx probably
    private var savedDevices: [Metadata]! = nil {
        didSet {
            idsAndDevices.removeAll()
            for device in savedDevices {
                idsAndDevices[device.uuid.uuidString] = device
            }
            savedDevicesSubject.onNext(savedDevices)
        }
    }
    private var idsAndDevices: [String: Metadata] = [:]
    private var savedDevicesSubject = ReplaySubject<[Metadata]>.create(bufferSize: 1)
    
    /// Observable list of saved devices
    public var saved: Observable<[Metadata]> {
        return savedDevicesSubject.asObservable()
    }

    private let appID: String
    private let savedDevicesKey: String
    
    fileprivate init(appID: String) {
        self.appID = appID
        self.savedDevicesKey = "\(appID).SavedDevices"
    }
    
    fileprivate func getSavedDevices() -> [Metadata] {
        if let savedDevices = savedDevices {
            return savedDevices
        }
        if let datas = UserDefaults.standard.value(forKey: savedDevicesKey) as? Data,
            let devices = try? PropertyListDecoder().decode([Metadata].self, from: datas) {
            savedDevices = devices/*.sorted(by: { (lhs, rhs) -> Bool in
             return lhs.name < rhs.name
             })*/
            return devices
        }
        savedDevices = []
        return []
    }
    
    /**
     Get all saved devices from the SettingsStore.
     
     - key: The local UUID of the peripheral
     - value: The DeviceMetadata connected to that peripheral.
     */
    public func getIdsAndDevices() -> [String: Metadata] {
        let _ = getSavedDevices()
        return idsAndDevices
    }
    
    /**
     Save a device to the SettingsStore.
     
     Beckon will automatically connect to any device whose DeviceMetadata
     is in the SettingsStore.
 
     - parameter savedDevice: A `DeviceMetadata` implementation where `uuid`
        corresponds to a CBPeripheral UUID.
    */
    public func saveDevice(_ savedDevice: Metadata) {
        var current = getSavedDevices()
        if let index = current.firstIndex(where: { alreadySaved in
            alreadySaved.uuid == savedDevice.uuid
        }) {
            current[index] = savedDevice
        } else {
            current.append(savedDevice)
        }

        UserDefaults.standard.set(try? PropertyListEncoder().encode(current), forKey: savedDevicesKey)
        savedDevices = current
    }
    
    /**
     Removes a device from the SettingsStore by matching the `uuid` parameter.
     
     - parameter savedDevice: Will remove any device with a `uuid` matching this
        device's `uuid`
    */
    public func removeDevice(_ savedDevice: Metadata) {
        var current = getSavedDevices()
        current.removeAll { (d) -> Bool in
            d.uuid == savedDevice.uuid
        }
        UserDefaults.standard.set(try? PropertyListEncoder().encode(current), forKey: savedDevicesKey)
        savedDevices = current
    }
    
    /**
     Remove all devices from the SettingsStore.
     */
    public func clear() {
        UserDefaults.standard.set(try? PropertyListEncoder().encode([Metadata]()), forKey: savedDevicesKey)
    }
}

/**
 Common identifier for connected, disconnected, saved and discovered devices
 */
public typealias DeviceIdentifier = UUID

public enum BeckonDeviceStatus<State> where State: BeckonState  {
    case disconnected
    case connected(state: State)
}

/**
 Represents the current state of a saved device.
 */
public class BeckonDevice<State, Metadata> where State: BeckonState, Metadata: DeviceMetadata {
    public var deviceIdentifier: DeviceIdentifier {
        return metadata.uuid
    }
    public let metadata: Metadata
    public let state: BeckonDeviceStatus<State>
    
    public init(metadata: Metadata, state: BeckonDeviceStatus<State>) {
        self.metadata = metadata
        self.state = state
    }
}

/**
 Main entry point for the Beckon framework.
 
 Manages scanning, connection and disconnection of bluetooth devices in a reactive manner.
 
 Supply your `BeckonDescriptor`, `BeckonState` and `DeviceMetadata` implementations to get
 a fully typed, reactive bluetooth runloop.
 */
public class Beckon<State, Metadata>: NSObject where State: BeckonState, Metadata: DeviceMetadata {
    private typealias Device = BeckonInternalDevice<State>
    
    private static func makeInstance(key: String) -> CBCentralManager {
        return CBCentralManager(
            delegate: NoopBluetoothDelegate.shared,
            queue: DispatchQueue.global(qos: .userInteractive),
            options: [CBCentralManagerOptionRestoreIdentifierKey : key])
    }
    
    public let appID: String
    private let instance: CBCentralManager
    
    /**
     The CBCentralManager used by Beckon.
     
     Only use this if you know what you're doing, and it's not supported by Beckon otherwise.
    */
    public var unsafeCentralManager: CBCentralManager { return instance }
    
    /**
     The SettingsStore used to save which devices to connect to and what data to save between runs.
    */
    public private(set) var settingsStore: SettingsStore<Metadata>
    
    private let disposeBag = DisposeBag()
    
    private var pairablePeripherals: [CBPeripheral] = []
    private var connectedDevices: [Device] = []
    private var pairedDevices: [Device] = []
    
    public var delegate: BeckonDescriptor
    
    fileprivate let restoredPeripheralsSubject = PublishSubject<CBPeripheral>()
    
    private let devicesSubject = BehaviorSubject<[Device]>.init(value: [])
    
    private let rescanSubject = ReplaySubject<Int>.create(bufferSize: 1)
    
    /**
     Start the runloop.
    */
    public func start() {
        rescanSubject.onNext(1)
    }

    /**
     Force a rescan.
     
     Usually not needed, but can sometimes speed up finding devices which just got into range.
    */
    public func rescan() {
        rescanSubject.onNext(1)
    }
    
    /**
     Observable of devices. Updated on every state change.
    */
    public var devices: Observable<[BeckonDevice<State, Metadata>]> {
        
        return Observable.combineLatest(self.internalDevices.flatMapLatest { devices -> Observable<[(DeviceIdentifier, State)]> in
            
            if devices.count == 0 {
                return Observable.just([])
            }
            
            return Observable.combineLatest(devices.map { device in device.state.map { actualState in return (device.deviceIdentifier, actualState) } })
            
        }, self.settingsStore.saved)
            .map { (arg: ([(DeviceIdentifier, State)], [Metadata])) -> [BeckonDevice<State, Metadata>] in
                let (connected, saved) = arg
                
                var connectedHash = [DeviceIdentifier:State]()
                for device in connected {
                    connectedHash[device.0] = device.1
                }
                
                return saved.map { metadata in
                    let state: State? = connectedHash[metadata.uuid]
                    return BeckonDevice<State, Metadata>(metadata: metadata, state: state != nil ? BeckonDeviceStatus<State>.connected(state: state!) : BeckonDeviceStatus<State>.disconnected)
                }
        }
    }
    
    private var internalDevices: Observable<[Device]> {
        return devicesSubject.asObservable()
    }
    
    private func device(for identifier:DeviceIdentifier) -> Device? {
        if let device = connectedDevices.first(where: { device in device.deviceIdentifier == identifier }) {
            return device
        }
        if let device = pairedDevices.first(where: { device in device.deviceIdentifier == identifier }) {
            return device
        }
        return nil
    }
    
    /**
     Observable of latest state for a connected device.
     */
    public func state(forDevice deviceIdentifier: DeviceIdentifier) -> Observable<State> {
        return device(for: deviceIdentifier)?.state ?? Observable.error(BeckonNoSuchDeviceError())
    }
    
    /**
     Poll connected device for updates on a single characteristic
     */
    public func updateCharacteristic(_ characteristic: CBUUID, for device: DeviceIdentifier) {
        self.device(for: device)?.updateCharacteristic(characteristic)
    }
    
    /**
     Create the Beckon instance.
     
     - parameter appID: A unique identifier for your app. Defaults to the bundle identifier.
    */
    public init(appID: String = Bundle.main.bundleIdentifier!, descriptor: BeckonDescriptor) {
        self.appID = appID
        self.delegate = descriptor
        
        self.devicesSubject.subscribe(onNext: {
            trace("[RxBt] (devicesSubject) Current devices: \($0.map { $0.peripheral.name ?? "UNKNOWN" })")
        }, onError: {
            trace("[RxBt] (devicesSubject) Devices subject did error: \($0)")
        }, onCompleted: {
            trace("[RxBt] (devicesSubject) Devices subject completed")
        }, onDisposed: {
            trace("[RxBt] (devicesSubject) Devices subject disposed")
        }).disposed(by: disposeBag)
        
        defer {
            self.devices.subscribe(onNext: {
                trace("[RxBt] (instance) Current devices: \($0)")
            }, onError: {
                trace("[RxBt] (instance) Devices subject did error: \($0)")
            }, onCompleted: {
                trace("[RxBt] (instance) Devices subject completed")
            }, onDisposed: {
                trace("[RxBt] (instance) Devices subject disposed")
            }).disposed(by: disposeBag)
        }
        
        instance = Beckon.makeInstance(key: "\(appID).CentralManagerIdentifier")
        settingsStore = SettingsStore<Metadata>(appID: appID)
        super.init()
        setup()
    }
    
    /**
     Observable of current CBManagerState
    */
    public var bluetoothState: Observable<CBManagerState> {
        return self.instance.rx.state
    }
    
    /**
     Manually disconnect a device
    */
    public func disconnect(device identifier: DeviceIdentifier) {
        guard let device = self.device(for: identifier) else { return }
        
        let appState = UIApplication.shared.applicationState
        if appState == .active {
            self.instance.cancelPeripheralConnection(device.peripheral)
        }
        self.rescan()
        self.disconnectedDevice(device.peripheral)
        device.dispose()
    }
    
    private func disconnectedDevice(_ peripheral: CBPeripheral) {
        self.pairedDevices.removeAll { (pairedDevice) -> Bool in
            pairedDevice.peripheral.identifier == peripheral.identifier
        }
        self.devicesSubject.onNext(self.pairedDevices)
    }
    
    /**
     Cancel all peripheral connections and start fresh.
     */
    public func reset() {
        self.connectedDevices.forEach({ (device) in
            _ = self.instance.rx.cancelPeripheralConnection(device.peripheral)
        })
        self.connectedDevices.removeAll()
        self.pairedDevices.forEach({ (device) in
            //                    _ = Axkid.shared.instance.rx.cancelPeripheralConnection(device.peripheral)
            self.disconnect(device: device.deviceIdentifier)
        })
        self.pairedDevices.removeAll()
        self.devicesSubject.onNext([])
        self.rescan()
    }
    
    /**
     Start the connection/disconnection runloop for the devices saved in the SettingsStore.
     
     Run only once.
    */
    private func setup() {
        // Listen for restored peripherals catched by the NoopBluetoothDelegate
        NotificationCenter.default.rx
            .notification(Notification.Name(BECKON_RESTORE_PERIPHERAL_NOTIFICATION))
            .subscribe(onNext: { [unowned self] notification in
                if let peripheral = notification.userInfo?[BECKON_RESTORE_PERIPHERAL_USER_INFO] as? CBPeripheral {
                    self.restoredPeripheralsSubject.onNext(peripheral)
                }
            }).disposed(by: disposeBag)
        
        // Disconnect on bluetooth off
        self.instance.rx
            .state
            .filter { state in return CBManagerState.poweredOff == state }
            .observe(on: MainScheduler.instance)
            .subscribe(on: MainScheduler.instance)
            .subscribe(onNext: { [unowned self] _ in
                self.connectedDevices.forEach({ [unowned self] (device) in
                    _ = self.instance.rx.cancelPeripheralConnection(device.peripheral)
                })
                self.connectedDevices.removeAll()
                self.pairedDevices.forEach({ (device) in
                    self.disconnect(device: device.deviceIdentifier)
                })
                self.pairedDevices.removeAll()
                self.devicesSubject.onNext([])
            }).disposed(by: disposeBag)
        
        // Main connection loop
        let newDevicesObservable = self.instance.rx
            .state
            .filter { state in return (CBManagerState.poweredOn == state) }
            .flatMapLatest { [unowned self] _ in return self.rescanSubject.asObservable() }
            .flatMapLatest { _ in
                self.instance.rx.scanForPeripherals(withServices: self.delegate.services.map { $0.uuid })
            }
            .do(onNext: { trace("[X] (SETUP) Found \($0.peripheral.name!), is it pairable?") })
            .filter {
                // Entry point for selecting only paired
                self.delegate.isPairable(advertisementData: $0.data)
            }
            .do(onNext: { trace("[X] (SETUP) onNext isPairable: \($0.peripheral.name!)") }, onCompleted: { trace("[X] (SETUP) Completed scanning") })
            .filter { [unowned self] dp in
                // This is probably kinda slow
                return (self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(dp.peripheral.identifier)
            }
            .do(onNext: { trace("[X] (SETUP) Pairable: \($0.peripheral.name!)") })
            .map { it -> CBPeripheral in
                return it.peripheral
            }
        
        let shadowConnected = { () -> [CBPeripheral] in
            self.instance.retrieveConnectedPeripherals(withServices: self.delegate.services.map { $0.uuid })
                .filter { peripheral in
                    self.delegate.isPairable(
                        advertisementData: AdvertisementData(
                            services: peripheral.services?.map { serv in serv.uuid } ?? [],
                            name: peripheral.name ?? ""
                        )
                    )
                }
                .filter { [unowned self] peripheral in
                    return (self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(peripheral.identifier)
                }
        }
        
        let retrievedPeripherals = { () -> Set<CBPeripheral> in
            let savedDevices = self.settingsStore.getSavedDevices()
            
            var retrievedPeripherals = Set<CBPeripheral>()
            self.instance.retrievePeripherals(withIdentifiers: savedDevices.map { $0.uuid }).forEach { retrievedPeripherals.insert($0) }
            
            return retrievedPeripherals.filter { [unowned self] peripheral in
                return (self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(peripheral.identifier)
            }
        }
        
        let restoredPeripherals = self.restoredPeripheralsSubject.filter { [unowned self] peripheral in
            return (self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(peripheral.identifier)
        }
        
        self.instance.rx
            .state
            .do(onNext: { x in debug("[RxBt] Checking state: \(x)") })
            .filter { state in return CBManagerState.poweredOn == state }
            .do(onNext: { _ in debug("[RxBt] State claims to be powered on") })
            .distinctUntilChanged()
//            .onBluetoothQueue()
            .flatMapLatest { [unowned self] _ in return self.rescanSubject.asObservable() }
            .flatMapLatest { _ in
                Observable<CBPeripheral>.merge(
                    newDevicesObservable,
                    Observable.from(shadowConnected()),
                    restoredPeripherals,
                    Observable.from(retrievedPeripherals())
                )
                // Not latest or it will only connect to the latest device it sees.
                .flatMap { peripheral -> Observable<CBPeripheral> in
                    trace("[X] (SETUP) \(peripheral.name!) state -> \(peripheral.state)")
                
                    if peripheral.state == .connected {
                        trace("[X] (SETUP) \(peripheral.name!) is already connected")
                        return self.instance.rx.hydrate(peripheral).asObservable()
                    } else if peripheral.state == .connecting {
                        return peripheral.rx.state
                            .filter { pstate in pstate != CBPeripheralState.connecting }
                            .flatMapLatest { pstate -> Observable<CBPeripheral> in
                                if pstate != CBPeripheralState.connected {
                                    trace("[X] (SETUP) \(peripheral.name!) went from connecting to faulty state -> \(pstate)")
                                    return Observable.empty()
                                }

                                trace("[X] (SETUP) \(peripheral.name!) connecting -> CONNECTED")
                                return self.instance.rx.hydrate(peripheral).asObservable()
                            }
                    } else if peripheral.state == CBPeripheralState.disconnecting {
                        trace("[X] (SETUP) \(peripheral.name!) waiting for disconnect")
                        return peripheral.rx.state
                            .filter { pstate in pstate != CBPeripheralState.disconnected }
                            .flatMap { _ -> Single<CBPeripheral> in
                                trace("[X] (SETUP) \(peripheral.name!) reconnect")
                                return self.instance.rx.connect(peripheral)
                            }.asObservable()
                    } else {
                        trace("[X] (SETUP) \(peripheral.name!) connect is fired")
                        return self.instance.rx.connect(peripheral).asObservable()
                    }
                }
            }
            .filter({ (peripheral) -> Bool in
                let isNotPaired = !(self.pairedDevices.contains(where: { (device) -> Bool in
                    device.peripheral == peripheral
                }))
                trace("[X] (SETUP) isNotPaired: \(isNotPaired) - \(peripheral.identifier) '\(peripheral.name!)")
                return isNotPaired
            })
            .do(onNext: { p in
                trace("[X] (SETUP) hasConnected: \(p.identifier) '\(p.name!)")
            })
            .subscribe(onNext: { [weak self] peripheral in
                guard let `self` = self else { return }
                
                trace("[X] (SETUP) Creating a device for peripheral: \(peripheral.name!)")
                if let device = Device(peripheral: peripheral, descriptor: self.delegate) {
                    self.pairedDevices.removeAll(where: { (pairedDevice) -> Bool in
                        let v = pairedDevice.peripheral.identifier == device.peripheral.identifier
                        if v {
                            trace("[X] (SETUP) Removing to update paired device: \(pairedDevice.peripheral.identifier) '\(device.peripheral.name!)'")
                        }
                        return v
                    })
                    debug("[X] (SETUP) Added device \(peripheral.identifier) '\(peripheral.name!)'")
                    self.pairedDevices.append(device)
                    self.devicesSubject.onNext(self.pairedDevices)
                }
            }).disposed(by: disposeBag)
        
        // Clean up when losing connection
        self.devicesSubject
            // TODO: this might not be good.
            .asInfallible(onErrorJustReturn: [])
            .flatMapLatest { (devices: [Device]) in
                Observable.from(devices)
            }
            .flatMap { (device: Device) in
                device.peripheral.rx.state.map { return (device, $0) }
            }
            .filter { _, state in state == CBPeripheralState.disconnected }
            .flatMapLatest { device, _ -> Observable<Device> in
                return Observable.just(device)
            }
            .filter { $0.peripheral.state == .disconnected }
            // TODO: this no longer compiles.
//            .delay(1.0, scheduler: ConcurrentMainScheduler.instance)
            .map { [unowned self] device in
                // NOTE: Side effects
                self.disconnect(device: device.deviceIdentifier)
            }
            .subscribe()
            .disposed(by: disposeBag)
        
        // When saving a new device, keep it connected but switch it over to the paired list
        self.settingsStore.saved
            .subscribe(onNext: { [unowned self] savedDevices in
                for (index, device) in self.connectedDevices.enumerated().reversed() {
                    if savedDevices.contains(where: { (metadata) -> Bool in
                        metadata.uuid == device.deviceIdentifier
                    }) {
                        self.connectedDevices.remove(at: index)
                        self.pairedDevices.append(device)
                        self.devicesSubject.onNext(self.pairedDevices)
                    }
                }
            }).disposed(by: disposeBag)
        
        //        rescanSubject.onNext(1)
        devicesSubject.onNext([])
    }
    
    /**
     Search for any pairable devices according to the BeckonDescriptor.
     
     Subscribe to this and save any devices you want to add to your runloop
     using `Beckon.settingsStore.saveDevice(_)`.
    */
    public func search() -> Observable<DiscoveredDevice> {
        let newDevicesObservable = self.instance.rx
            .state
            .filter { state in return (CBManagerState.poweredOn == state) }
            .flatMapLatest { _ in
                self.instance.rx.scanForPeripherals(
                    withServices: self.delegate.services.map { $0.uuid })
            }
            .do(onNext: { trace("[X] (SEARCH) Found \($0.peripheral.name ?? "Unknown name"), is it pairable?") })
            .filter {
                // Entry point for selecting only paired
                self.delegate.isPairable(advertisementData: $0.data)
            }
            .do(onNext: { trace("[X] (SEARCH) Yes, it is pairable: \($0.peripheral.name ?? "Unknown name")") }, onCompleted: { trace("[X] (SEARCH) Completed scanning") })
            .filter { [unowned self] dp in
                // This is probably kinda slow
                return !(self.settingsStore.getSavedDevices()
                    .map { $0.uuid }
                    .contains(dp.peripheral.identifier))
            }
            .flatMap({ (discovered : DiscoveredPeripheral) -> Observable<CBPeripheral> in
                trace("[X] (SEARCH) And it's NOT a saved device: \(discovered.data.name ?? "Unknown name")")
                return Observable.just(discovered.peripheral)
            })
        
        let shadowConnected = self.instance.retrieveConnectedPeripherals(
                withServices: self.delegate.services.map { $0.uuid })
            .filter { peripheral in
                let data = AdvertisementData(
                    services: peripheral.services?.map { serv in serv.uuid } ?? [],
                    name: peripheral.name ?? "")
                return self.delegate.isPairable(advertisementData: data)
            }
            .filter { [unowned self] peripheral in
                return !(self.settingsStore.getSavedDevices()
                    .map { $0.uuid }
                    .contains(peripheral.identifier))
            }
        
        return Observable<CBPeripheral>.merge(newDevicesObservable, Observable.from(shadowConnected))
            .filter { !(self.pairablePeripherals.contains($0)) }
            .do(onNext: { p in
                self.pairablePeripherals.append(p)
            })
            .flatMap { peripheral -> Observable<CBPeripheral> in
                trace("[X] (SEARCH) \(peripheral.name!) state -> \(peripheral.state)")
                
                if peripheral.state == .connected {
                    trace("[X] (SEARCH) \(peripheral.name!) is already connected")
                    return self.instance.rx.hydrate(peripheral).asObservable()
                } else if peripheral.state == .connecting {
                    return peripheral.rx.state
                        .filter { pstate in pstate != CBPeripheralState.connecting }
                        .flatMapLatest { pstate -> Observable<CBPeripheral> in
                            if pstate != CBPeripheralState.connected {
                                trace("[X] (SEARCH) \(peripheral.name!) went from connecting to faulty state -> \(pstate)")
                                return Observable.empty()
                            }
                            
                            trace("[X] (SEARCH) \(peripheral.name!) connecting -> CONNECTED")
                            return self.instance.rx.hydrate(peripheral).asObservable()
                    }
                } else if peripheral.state == CBPeripheralState.disconnecting {
                    trace("[X] (SEARCH) \(peripheral.name!) waiting for disconnect")
                    return peripheral.rx.state
                        .filter { pstate in pstate != CBPeripheralState.disconnected }
                        .flatMap { _ -> Single<CBPeripheral> in
                            trace("[X] (SEARCH) \(peripheral.name!) reconnect")
                            return self.instance.rx.connect(peripheral)
                        }.asObservable()
                } else {
                    trace("[X] (SEARCH) \(peripheral.name!) connect is fired")
                    return self.instance.rx.connect(peripheral).asObservable()
                }
            }
            .onBluetoothQueue()
            .map { [unowned self] peripheral -> Device? in
                trace("[X] (SEARCH) Trying to make a Device: \(peripheral.name ?? "Unknown name")")
                return Device(peripheral: peripheral, descriptor: self.delegate)
            }
            .flatMap({ device -> Observable<Device> in
                return device.map { mapDevice in
                    self.connectedDevices.append(mapDevice)
                    self.pairablePeripherals.removeAll(where: { (peripheral) -> Bool in
                        return mapDevice.deviceIdentifier == peripheral.identifier
                    })
                    return Observable.just(mapDevice)
                } ?? Observable.empty()
            })
            .map {
                return DiscoveredDevice(uuid: $0.deviceIdentifier)
            }
            .do(onDispose: { [weak self] in
                trace("[X] (SEARCH) Disposing search!")
                self?.stopSearch()
            })
    }
    
    /**
     Disconnect from all devices found while searching for new devices.
    */
    public func stopSearch() {
        self.pairablePeripherals.forEach({ [unowned self] (peripheral) in
            self.instance.rx.cancelPeripheralConnection(peripheral).subscribe(onSuccess: { (p) in
                self.pairablePeripherals.removeAll(where: { (p2) -> Bool in
                    return p2 == p
                })
            }).disposed(by: disposeBag)
        })
//        self.pairablePeripherals.removeAll()

        self.connectedDevices.forEach({ [unowned self] (device) in
            self.disconnect(device: device.deviceIdentifier)
        })
        self.connectedDevices.removeAll()
        //        self.instance.stopScan()
    }
    
    /**
     Write a value to a previously specified characteristic
     */
    public func write<T>(value: T, to characteristicID: WriteOnlyBluetoothCharacteristicUUID<T>, on device: DeviceIdentifier) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        return self.device(for: device)?.write(value: value, to: characteristicID) ?? Single.error(BeckonNoSuchDeviceError())
    }

    public func write<T>(value: T, to characteristicID: ConvertibleBluetoothCharacteristicUUID<T, State>, on device: DeviceIdentifier) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        return self.device(for: device)?.write(value: value, to: characteristicID) ?? Single.error(BeckonNoSuchDeviceError())
    }

    public func write<T>(value: T, to characteristicID: CustomBluetoothCharacteristicUUID<State>, on device: DeviceIdentifier) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        return self.device(for: device)?.write(value: value, to: characteristicID) ?? Single.error(BeckonNoSuchDeviceError())
    }

    public func write<T>(value: T, to uuid: CBUUID, on device: DeviceIdentifier) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        return self.device(for: device)?.write(value: value, to: uuid) ?? Single.error(BeckonNoSuchDeviceError())
    }
}

private class BeckonInternalDevice<State>: NSObject, Disposable where State: BeckonState  {
    static func == (lhs: BeckonInternalDevice, rhs: BeckonInternalDevice) -> Bool {
        return lhs.peripheral == rhs.peripheral
    }
    
    public let peripheral: CBPeripheral
    
    public var deviceIdentifier: UUID {
        return peripheral.identifier
    }
    
    private var services: [CBUUID: (BluetoothServiceUUID, CBService)] = [:]
    private var characteristics: [CBUUID: (BluetoothCharacteristicUUID, CBCharacteristic)] = [:]
    
    private let disposeBag = DisposeBag()
    
    required public init?(peripheral: CBPeripheral, descriptor: BeckonDescriptor) {
        trace("[RxBt] (InternalDevice) Init '\(peripheral.name!)'")
        self.peripheral = peripheral
        
        let characteristicIDs = descriptor.characteristics
        
        for cbService in peripheral.services ?? [] {
            
            let serviceCharacteristics = cbService.characteristics ?? []
            
            for cbCharacteristic in serviceCharacteristics {
                if let characteristicID = characteristicIDs.first(where: {
                    characteristicUUID in characteristicUUID.uuid.uuidString == cbCharacteristic.uuid.uuidString
                }) {
                    self.services[cbService.uuid] = (characteristicID.service, cbService)

                    self.characteristics[characteristicID.uuid] = (characteristicID, cbCharacteristic)
                }
            }
        }
        
        trace("[RxBt] (InternalDevice) Services count: \(self.services.count)")
        trace("[RxBt] (InternalDevice) Characteristics count: \(self.characteristics.count)")
        
        let a = (self.services.count < descriptor.services.count)
        let b = (self.characteristics.count < descriptor.characteristics.count)
        
        if a || b {
            debug("[RxBt] (InternalDevice) Init: Too few services or characteristics; returning nil!")
            return nil
        }
        
        super.init()
    }
    
    private var deviceStateSubject: ReplaySubject<State>! = ReplaySubject.create(bufferSize: 1)
    private var connectedDeviceState: Disposable? = nil
    
    private var bindings: Bindings<BluetoothCharacteristicUUID>! = nil
    
    public private(set) lazy var state: Observable<State>! = {
        trace("[RxBt] (InternalDevice) State initializing")
        let x = Observable.system(
            initialState: State.defaultState,
            reduce: { [unowned self] in self.reducer(characteristicID: $1, oldState: $0) },
            scheduler: ConcurrentMainScheduler.instance,
            feedback: RxFeedback.bind { [unowned self] state in
                trace("[RxBt] (InternalDevice) State feedback binding triggered")
                let bindings = Bindings(subscriptions: [Disposable](), events: self.subscriptions())
                self.bindings = bindings
                return bindings
            }
            ).multicast(self.deviceStateSubject)
        self.connectedDeviceState = x.connect()
        return x
    }()
    
    private func subscriptions() -> [Observable<BluetoothCharacteristicUUID>] {
        debug("[RxBt] (InternalDevice) self.subscriptions() called")
        let notifyAndReadCharacteristics = self.characteristics
            .filter { char in
                char.value.0.traits.contains(where: { trait in trait == .notify || trait == .read })
            }
            
        return notifyAndReadCharacteristics.map { (arg) -> Observable<BluetoothCharacteristicUUID> in
            let (_, (id, _)) = arg
            let uuidString = id.uuid.uuidString
            
            trace("[RxBt] (InternalDevice) \(self.peripheral.name!) Checking read and notify traits")
            if id.traits.contains(.notify) {
                trace("[RxBt] (InternalDevice) \(self.peripheral.name!) Notify required")
                _ = peripheral.rx.setNotifyValue(
                    true,
                    for: id,
                    with: PriorityInfo(
                        tag: "notify.\(uuidString)",
                        priority: Operation.QueuePriority.normal
                    )
                ).subscribe()
            }
            if id.traits.contains(.read) {
                trace("[RxBt] (InternalDevice) \(self.peripheral.name!) Read required")
                _ = peripheral.rx.readValue(
                    for: id,
                    with: PriorityInfo(
                        tag: "read.\(uuidString)",
                        priority: Operation.QueuePriority.normal
                    )
                ).subscribe()
            }
            
            trace("[RxBt] (InternalDevice) \(self.peripheral.name!) Requesting to watch value \(uuidString)")
            return self.peripheral.rx.watchValue(
                for: id,
                with: PriorityInfo(
                    tag: "watch.\(uuidString)",
                    priority: Operation.QueuePriority.normal
                )
            )
            .map { _ in
                return id
            }.do(
                onSubscribe: {
                    trace("[RxBt] (InternalDevice) Trying to watch: \(self.peripheral.name ?? "FUUU") \(uuidString)")
                },
                onSubscribed: {
                    trace("[RxBt] (InternalDevice) Successfully watching: \(self.peripheral.name ?? "FUUU") \(uuidString)")
                },
                onDispose: {
                    trace("[RxBt] (InternalDevice) Stopped watching: \(self.peripheral.name ?? "FUUU") \(uuidString)")
                }
            )
        }
    }
    
    func updateCharacteristic(_ uuid: CBUUID) {
        guard let id = self.characteristics[uuid]?.0 else {
            return
        }
        let uuidString = id.uuid.uuidString
        _ = peripheral.rx.readValue(
            for: id,
            with: PriorityInfo(
                tag: "read.\(uuidString)",
                priority: Operation.QueuePriority.normal
            )
        ).subscribe()
    }
    
    func setter<Object: AnyObject, Value>(
        for object: Object,
        keyPath: WritableKeyPath<Object, Value>
        ) -> (Value) -> Void {
        return { [weak object] value in
            object?[keyPath: keyPath] = value
        }
    }
    
    open func reducer(characteristicID: BluetoothCharacteristicUUID, oldState: State) -> State {
        guard let data = self.characteristics[characteristicID.uuid]?.1.value else {
            trace("[Reducer] Reducer ran without finding data! \(characteristicID.uuid.uuidString)")
            return oldState
        }
        
        // Custom mappers
        if let custom = characteristicID as? CustomBluetoothCharacteristicUUID<State> {
            trace("[Reducer] Using custom mapper: \(custom)")
            return custom.mapper(data, oldState)
        }
        
        trace("[Reducer] Trying BeckonMappable reducers")
        
        // The automaticly convertable characteristics all need to be tested here,
        // because Swift's generics aren't covariant... Adding a BeckonMappable means
        // implementing BeckonMappable AND adding it here
        if let convertible = characteristicID as? ConvertibleBluetoothCharacteristicUUID<Int, State> {
            return self.reducer(data: data, convertible: convertible, oldState: oldState)
        }
        
        if let convertible = characteristicID as? ConvertibleBluetoothCharacteristicUUID<String, State> {
            return self.reducer(data: data, convertible: convertible, oldState: oldState)
        }
        
        if let convertible = characteristicID as? ConvertibleBluetoothCharacteristicUUID<Bool, State> {
            return self.reducer(data: data, convertible: convertible, oldState: oldState)
        }
        
        trace("[Reducer] Could not parse data, returning old state!")

        return oldState
    }
    
    func reducer<T>(data: Data, convertible: ConvertibleBluetoothCharacteristicUUID<T, State>, oldState: State) -> State where T: BeckonMappable {
        
        let mappableValue = oldState[keyPath: convertible.keypath]
        
        var newState = oldState
        do {
            try newState[keyPath: convertible.keypath] = mappableValue.mapper(data)
        } catch {
            if let error = error as? BeckonMapperError {
                print("Could not parse as \(error.mapper): \(error.data)")
            }
        }
        
        return newState
    }
    
    func write<T>(value: T, to characteristicID: WriteOnlyBluetoothCharacteristicUUID<T>) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        if let _ = self.characteristics[characteristicID.uuid]?.1 {
            do {
                let data = try value.mapper(value)
                return self.peripheral.rx.writeValue(data: data, for: characteristicID, with: PriorityInfo(tag: "write", priority: Operation.QueuePriority.normal))
                    .map { _ in return BeckonWriteResponse() }

            } catch {
                if let error = error as? BeckonSerializeError {
                    print("Could not serialize \(error.value) as \(error.mapper): ")
                }
                return Single.error(error)
            }
        }
        return Single.error(BeckonInvalidCharacteristicError())
    }
    
    func write<T>(value: T, to characteristicID: ConvertibleBluetoothCharacteristicUUID<T, State>) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        if let _ = self.characteristics[characteristicID.uuid]?.1 {
            do {
                let data = try value.mapper(value)
                print("Writing \(data.base64EncodedString()) to \(characteristicID.uuid)")
                return self.peripheral.rx.writeValue(data: data, for: characteristicID, with: PriorityInfo(tag: "write", priority: Operation.QueuePriority.normal))
                    .map { _ in return BeckonWriteResponse() }

            } catch {
                if let error = error as? BeckonSerializeError {
                    print("Could not serialize \(error.value) as \(error.mapper): ")
                }
                return Single.error(error)
            }
        }
        return Single.error(BeckonInvalidCharacteristicError())
    }

    
    func write<T>(value: T, to characteristicID: CustomBluetoothCharacteristicUUID<State>) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        if let _ = self.characteristics[characteristicID.uuid]?.1 {
            do {
                let data = try value.mapper(value)
                return self.peripheral.rx.writeValue(data: data, for: characteristicID, with: PriorityInfo(tag: "write", priority: Operation.QueuePriority.normal))
                    .map { _ in return BeckonWriteResponse() }

            } catch {
                if let error = error as? BeckonSerializeError {
                    print("Could not serialize \(error.value) as \(error.mapper): ")
                }
                return Single.error(error)
            }
        }
        return Single.error(BeckonInvalidCharacteristicError())
    }

    func write<T>(value: T, to uuid: CBUUID) -> Single<BeckonWriteResponse> where T: BeckonMappable {
        if let _ = self.characteristics[uuid]?.1,
            let characteristicID = self.characteristics[uuid]?.0, characteristicID.traits.contains(.write) {
            do {
                let data = try value.mapper(value)
                return self.peripheral.rx.writeValue(data: data, for: characteristicID, with: PriorityInfo(tag: "write", priority: Operation.QueuePriority.normal))
                    .map { _ in return BeckonWriteResponse() }

            } catch {
                if let error = error as? BeckonSerializeError {
                    print("Could not serialize \(error.value) as \(error.mapper): ")
                }
                return Single.error(error)
            }
        }
        return Single.error(BeckonInvalidCharacteristicError())
    }

    
    deinit {
        trace("[InternalDevice] DEINIT")
        dispose()
    }
    
    public func dispose() {
        trace("[InternalDevice] DISPOSE")
        
        connectedDeviceState?.dispose()
        connectedDeviceState = nil
        
        deviceStateSubject?.onCompleted()
        bindings?.dispose()
        
        deviceStateSubject = nil
        bindings = nil
        
        trace("[InternalDevice] DISPOSED")
    }
}

public struct BeckonWriteResponse {}

public struct BeckonInvalidCharacteristicError: Error {}
public struct BeckonNoSuchDeviceError: Error {}

/**
 Describes your bluetooth device.
 */
public protocol BeckonDescriptor: AnyObject {
    var services: [BluetoothServiceUUID] { get }
    var characteristics: [BluetoothCharacteristicUUID] { get }
    func isPairable(advertisementData: AdvertisementData) -> Bool
}

/**
 Extend this and supply to your Beckon instance to get
 a typesafe state that will be updated as new values
 are read from the characteristics in your descriptor.
 
 To use keypath mapping and immutable state, define the
 state in the same file as your characteristics like this:
 
 ```
 fileprivate(set) var property: <BeckonMappableImplementation>
 ```
 */
public protocol BeckonState: Equatable {
    static var defaultState: Self { get }
}

let observeQueue = MainScheduler.instance //SerialDispatchQueueScheduler.init(internalSerialQueueName: "obs")
let subscribeQueue = ConcurrentMainScheduler.instance //SerialDispatchQueueScheduler.init(internalSerialQueueName: "sub")

extension ObservableType {
    public func onBluetoothQueue() -> Observable<Element> {
        return self.map { $0 }
//            .observe(on: observeQueue)
//            .subscribeOn(subscribeQueue)
    }
}
