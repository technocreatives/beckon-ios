//
//  DevicesViewController.swift
//  BeckonExample
//
//  Created by Ville Petersson on 2019-04-29.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
//

import UIKit
import Beckon
import RxSwift
import RxCocoa

class DevicesViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return scannedDevices.count
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "deviceCell", for: indexPath)
        let device = self.scannedDevices[indexPath.row]
        cell.textLabel?.text = "Device \(device.metadata)"
        if case .connected(let state) = device.state {
            cell.detailTextLabel?.text = "Connected: \(state.active ? "Active" : "Not active"), Value: \(state.value) "
        } else {
            cell.detailTextLabel?.text = "Disconnected"
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let device = self.scannedDevices[indexPath.row]

        let metadata = ExampleMetadata(uuid: device.deviceIdentifier, firstConnected: Date())
        
        if case .connected(let state) = device.state {
            let _ = BeckonInstance.shared.write(value: !state.active, to: ExampleDescriptor.lightOnCharacteristic, on: metadata.uuid).subscribe()
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    
    @IBOutlet weak var tableView: UITableView!
    let disposeBag = DisposeBag()
    
    var scannedDevices: [BeckonDevice<ExampleState, ExampleMetadata>] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.dataSource = self        
        
        BeckonInstance.shared.devices
            .subscribe(onNext: { [weak self] (devices) in
                self?.scannedDevices = devices
                self?.tableView.reloadData()
            }).disposed(by: disposeBag)
    }
}
