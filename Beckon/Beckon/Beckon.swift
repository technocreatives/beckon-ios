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
                    self.disconnect(device: device.deviceIdentifier)
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
                if let services = self.delegate.services {
                    self.instance.retrieveConnectedPeripherals(withServices: services.map { $0.uuid }).forEach { peripherals.insert($0) }
                    
                    return Observable.merge(Observable.from(peripherals.map { $0 }),
                                            self.instance.rx.scanForPeripherals(withServices: services.map { $0.uuid }).filter { self.delegate.isPairable(advertisementData: $0.data) }.map { dp in dp.peripheral }, self.restoredPeripheralsSubject)
                }
                return Observable.merge(Observable.from(peripherals.map { $0 }),
                                        self.instance.rx.scanForPeripherals(withServices: nil).filter { self.delegate.isPairable(advertisementData: $0.data) }.map { dp in dp.peripheral }, self.restoredPeripheralsSubject)
                
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
                if let self = self, let device = Device(peripheral: peripheral, descriptor: self.delegate) {
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
                self.disconnect(device: device.deviceIdentifier)
            }.subscribe().disposed(by: disposeBag)
        
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
        return self.instance.rx
            .state
            .filter { state in return (CBManagerState.poweredOn == state) }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .flatMapLatest { _ in
                self.instance.rx.scanForPeripherals(withServices: self.delegate.services?.map { $0.uuid })
            }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .do(onNext: { print("Found \($0), is it pairable?") })
            .filter {
                self.delegate.isPairable(advertisementData: $0.data)  } // Entry point for selecting only paired
            .do(onNext: { print($0) }, onCompleted: { print("Completed scanning") })
            .filter { [unowned self] dp in
                // This is probably kinda slow
                return !(self.settingsStore.getSavedDevices()).map { $0.uuid }.contains(dp.peripheral.identifier)
            }
            .flatMap { [unowned self] discovered in
                return self.instance.rx.connect(discovered.peripheral) }
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance)
            .map { [unowned self] peripheral in
                return Device(peripheral: peripheral, descriptor: self.delegate)
            }
            .flatMapLatest({ device -> Observable<Device> in
                return device.map {
                    self.connectedDevices.append($0)
                    return Observable.just($0)
                    } ?? Observable.empty()
            })
            .map {
                return DiscoveredDevice(uuid: $0.deviceIdentifier)
            }
    }
    
    /**
     Disconnect from all devices found while searching for new devices.
    */
    public func stopSearch() {
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
        
        self.peripheral = peripheral
        
        let characteristicIDs = descriptor.characteristics
        
        for cbService in peripheral.services ?? [] {
            
            let serviceCharacteristics = cbService.characteristics ?? []
            
            for cbCharacteristic in serviceCharacteristics {
                if let characteristicID = characteristicIDs.first(where: { characteristicUUID in characteristicUUID.uuid.uuidString == cbCharacteristic.uuid.uuidString }) {
                    self.services[cbService.uuid] = (characteristicID.service, cbService)

                    self.characteristics[characteristicID.uuid] = (characteristicID, cbCharacteristic)
                }
            }
        }
        
        super.init()
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
        
        return characteristics
            .filter { char in char.value.0.traits.contains(where: { trait in trait == .notify || trait == .read }) }
            .map { (arg) -> Observable<BluetoothCharacteristicUUID> in
            let (_, (id, _)) = arg
            let uuidString = id.uuid.uuidString
            
            if id.traits.contains(.notify) {
                _ = peripheral.rx.setNotifyValue(true, for: id, with: PriorityInfo(tag: "notify.\(uuidString)", priority: Operation.QueuePriority.normal)).subscribe()
            }
            if id.traits.contains(.read) {
                _ = peripheral.rx.readValue(for: id, with: PriorityInfo(tag: "read.\(uuidString)", priority: Operation.QueuePriority.normal)).subscribe()
            }
            
            return self.peripheral.rx.watchValue(for: id, with: PriorityInfo(tag: "watch.\(uuidString)", priority: Operation.QueuePriority.normal))
                .map { _ in
                    return id
                }.do(onSubscribe: { print("Watching \(uuidString)") }, onDispose: { print("Stopped watching \(uuidString)") })
        }
    }
    
    func updateCharacteristic(_ uuid: CBUUID) {
        guard let id = self.characteristics[uuid]?.0 else {
            return
        }
        let uuidString = id.uuid.uuidString
        _ = peripheral.rx.readValue(for: id, with: PriorityInfo(tag: "read.\(uuidString)", priority: Operation.QueuePriority.normal)).subscribe()
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
            return oldState
        }
        
        // Custom mappers
        if let custom = characteristicID as? CustomBluetoothCharacteristicUUID<State> {
            return custom.mapper(data, oldState)
        }
        
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

public struct BeckonWriteResponse {}

public struct BeckonInvalidCharacteristicError: Error {}
public struct BeckonNoSuchDeviceError: Error {}

/**
 Describes your bluetooth device.
 */
public protocol BeckonDescriptor: class {
    var services: [BluetoothServiceUUID]? { get }
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

let observeQueue = MainScheduler.instance
let subscribeQueue = ConcurrentMainScheduler.instance

extension ObservableType {
    public func onBluetoothQueue() -> Observable<E> {
        return self.observeOn(observeQueue)
            .subscribeOn(subscribeQueue)
    }
}
