//
//  CBPeripheral+Rx.swift
//  Beckon
//
//  Created by Ville Petersson on 2019-04-02.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
//

import UIKit
import CoreBluetooth
import RxSwift
import RxCocoa

extension CBPeripheral: HasDelegate {
    public typealias Delegate = CBPeripheralDelegate
}

struct PriorityInfo {
    let tag: String
    let priority: Operation.QueuePriority
    let timeout: Double
    let retries: Int
    let maxInstances: Int?
    
    init(tag: String, priority: Operation.QueuePriority, timeout: Double = 0.5, retries: Int = 0, maxInstances: Int? = nil) {
        self.tag = tag
        self.priority = priority
        self.timeout = timeout
        self.retries = retries
        self.maxInstances = maxInstances
    }
}

class BluetoothAction: Operation {
    private var bag: DisposeBag! = DisposeBag()
    
    let info: PriorityInfo
    let action: () -> Void
    let waitUntil: Completable
    
    init(info: PriorityInfo, action: @escaping () -> Void, waitUntil: Completable) {
        self.info = info
        self.action = action
        self.waitUntil = waitUntil
        
        super.init()
        
        self.queuePriority = info.priority
    }
    
    enum State {
        case notStarted
        case cancelled
        case executing
        case finished
        case error(Error)
    }
    
    private var state: State = .notStarted
    
    override func start() {
        if isCancelled {
            return
        }
        
        self.state = .executing
        
        self.waitUntil.do(onSubscribed: {
            print("ACTION: \(self.info.tag)")
            self.action()
        })
            .timeout(self.info.timeout, scheduler: ConcurrentMainScheduler.instance)
            .retry(self.info.retries)
            .subscribe(onCompleted: { [weak self] in
                self?.state = .finished
                }, onError: { [weak self] err in
                    self?.state = .error(err)
            })
            .disposed(by: bag)
    }
    
    override func cancel() {
        self.state = .cancelled
        bag = nil
    }
    
    dynamic override var isExecuting: Bool {
        switch state {
        case .executing:
            return true
        default:
            return false
        }
    }
    
    dynamic override var isFinished: Bool {
        switch state {
        case .cancelled, .finished, .error(_):
            return true
        default:
            return false
        }
    }
    
    dynamic override var isCancelled: Bool {
        switch state {
        case .cancelled:
            return true
        default:
            return false
        }
    }
}

internal class BluetoothQueue {
    private let dispatchQueue = DispatchQueue(label: "BluetoothQueue-\(UUID.init())")
    let operationQueue = OperationQueue()
    
    init() {
        operationQueue.underlyingQueue = dispatchQueue
    }
    
    private var isTerminating = false
    
    func add(action: BluetoothAction) {
        if isTerminating {
            return
        }
        
        if let i = action.info.maxInstances {
            let c = operationQueue.operations.reduce(0, { acc, cur in
                guard let opAction = cur as? BluetoothAction else {
                    return acc
                }
                
                if action.info.tag == opAction.info.tag {
                    if !opAction.isCancelled {
                        return acc + 1
                    }
                }
                
                return acc
            })
            
            if c >= i {
                var cancelled = 0
                for op in operationQueue.operations {
                    if cancelled == c - i + 1 {
                        break
                    }
                    
                    guard let opAction = op as? BluetoothAction else {
                        continue
                    }
                    
                    if action.info.tag == opAction.info.tag {
                        if !opAction.isCancelled {
                            opAction.cancel()
                            cancelled += 1
                        }
                    }
                }
            }
        }
        
        operationQueue.addOperation(action)
    }
    
    func terminate() {
        if isTerminating {
            return
        }
        isTerminating = true
        operationQueue.cancelAllOperations()
    }
}

class RxCBPeripheralDelegateProxy: DelegateProxy<CBPeripheral, CBPeripheralDelegate>, DelegateProxyType, CBPeripheralDelegate {
    public init(peripheral: CBPeripheral) {
        super.init(parentObject: peripheral, delegateProxy: RxCBPeripheralDelegateProxy.self)
    }
    
    public static func registerKnownImplementations() {
        self.register { RxCBPeripheralDelegateProxy(peripheral: $0) }
    }
    
    internal lazy var queue = BluetoothQueue()
    
    internal lazy var didDiscoverServicesSubject = PublishSubject<([CBService], Error?)>()
    internal lazy var didDiscoverCharacteristicsSubject = PublishSubject<(CBService, Error?)>()
    internal lazy var didUpdateValueSubject = PublishSubject<(CBCharacteristic, Error?)>()
    internal lazy var didWriteValueCharacteristicSubject = PublishSubject<(CBCharacteristic, Error?)>()
    internal lazy var didUpdateNotificationStateSubject = PublishSubject<(CBCharacteristic, Error?)>()
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debug("[Proxy] Peripheral didDiscoverServices: \(peripheral.identifier)")
        
        trace("[Proxy] peripheral(\(peripheral.identifier)) didDiscoverServices")
        peripheral.services?.forEach {
            trace("[Proxy] peripheral(\(peripheral.identifier)) service: \($0)")
        }
        _forwardToDelegate?.peripheral?(peripheral, didDiscoverServices: error)
        DispatchQueue.main.async {
            self.didDiscoverServicesSubject.onNext((peripheral.services ?? [], error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        debug("[Proxy] Peripheral didDiscoverCharacteristicsFor: \(peripheral.identifier)")
        
        trace("[Proxy] peripheral(\(peripheral.identifier)) didDiscoverCharacteristicsFor(\(service.uuid))")
        service.characteristics?.forEach {
            trace("[Proxy] peripheral(\(peripheral.identifier)) characteristic: \($0)")
        }
        //        let characteristics = service.characteristics ?? []
        
        DispatchQueue.main.async {
            self._forwardToDelegate?.peripheral?(peripheral, didDiscoverCharacteristicsFor: service, error: error)
            self.didDiscoverCharacteristicsSubject.onNext((service, error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        debug("[Proxy] Peripheral: \(peripheral.identifier) didUpdateValueFor: \(characteristic.uuid)")
        
        DispatchQueue.main.async {
            self._forwardToDelegate?.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
            self.didUpdateValueSubject.onNext((characteristic, error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debug("[Proxy] Peripheral: \(peripheral.identifier) didWriteValueFor: \(characteristic.uuid)")
        DispatchQueue.main.async {
            self._forwardToDelegate?.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
            self.didWriteValueCharacteristicSubject.onNext((characteristic, error))
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        debug("[Proxy] Peripheral: \(peripheral.identifier) didUpdateNotificationStateFor: \(characteristic.uuid)")
        DispatchQueue.main.async {
            self._forwardToDelegate?.peripheral?(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
            self.didUpdateNotificationStateSubject.onNext((characteristic, error))
        }
    }
    
    deinit {
        didDiscoverServicesSubject.on(.completed)
        didDiscoverCharacteristicsSubject.on(.completed)
        didUpdateValueSubject.on(.completed)
        didWriteValueCharacteristicSubject.on(.completed)
        didUpdateNotificationStateSubject.on(.completed)
        
        queue.terminate()
    }
}

extension Reactive where Base: CBPeripheral {
    public var delegate: DelegateProxy<CBPeripheral, CBPeripheralDelegate> {
        return RxCBPeripheralDelegateProxy.proxy(for: base)
    }
    
    public var state: Observable<CBPeripheralState> {
        return base.rx.observe(CBPeripheralState.self, "state")
            .observeOn(MainScheduler.instance)
            .flatMapLatest { (state: CBPeripheralState?) -> Observable<CBPeripheralState> in
                guard let state = state else {
                    return Observable.empty()
                }
                return Observable.just(state)
        }
    }
    
    //    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID]?, for service: CBService) -> Single<[CBCharacteristic]> {
    func discoverCharacteristics(for service: CBService) -> Single<[CBCharacteristic]> {
        debug("[discoverCharacteristics] Called discoverCharacteristics: \(self.base.name!)")
        
        if let characteristics = service.characteristics {
            debug("[discoverCharacteristics] Returning cached characteristics: \(self.base.name!)")
            return Single.just(characteristics)
        }
        
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didDiscoverCharacteristicsSubject
            .do(onSubscribe: {
                debug("[discoverCharacteristics] Begin discover characteristics request: \(self.base.name!)")
                self.base.discoverCharacteristics(nil, for: service)
            })
            .filter {
                $0.0.uuid == service.uuid
            }
            .do(onNext: { _ in debug("[discoverCharacteristics] Discover characteristics request completed; values received: \(self.base.name!)") })
            .flatMapLatest({ (tuple) -> Observable<[CBCharacteristic]> in
                if let error = tuple.1 {
                    debug("[discoverCharacteristics] request errored: \(self.base.name!)")
                    return Observable.error(error)
                }
                
                if tuple.0.characteristics == nil {
                    debug("[discoverCharacteristics] EMPTY CHARACTERISTICS!: \(self.base.name!)")
                }
                return Observable.just(tuple.0.characteristics ?? [])
            })
            .take(1)
            .asSingle()
    }
    
    func discoverServices() -> Single<[CBService]> {
        if let services = base.services {
            debug("[discoverServices] Returning cached services")
            return Single.just(services)
        }
        
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didDiscoverServicesSubject
            .onBluetoothQueue()
            .do(onSubscribe: {
                debug("Begin discover services request")
                self.base.discoverServices(nil)
            })
            .take(1)
            .flatMapLatest({ (tuple) -> Observable<[CBService]> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
            .do(onNext: { _ in debug("Discover services request completed; values received") })
            .asSingle()
    }
    
    struct CharacteristicError: Error {
        let message: String
    }
    
    private func characteristic(for characteristicUUID: BluetoothCharacteristicUUID, with info: PriorityInfo) -> Single<CBCharacteristic> {
        let services = base.services
        
        guard let service = services?.first(where: { $0.uuid == characteristicUUID.service.uuid }) else {
            return Single.error(CharacteristicError(message: "No service found for: \(characteristicUUID)"))
        }
        
        let characteristics = service.characteristics
        
        guard let characteristic = characteristics?.first(where: { $0.uuid == characteristicUUID.uuid }) else {
            return Single.error(CharacteristicError(message: "No characteristic found for: \(characteristicUUID)"))
        }
        
        return Single.just(characteristic)
    }
    
    func readValue(for characteristicUUID: BluetoothCharacteristicUUID, with info: PriorityInfo) -> Single<CBCharacteristic> {
        return characteristic(for: characteristicUUID, with: info)
            .flatMap { self.base.rx.readValue(for: $0, with: info) }
            .asObservable()
            .onBluetoothQueue()
            .asSingle()
    }
    
    private func readValue(for characteristic: CBCharacteristic, with info: PriorityInfo) -> Single<CBCharacteristic> {
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didUpdateValueSubject
            .onBluetoothQueue()
            .do(onSubscribe: { self.base.readValue(for: characteristic) })
            .filter({ $0.0.uuid == characteristic.uuid })
            .take(1)
            .flatMap({ (tuple) -> Observable<CBCharacteristic> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
            .asSingle()
    }
    
    func writeValue(data: Data, for characteristicUUID: BluetoothCharacteristicUUID, with info: PriorityInfo) -> Single<CBCharacteristic> {
        return characteristic(for: characteristicUUID, with: info)
            .flatMap { self.base.rx.writeValue(data: data, for: $0, with: info) }
            .asObservable().onBluetoothQueue()
            .filter({ $0.uuid == characteristicUUID.uuid })
            .take(1)
            .asSingle()
    }
    
    private func writeValue(data: Data, for characteristic: CBCharacteristic, with info: PriorityInfo) -> Single<CBCharacteristic> {
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didWriteValueCharacteristicSubject.onBluetoothQueue()
            .do(onSubscribe: { self.base.writeValue(data, for: characteristic, type: .withResponse) })
            .filter({ $0.0.uuid == characteristic.uuid })
            .take(1)
            .flatMapLatest({ (tuple) -> Observable<CBCharacteristic> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
            .asSingle()
    }
    
    private func watchValue(for characteristic: CBCharacteristic, with info: PriorityInfo) -> Observable<CBCharacteristic> {
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didUpdateValueSubject.onBluetoothQueue()
            .filter({ $0.0.uuid == characteristic.uuid })
            .flatMap({ (tuple) -> Observable<CBCharacteristic> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
    }
    
    /// Watch a value subscribed to or otherwise read to
    func watchValue(for characteristicUUID: BluetoothCharacteristicUUID, with info: PriorityInfo) -> Observable<CBCharacteristic> {
        return characteristic(for: characteristicUUID, with: info)
            .asObservable()
            .take(1)
            .flatMapFirst { self.base.rx.watchValue(for: $0, with: info) }
    }
    
    /// Returns evidence of notification being set
    private func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, with info: PriorityInfo) -> Single<CBCharacteristic> {
        return RxCBPeripheralDelegateProxy.proxy(for: self.base)
            .didUpdateNotificationStateSubject
            .onBluetoothQueue()
            .do(onSubscribe: {
                debug("setNotifyValue onSubscribe")
                self.base.setNotifyValue(enabled, for: characteristic)
            })
            .filter({ $0.0.uuid == characteristic.uuid })
            .take(1)
            .flatMapLatest({ (tuple) -> Observable<CBCharacteristic> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
            .asSingle()
    }
    
    func setNotifyValue(_ enabled: Bool, for characteristicUUID: BluetoothCharacteristicUUID, with info: PriorityInfo) -> Observable<CBCharacteristic> {
        let proxy = RxCBPeripheralDelegateProxy.proxy(for: self.base)
        
        return characteristic(for: characteristicUUID, with: info).asObservable().take(1)
            .do(onNext: {
                debug("setNotifyValue withUUID onNext")
                self.base.setNotifyValue(enabled, for: $0)
            })
            .flatMapLatest { _ -> Observable<(CBCharacteristic, Error?)> in
                proxy.didUpdateValueSubject.asObserver()
            }
            .filter({ tuple in
                tuple.0.uuid == characteristicUUID.uuid
            }).onBluetoothQueue()
            .flatMapLatest({ (tuple) -> Observable<CBCharacteristic> in
                if let error = tuple.1 { return Observable.error(error) }
                return Observable.just(tuple.0)
            })
    }
}
