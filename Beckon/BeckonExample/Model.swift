//
//  Model.swift
//  BeckonExample
//
//  Created by Ville Petersson on 2019-04-29.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
//

import Foundation
import Beckon
import CoreBluetooth

enum ExampleServices: String, BluetoothServiceUUID {
    var uuid: CBUUID {
        return CBUUID(string: self.rawValue.uppercased())
    }
    
    case main = "FFF0"
}

enum ExampleCharacteristicIdentifiers: String {
    var uuid: CBUUID {
        return CBUUID(string: self.rawValue.uppercased())
    }

    case value = "FFF2"
    case active = "FFF3"
    case lightOn = "FFF4"
}

struct ExampleState: BeckonState {
    static var defaultState: ExampleState {
        return ExampleState(value: 0, active: false)
    }

    fileprivate(set) var value: Int
    fileprivate(set) var active: Bool
}

struct ExampleMetadata: DeviceMetadata {
    var uuid: UUID
    var firstConnected: Date
}

class ExampleDescriptor: BeckonDescriptor {
    var services: [BluetoothServiceUUID] = [ExampleServices.main]
    
    static let lightOnCharacteristic = WriteOnlyBluetoothCharacteristicUUID<Bool>(uuid: ExampleCharacteristicIdentifiers.lightOn.uuid, service: ExampleServices.main)

    
    var characteristics: [BluetoothCharacteristicUUID] = [
        ConvertibleBluetoothCharacteristicUUID<Int, ExampleState>(uuid: ExampleCharacteristicIdentifiers.value.uuid,
                                                                       service: ExampleServices.main,
                                                                       traits: [.notify,.read],
                                                                       keyPath: \ExampleState.value),
        ConvertibleBluetoothCharacteristicUUID<Bool, ExampleState>(uuid: ExampleCharacteristicIdentifiers.active.uuid,
                                                                          service: ExampleServices.main,
                                                                          traits: [.notify,.read],
                                                                          keyPath: \ExampleState.active),
        lightOnCharacteristic
    ]

    
    func isPairable(advertisementData: AdvertisementData) -> Bool {
        return advertisementData.name?.contains("BECKON") ?? false
    }
}

class AllDevicesDescriptor: BeckonDescriptor {
    var services: [BluetoothServiceUUID] = []
    
    var characteristics: [BluetoothCharacteristicUUID] = []
    
    func isPairable(advertisementData: AdvertisementData) -> Bool {
        return true
    }
}

class BeckonInstance {
    static let shared = Beckon<ExampleState, ExampleMetadata>(appID: "beckonExample", descriptor: AllDevicesDescriptor())
}
