//
//  ViewController.swift
//  BeckonExample
//
//  Created by Ville Petersson on 2019-04-02.
//  Copyright © 2019 The Techno Creatives. All rights reserved.
//

import UIKit
import Beckon
import RxSwift
import RxCocoa

class ScanViewController: UIViewController, UITableViewDelegate, UITableViewDataSource {
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return scannedDevices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "scannedCell", for: indexPath)
        let device = self.scannedDevices[indexPath.row]
        cell.textLabel?.text = "Device \(device.uuid)"
        return cell
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let device = self.scannedDevices[indexPath.row]

        let metadata = ExampleMetadata(uuid: device.uuid, firstConnected: Date())
        
        BeckonInstance.shared.settingsStore.saveDevice(metadata)
        
        self.dismiss(animated: true, completion: nil)
    }


    @IBOutlet weak var tableView: UITableView!
    let disposeBag = DisposeBag()
    
    var scannedDevices: [DiscoveredDevice] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        tableView.delegate = self
        tableView.dataSource = self


        BeckonInstance.shared.search()
            .subscribe(onNext: { [weak self] (device) in
                print("FOUND IT \n\n\n\nWOOO\n\n")
                assert(Thread.isMainThread)
                self?.scannedDevices.append(device)
                self?.tableView.reloadData()
            }).disposed(by: disposeBag)
    }
}

