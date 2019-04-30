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

public protocol BluetoothServiceUUID {
    var uuid: CBUUID { get }
}

public enum CharacteristicTraits {
    case read
    case notify
    case write
}

public protocol BluetoothCharacteristicUUID {
    var uuid: CBUUID { get }
    var service: BluetoothServiceUUID { get }
    var traits: [CharacteristicTraits] { get }
}

public protocol BeckonMappable {
    func mapper(_ data: Data) throws -> Self
}

struct BeckonMapperError: Error {
    let data: Data
    let mapper: String
}

extension Int: BeckonMappable {
    public func mapper(_ data: Data) throws -> Int {
        return data.withUnsafeBytes { $0.pointee }
    }
}

extension String: BeckonMappable {
    public func mapper(_ data: Data) throws -> String {
        guard let string = String(data: data, encoding: String.Encoding.utf8) else { throw BeckonMapperError(data: data, mapper: "String") }
        return string
    }
}

extension Bool: BeckonMappable {
    public func mapper(_ data: Data) throws -> Bool {
        return data.first == 1
    }
}

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

public struct CustomBluetoothCharacteristicUUID<State>: BluetoothCharacteristicUUID where State: BeckonState {
    public var uuid: CBUUID
    public var service: BluetoothServiceUUID

    public var traits: [CharacteristicTraits]
    
    var mapper: ((Data, State) -> State)
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
            let peripherals = peripheralsObject as! Array<CBPeripheral>
            for peripheral in peripherals {
                debug("[Proxy] didRestore: \(peripheral.identifier)")
                didConnectSubject.onNext(peripheral)
            }
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debug("[Proxy] didUpdateState: \(central.state.rawValue)")
        _forwardToDelegate?.centralManagerDidUpdateState?(central)
        
        didUpdateStateSubject.onNext(central.state)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        _forwardToDelegate?.centralManager?(central, didDiscover: peripheral, advertisementData: advertisementData, rssi: RSSI)
        
        debug("[Proxy] didDiscover: \(peripheral.identifier)")
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let data = AdvertisementData(services: services, name: advertisedName)
        let discovered = DiscoveredPeripheral(peripheral: peripheral, data: data, rssi: RSSI)
        didDiscoverSubject.onNext(discovered)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        _forwardToDelegate?.centralManager?(central, didConnect: peripheral)
        
        debug("[Proxy] didConnect: \(peripheral.identifier)")
        didConnectSubject.onNext(peripheral)
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        _forwardToDelegate?.centralManager?(central, didDisconnectPeripheral: peripheral, error: error)
        
        debug("[Proxy] didDisconnect: \(peripheral.identifier)")
        didDisconnectSubject.onNext((peripheral, error))
    }
    
    deinit {
        didUpdateStateSubject.onCompleted()
        didDiscoverSubject.onCompleted()
        didConnectSubject.onCompleted()
        didDisconnectSubject.onCompleted()
    }
}


extension Reactive where Base: CBCentralManager {
    public var delegate: DelegateProxy<CBCentralManager, CBCentralManagerDelegate> {
        return RxCBCentralManagerDelegateProxy.proxy(for: base)
    }
    
    public func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) -> Single<CBPeripheral> {
        trace("[Manager] connect: \(peripheral.identifier)")
        let proxy = RxCBCentralManagerDelegateProxy.proxy(for: self.base)
        let status: Observable<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn })
        
        return status
            .observeOn(MainScheduler.instance)
            .subscribeOn(MainScheduler.instance) // Dont add
            .flatMapLatest { status -> Observable<CBPeripheral> in
                trace("[Manager] Status trigger: \(status)")
                return proxy.didConnectSubject
                    .observeOn(MainScheduler.instance)
                    //                            .subscribeOn(MainScheduler.instance) // Dont add
                    .do(onNext: { peripheral in
                        trace("[Manager] connect flat map received new peripheral: \(peripheral.identifier)")
                    }, onSubscribe: {
                        trace("[Manager] connect request to real CBCentralManager starting")
                        self.base.connect(peripheral, options: options)
                    })
                    .filter { $0.identifier == peripheral.identifier }
                    .do(onNext: { peripheral in
                        trace("[Manager] connect has a peripheral: \(peripheral.identifier), state: \(peripheral.state)")
                    })
                    .filter { $0.state == .connected }
                    .do(onNext: { peripheral in
                        trace("[Manager] connect request has returned a connected peripheral: \(peripheral.identifier)")
                    })
                    .take(1)
            }
            .flatMapLatest { (peripheral: CBPeripheral) -> Observable<([CBService], CBPeripheral)> in
                return peripheral.rx.discoverServices()
                    .observeOn(MainScheduler.instance)
                    //                        .subscribeOn(MainScheduler.instance) // Dont add
                    .asObservable()
                    .map { ($0, peripheral) }
            }
            .flatMapLatest { (tuple: ([CBService], CBPeripheral)) -> Observable<CBPeripheral> in
                let services = tuple.0
                let peripheral = tuple.1
                
                trace("[Manager] connect has received new discovered services for peripheral: \(peripheral.identifier)")
                
                return Observable.from(services.map { peripheral.rx.discoverCharacteristics(for: $0).asObservable() })
                    .merge()
                    .toArray()
                    .map { _ in peripheral }
            }
            .filter({ $0.identifier == peripheral.identifier })
            .do(onNext: { peripheral in
                trace("[Manager] connect has received discovered characteristics for peripheral: \(peripheral.identifier)")
            })
            .take(1)
            .asSingle()
    }
    
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) -> Single<CBPeripheral> {
        debug("cancelPeripheralConnection")
        let proxy = RxCBCentralManagerDelegateProxy.proxy(for: self.base)
        let status: Observable<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn })
        
        return status.flatMap { _ -> Observable<(CBPeripheral, Error?)> in
            return proxy.didDisconnectSubject
                .do(onSubscribe: {
                    debug("onSubscribe cancelPeripheralConnection")
                    self.base.cancelPeripheralConnection(peripheral)
                })
            }
            .observeOn(MainScheduler.instance)
            //            .subscribeOn(MainScheduler.instance) // Dont add
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
        let status: Observable<CBManagerState> = proxy.didUpdateStateSubject.filter({ $0 == .poweredOn })
        
        return status.flatMap { _ -> Observable<DiscoveredPeripheral> in
            return proxy.didDiscoverSubject.do(onSubscribe: {
                debug("onSubscribe scanForPeripherals")
                self.base.scanForPeripherals(withServices: services)
            })
            }.do(onCompleted: {
                debug("onCompleted stopScan")
                self.base.stopScan()
            })
            .observeOn(MainScheduler.instance)
        //                .subscribeOn(MainScheduler.instance) // Dont add
    }
    
    var state: Observable<CBManagerState> {
        return RxCBCentralManagerDelegateProxy.proxy(for: self.base)
            .didUpdateStateSubject.asObservable()
    }
}
