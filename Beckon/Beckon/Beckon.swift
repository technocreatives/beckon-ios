//
//  Beckon.swift
//  Beckon
//
//  Created by Ville Petersson on 2019-04-02.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
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
                        self.sendNotification(peripheral: peripheral)
                    } else {
                        self.holdPeripherals.append(peripheral)
                    }
                }
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            for peripheral in holdPeripherals {
                self.sendNotification(peripheral: peripheral)
            }
            
            holdPeripherals.removeAll()
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
 Main entry point for the Beckon framework.
 
 Manages scanning, connection and disconnection of bluetooth devices in a reactive manner.
 
 Supply your `BeckonDescriptor`, `BeckonDevice`, `BeckonState` and `DeviceMetadata` implementations to get
 a fully typed, reactive bluetooth runloop.
 */
public class Beckon<Device, State, Metadata>: NSObject where Device: BeckonDevice<State>, State: BeckonState, Metadata: DeviceMetadata {
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
    
    private var connectedDevices: [Device] = []
    private var pairedDevices: [Device] = []
    
    public var delegate: BeckonDescriptor?
    
    fileprivate let restoredPeripheralsSubject = PublishSubject<CBPeripheral>()
    
    private let devicesSubject = BehaviorSubject<[Device]>.init(value: [])
    
    private let rescanSubject = ReplaySubject<Int>.create(bufferSize: 1)
    
    /**
     Force a rescan.
     
     Usually not needed, but can sometimes speed up finding devices which just got into range.
    */
    public func rescan() {
        rescanSubject.onNext(1)
    }
    
    /**
     Observable of latest connected devices.
    */
    public var devices: Observable<[Device]> {
        return devicesSubject.asObservable()
    }
    
    public func state(forDevice deviceIdentifier:UUID) -> Observable<State>? {
        return pairedDevices.first(where: { $0.deviceIdentifier == deviceIdentifier })?.state
    }
    
    /**
     Create the Beckon instance.
     
     - parameter appID: A unique identifier for your app. Defaults to the bundle identifier.
    */
    public init(appID: String = Bundle.main.bundleIdentifier!) {
        self.appID = appID
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
    public func disconnect(device: Device) {
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
            self.disconnect(device: device)
        })
        self.pairedDevices.removeAll()
        self.devicesSubject.onNext([])
        self.rescan()
    }
    
    /**
     Start the connection/disconnection runloop for the devices saved in the SettingsStore.
     
     Run only once.
    */
    public func setup() {
        // Listen for restored peripherals catched by the NoopBluetoothDelegate
        NotificationCenter.default.rx.notification(Notification.Name(BECKON_RESTORE_PERIPHERAL_NOTIFICATION))
            .subscribe(onNext: { [unowned self] notification in
                if let peripheral = notification.userInfo?[BECKON_RESTORE_PERIPHERAL_USER_INFO] as? CBPeripheral {
                    self.restoredPeripheralsSubject.onNext(peripheral)
                }
            }).disposed(by: disposeBag)
        
        // Disconnect on bluetooth off
        self.instance.rx
            .state
            .filter { state in return CBManagerState.poweredOff == state }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .subscribe(onNext: { [unowned self] _ in
                self.connectedDevices.forEach({ [unowned self] (device) in
                    _ = self.instance.rx.cancelPeripheralConnection(device.peripheral)
                })
                self.connectedDevices.removeAll()
                self.pairedDevices.forEach({ (device) in
                    self.disconnect(device: device)
                })
                self.pairedDevices.removeAll()
                self.devicesSubject.onNext([])
            }).disposed(by: disposeBag)
        
        // Main connection loop
        self.instance.rx
            .state
            .filter { state in return CBManagerState.poweredOn == state }
            .distinctUntilChanged()
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .flatMapLatest { [unowned self] _ in return self.rescanSubject.asObservable() }
            .flatMapLatest({ [unowned self] _ -> Observable<CBPeripheral> in
                let devices = self.settingsStore.getSavedDevices()
                
                var peripherals = Set<CBPeripheral>()
                self.instance.retrievePeripherals(withIdentifiers: devices.map { $0.uuid }).forEach { peripherals.insert($0) }
                if let delegate = self.delegate, let services = delegate.services() {
                    self.instance.retrieveConnectedPeripherals(withServices: services.map { $0.uuid }).forEach { peripherals.insert($0) }
                    
                    return Observable.merge(Observable.from(peripherals.map { $0 }),
                                            self.instance.rx.scanForPeripherals(withServices: services.map { $0.uuid }).filter { self.delegate?.isPairable(advertisementData: $0.data) ?? false }.map { dp in dp.peripheral }, self.restoredPeripheralsSubject)
                }
                return Observable.merge(Observable.from(peripherals.map { $0 }),
                                        self.instance.rx.scanForPeripherals(withServices: nil).filter { self.delegate?.isPairable(advertisementData: $0.data) ?? false }.map { dp in dp.peripheral }, self.restoredPeripheralsSubject)
                
            })
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .filter { [unowned self] peripheral in
                // This is probably kinda slow
                return (self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(peripheral.identifier)
            }
            .do(onNext: { p in
                print("willConnect: \(p)")
            })
            .flatMap { [unowned self] peripheral -> Single<CBPeripheral> in
                if peripheral.state == CBPeripheralState.connected {
                    return Single.just(peripheral)
                } else {
                    return self.instance.rx.connect(peripheral)
                }
            }
            .do(onNext: { p in
                print("hasConnected: \(p)")
            })
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .filter({ (peripheral) -> Bool in
                !self.pairedDevices.contains(where: { (device) -> Bool in
                    device.peripheral == peripheral
                })
            })
            .subscribe(onNext: { [weak self] peripheral in
                if let device = Device(peripheral: peripheral), let self = self {
                    self.pairedDevices.removeAll(where: { (pairedDevice) -> Bool in
                        pairedDevice.peripheral.identifier == device.peripheral.identifier
                    })
                    self.pairedDevices.append(device)
                    self.devicesSubject.onNext(self.pairedDevices)
                }
            }).disposed(by: disposeBag)
        
        // Clean up when losing connection
        self.devicesSubject.flatMapLatest { devices in
            Observable.from(devices)
            }
            .flatMap { device in
                device.peripheral.rx.state.map { return (device, $0) }
            }
            .filter { _, state in state == CBPeripheralState.disconnected }
            .flatMapLatest { device, _ -> Observable<Device> in
                return Observable.just(device)
            }
            .filter { $0.peripheral.state == .disconnected }
            .delay(1.0, scheduler: ConcurrentMainScheduler.instance)
            .map { [unowned self] device in
                // NOTE: Side effects
                self.disconnect(device: device)
            }.subscribe().disposed(by: disposeBag)
        
        //        rescanSubject.onNext(1)
        devicesSubject.onNext([])
    }
    
    /**
     Search for any pairable devices according to the BeckonDescriptor.
     
     Subscribe to this and save any devices you want to add to your runloop
     using `Beckon.settingsStore.saveDevice(_)`.
    */
    public func search() -> Observable<Device> {
        return self.instance.rx
            .state
            .filter { state in return (CBManagerState.poweredOn == state) }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .flatMapLatest { _ in
                self.instance.rx.scanForPeripherals(withServices: self.delegate?.services()?.map { $0.uuid })
            }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .do(onNext: { print("Found \($0), is it pairable?") })
            .filter {
                self.delegate?.isPairable(advertisementData: $0.data) ?? false  } // Entry point for selecting only paired
            .do(onNext: { print($0) }, onCompleted: { print("Completed scanning") })
            .filter { [unowned self] dp in
                // This is probably kinda slow
                return !(self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(dp.peripheral.identifier)
            }
            .flatMap { [unowned self] discovered in
                return self.instance.rx.connect(discovered.peripheral) }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .map { peripheral in
                return Device(peripheral: peripheral)
            }
            .flatMapLatest({ device -> Observable<Device> in
                return device.map {
                    self.connectedDevices.append($0)
                    return Observable.just($0)
                    } ?? Observable.empty()
            })
    }
    
    /**
     Disconnect from all devices found while searching for new devices.
    */
    public func stopSearch() {
        self.connectedDevices.forEach({ [unowned self] (device) in
            self.disconnect(device: device)
        })
        self.connectedDevices.removeAll()
        //        self.instance.stopScan()
    }
}

open class BeckonDevice<State>: NSObject, Disposable where State: BeckonState  {
    static func == (lhs: BeckonDevice, rhs: BeckonDevice) -> Bool {
        return lhs.peripheral == rhs.peripheral
    }
    
    public let peripheral: CBPeripheral
    
    public var deviceIdentifier: UUID {
        return peripheral.identifier
    }
    
    public var services: [CBUUID: (BluetoothServiceUUID, CBService)] = [:]
    public var characteristics: [CBUUID: (BluetoothCharacteristicUUID, CBCharacteristic)] = [:]
    
    private let disposeBag = DisposeBag()
    private var latestState: State = State.defaultState
    
    required public init?(peripheral: CBPeripheral) {
        
        self.peripheral = peripheral
        super.init()
        
        self.state.subscribe(onNext: { [weak self] state in
            self?.latestState = state
        }).disposed(by: disposeBag)
    }
    
    private var deviceStateSubject: ReplaySubject<State>! = ReplaySubject.create(bufferSize: 1)
    private var connectedDeviceState: Disposable? = nil
    
    private var bindings: Bindings<BluetoothCharacteristicUUID>! = nil
    
    public private(set) lazy var state: Observable<State>! = {
        let x = Observable.system(
            initialState: State.defaultState,
            reduce: { [unowned self] in self.reducer(characteristicID: $1, oldState: $0) },
            scheduler: MainScheduler.instance,
            scheduledFeedback: RxFeedback.bind { [unowned self] state in
                let bindings = Bindings(subscriptions: [Disposable](), mutations: self.subscriptions())
                self.bindings = bindings
                return bindings
            }
            ).multicast(self.deviceStateSubject)
        self.connectedDeviceState = x.connect()
        return x
    }()
    
    private func subscriptions() -> [Observable<BluetoothCharacteristicUUID>] {
        return characteristics.map { (arg) -> Observable<BluetoothCharacteristicUUID> in
            let (_, (id, _)) = arg
            let uuidString = id.uuid.uuidString
            
            if id.notify {
                _ = peripheral.rx.setNotifyValue(true, for: id, with: PriorityInfo(tag: "notify.\(uuidString)", priority: Operation.QueuePriority.normal)).subscribe()
            }
            _ = peripheral.rx.readValue(for: id, with: PriorityInfo(tag: "read.\(uuidString)", priority: Operation.QueuePriority.normal)).subscribe()
            
            return self.peripheral.rx.watchValue(for: id, with: PriorityInfo(tag: "watch.\(uuidString)", priority: Operation.QueuePriority.normal))
                .map { _ in
                    return id
                }.do(onSubscribe: { print("Watching \(uuidString)") }, onDispose: { print("Stopped watching \(uuidString)") })
        }
    }
    
    open func reducer(characteristicID: BluetoothCharacteristicUUID, oldState: State) -> State {
        return oldState
    }
    
    deinit {
        dispose()
    }
    
    public func dispose() {
        connectedDeviceState?.dispose()
        connectedDeviceState = nil
        
        deviceStateSubject?.onCompleted()
        bindings?.dispose()
        
        deviceStateSubject = nil
        bindings = nil
    }
}

public protocol BeckonDescriptor: class {
    func services() -> [BluetoothServiceUUID]?
    func characteristics() -> [BluetoothCharacteristicUUID]
    func isPairable(advertisementData: AdvertisementData) -> Bool
}

public protocol BeckonState {
    static var defaultState: Self { get }
}
