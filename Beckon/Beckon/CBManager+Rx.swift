//
//  CBManager+Rx.swift
//  Beckon
//
//  Created by Ville Petersson on 2019-04-02.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
//

import UIKit
import CoreBluetooth
import RxSwift
import RxCocoa

/**
 Describes a Bluetooth service
 */
public protocol BluetoothServiceUUID {
    var uuid: CBUUID { get }
}

public enum CharacteristicTraits {
    case read
    case notify
    case write
}

/**
 Describes a Bluetooth characteristic
 
 Usually, you want to use one of the existing implementations,
 like `WriteOnlyBluetoothCharacteristicUUID`, `ConvertibleBluetoothCharacteristicUUID`,
 or `CustomBluetoothCharacteristicUUID`.
 */
public protocol BluetoothCharacteristicUUID {
    var uuid: CBUUID { get }
    var service: BluetoothServiceUUID { get }
    var traits: [CharacteristicTraits] { get }
}

/**
 Data types implementing this can autmatically be mapped to or from
 characteristics by Beckon
 
 Implement it on your data types to support writing them to characteristics.
 Because of current limitations, *only the ones implemented by the Beckon framework by
 default can automatically be mapped to keypaths*.
 */
public protocol BeckonMappable {
    func mapper(_ value: Self) throws -> Data
    func mapper(_ data: Data) throws -> Self
}

/**
 Represents a failure to map from value to Data
 */
struct BeckonSerializeError: Error {
    let value: Any
    let mapper: String
}

/**
 Represents a failure to map from Data to value
 */
struct BeckonMapperError: Error {
    let data: Data
    let mapper: String
}

extension Data: BeckonMappable {
    public func mapper(_ data: Data) throws -> Data {
        return data
    }
}

extension Int: BeckonMappable {
    public func mapper(_ value: Int) throws -> Data {
        var value = value
        return Data(bytes: &value, count: MemoryLayout.size(ofValue: value))
    }
    
    public func mapper(_ data: Data) throws -> Int {
        return data.withUnsafeBytes { $0.pointee }
    }
}

extension String: BeckonMappable {
    public func mapper(_ value: String) throws -> Data {
        guard let data = value.data(using: .utf8) else { throw BeckonSerializeError(value: value, mapper: "String") }
        return data
    }
    
    public func mapper(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: String.Encoding.utf8) else { throw BeckonMapperError(data: data, mapper: "String") }
        return string
    }
}

extension Bool: BeckonMappable {
    public func mapper(_ value: Bool) throws -> Data {
        var mut = value
        return Data(bytes: &mut, count: MemoryLayout.size(ofValue: value))
    }
    
    public func mapper(_ data: Data) throws -> Bool {
        return data.first == 1
    }
}

/**
 Use this `BluetoothCharacteristicUUID` for Bluetooth characteristics which only supports writing `BeckonMappable`s
 */
public struct WriteOnlyBluetoothCharacteristicUUID<ValueType>: BluetoothCharacteristicUUID where ValueType: BeckonMappable {
    public var uuid: CBUUID
    public var service: BluetoothServiceUUID
    public var traits: [CharacteristicTraits] = [.write]
    
    public init(uuid: CBUUID, service: BluetoothServiceUUID) {
        self.uuid = uuid
        self.service = service
    }
}

/**
 Use this `BluetoothCharacteristicUUID` for Bluetooth characteristics which maps 1:1 with `BeckonMappable` properties
 on your state using a keypath on your state
 */
public struct ConvertibleBluetoothCharacteristicUUID<ValueType, State>: BluetoothCharacteristicUUID where ValueType: BeckonMappable, State: BeckonState {
    
    public var uuid: CBUUID
    public var service: BluetoothServiceUUID
    public var traits: [CharacteristicTraits]
    
    public var keypath: WritableKeyPath<State, ValueType>
    
    public init(uuid: CBUUID, service: BluetoothServiceUUID, traits: [CharacteristicTraits], keyPath: WritableKeyPath<State, ValueType>) {
        self.uuid = uuid
        self.service = service
        self.traits = traits
        self.keypath = keyPath
    }
}

/**
 Use this `BluetoothCharacteristicUUID` for Bluetooth characteristics where you need
 custom mapping from raw Data to your updated state.
 */
public struct CustomBluetoothCharacteristicUUID<State>: BluetoothCharacteristicUUID where State: BeckonState {
    public var uuid: CBUUID
    public var service: BluetoothServiceUUID

    public var traits: [CharacteristicTraits]
    
    var mapper: ((Data, State) -> State)
    
    public init(uuid: CBUUID, service: BluetoothServiceUUID, traits: [CharacteristicTraits], mapper: @escaping ((Data, State) -> State)) {
        self.uuid = uuid
        self.service = service
        self.traits = traits
        self.mapper = mapper
    }
}

public struct AdvertisementData {
    public let services: [CBUUID]
    public let name: String?
}

public struct DiscoveredPeripheral {
    let peripheral: CBPeripheral
    let data: AdvertisementData
    let rssi: NSNumber
}

extension CBCentralManager: HasDelegate {
    public typealias Delegate = CBCentralManagerDelegate
}

let debugOutput: Bool = false
internal func debug(_ output: String) {
    if !debugOutput {
        return
    }
    print("debug [RxBT]: \(output)")
}

let traceOutput: Bool = false
internal func trace(_ output: String) {
    if !traceOutput {
        return
    }

    print("trace [RxBT]: \(output)")
}

class RxCBCentralManagerDelegateProxy: DelegateProxy<CBCentralManager, CBCentralManagerDelegate>, DelegateProxyType, CBCentralManagerDelegate {
    public init(manager: CBCentralManager) {
        super.init(parentObject: manager, delegateProxy: RxCBCentralManagerDelegateProxy.self)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: {
            self.didUpdateStateSubject.onNext(manager.state)
        })
    }
    
    public static func registerKnownImplementations() {
        self.register {
            RxCBCentralManagerDelegateProxy(manager: $0)
        }
    }
    
    internal lazy var didUpdateStateSubject = ReplaySubject<CBManagerState>.create(bufferSize: 1)
    internal lazy var didDiscoverSubject = PublishSubject<DiscoveredPeripheral>()
    internal lazy var didConnectSubject = PublishSubject<CBPeripheral>()
    internal lazy var didDisconnectSubject = PublishSubject<(CBPeripheral, Error?)>()
    
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripheralsObject = dict[CBCentralManagerRestoredStatePeripheralsKey] {
            DispatchQueue.main.async {
                let peripherals = peripheralsObject as! Array<CBPeripheral>
                
                for peripheral in peripherals {
                    debug("[Proxy] didRestore: \(peripheral.identifier)")
                    self.didConnectSubject.onNext(peripheral)
                }
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debug("[Proxy] didUpdateState: \(central.state.rawValue)")
        
        DispatchQueue.main.async {
            self._forwardToDelegate?.centralManagerDidUpdateState?(central)
            self.didUpdateStateSubject.onNext(central.state)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        debug("[Proxy] didDiscover: \(peripheral.identifier)")
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let data = AdvertisementData(services: services, name: advertisedName)
        let discovered = DiscoveredPeripheral(peripheral: peripheral, data: data, rssi: RSSI)
        
        DispatchQueue.main.async {
            self._forwardToDelegate?.centralManager?(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
            self.didDiscoverSubject.onNext(discovered)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        debug("[Proxy] didConnect: \(peripheral.identifier)")
        
        DispatchQueue.main.async {
            self._forwardToDelegate?.centralManager?(central, didConnect: peripheral)
            self.didConnectSubject.onNext(peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debug("[Proxy] didDisconnect: \(peripheral.identifier)")
        DispatchQueue.main.async {
            self._forwardToDelegate?.centralManager?(central, didDisconnectPeripheral: peripheral, error: error)
            self.didDisconnectSubject.onNext((peripheral, error))
        }
    }
    
    deinit {
        didUpdateStateSubject.onCompleted()
        didDiscoverSubject.onCompleted()
        didConnectSubject.onCompleted()
        didDisconnectSubject.onCompleted()
    }
}

extension CBPeripheralState: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .connected: return ".connected"
        case .connecting: return ".connecting"
        case .disconnected: return ".disconnected"
        case .disconnecting: return ".disconnecting"
        }
    }
}

extension CBManagerState: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .poweredOff:
            return ".poweredOff"
        case .poweredOn:
            return ".poweredOn"
        case .resetting:
            return ".resetting"
        case .unauthorized:
            return ".unauthorized"
        case .unknown:
            return ".unknown"
        case .unsupported:
            return ".unsupported"
        }
    }
}

fileprivate func internalHydrate(_ peripheral: CBPeripheral) -> Single<CBPeripheral> {
    return Single.just(peripheral)
        .flatMap { (peripheral: CBPeripheral) -> Single<([CBService], CBPeripheral)> in
            trace("[Manager] Hydrating peripheral \(peripheral.name ?? peripheral.debugDescription)")
            if let services = peripheral.services, services.count > 0 {
                trace("[Manager] Already hydrated services")
                return Single.just((services, peripheral))
            } else {
                return peripheral.rx.discoverServices().map { ($0, peripheral) }
            }
        }
        .flatMap { (tuple: ([CBService], CBPeripheral)) -> Single<CBPeripheral> in
            let services = tuple.0
            let peripheral = tuple.1
            
            trace("[Manager] connect has received new discovered services for peripheral: \(peripheral.name!)")
            return Observable.from(services).map { service -> Single<[CBCharacteristic]> in
                    if let characteristics = service.characteristics, characteristics.count > 0 {
                        trace("[Manager] Already hydrated characteristics")
                        return Single.just(characteristics)
                    } else {
                        return peripheral.rx.discoverCharacteristics(for: service)
                    }
                }
                .merge()
                .toArray()
                .filter { $0.count == services.count }
                .map { _ in peripheral }
                .asSingle()
        }
        .do(onSuccess: { peripheral in
            trace("[Manager] hydrate has received discovered characteristics for peripheral: \(peripheral.name!)")
        })
}

extension Reactive where Base: CBCentralManager {
    public var delegate: DelegateProxy<CBCentralManager, CBCentralManagerDelegate> {
        return RxCBCentralManagerDelegateProxy.proxy(for: base)
    }
    
    internal func hydrate(_ peripheral: CBPeripheral) -> Single<CBPeripheral> {
        return internalHydrate(peripheral)
    }
    
    public func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) -> Single<CBPeripheral> {
        trace("[Manager] connect: \(peripheral.identifier)")
        let proxy = RxCBCentralManagerDelegateProxy.proxy(for: self.base)
        let status: Single<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn }).take(1).asSingle()
        
        let connection = status
//            .onBluetoothQueue()
            .flatMap { status -> Single<CBPeripheral> in
                trace("[Manager] Status trigger: \(status)")
                return proxy.didConnectSubject
//                    .onBluetoothQueue()
                    .do(
                        onNext: { peripheral in
                            trace("[Manager] connect flat map received new peripheral: \(peripheral.name!)")
                        }, onSubscribe: {
                            trace("[Manager] connect request to real CBCentralManager starting")
                            DispatchQueue.main.async {
                                self.base.connect(peripheral, options: options)
                            }
                        }
                    )
                    .filter { $0.identifier == peripheral.identifier }
                    .take(1)
                    .asSingle()
                    .do(onSuccess: { peripheral in
                        trace("[Manager] connect has a peripheral: \(peripheral.name!), state: \(peripheral.state)")
                    })
            }
            // Start the part where we parallelise getting the characteristics from the services
            .flatMap({ x -> Single<CBPeripheral> in internalHydrate(x) })
            .do(onSuccess: { peripheral in
                trace("[Manager] connect has received discovered characteristics for peripheral: \(peripheral.name!)")
            }, onError: { err in
                trace("[Manager] connect resulted in error \(err)")
            })
        return connection
    }
    
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) -> Single<CBPeripheral> {
        debug("cancelPeripheralConnection")
        let proxy = RxCBCentralManagerDelegateProxy.proxy(for: self.base)
        let status: Observable<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn }).take(1)
        
        return status.flatMap { _ -> Observable<(CBPeripheral, Error?)> in
            return proxy.didDisconnectSubject
                .do(onSubscribe: {
                    debug("onSubscribe cancelPeripheralConnection")
                    self.base.cancelPeripheralConnection(peripheral)
                })
            }
            .onBluetoothQueue()
            .filter({ $0.0.identifier == peripheral.identifier })
            .take(1)
            .flatMap({ (tuple) -> Observable<CBPeripheral> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
            .asSingle()
    }
    
    public func scanForPeripherals(withServices services: [CBUUID]? = nil) -> Observable<DiscoveredPeripheral> {
        debug("scanForPeripherals")
        let proxy = RxCBCentralManagerDelegateProxy.proxy(for: self.base)
        let status: Observable<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn }).take(1)
        
        return status.flatMap { _ -> Observable<DiscoveredPeripheral> in
            return proxy.didDiscoverSubject.do(onSubscribe: {
                debug("onSubscribe scanForPeripherals")
                self.base.scanForPeripherals(withServices: services)
            })
            }.do(onCompleted: {
                debug("onCompleted stopScan")
                self.base.stopScan()
            })
            .onBluetoothQueue()
    }
    
    var state: Observable<CBManagerState> {
        return RxCBCentralManagerDelegateProxy.proxy(for: self.base)
            .didUpdateStateSubject.asObservable()
    }
}
