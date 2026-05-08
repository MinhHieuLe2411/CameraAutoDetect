//
//  ViewController.swift
//  CustomCameraAutoDetect
//
//  Created by Lê Minh Hiếu on 15/1/26.
//

import UIKit

class ViewController: UIViewController {
    private let openCameraButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupButton()
    }

    private func setupButton() {
        openCameraButton.translatesAutoresizingMaskIntoConstraints = false
        openCameraButton.setTitle("Open Camera", for: .normal)
        openCameraButton.setTitleColor(.white, for: .normal)
        openCameraButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        openCameraButton.backgroundColor = UIColor.systemBlue
        openCameraButton.layer.cornerRadius = 26
        openCameraButton.addTarget(self, action: #selector(openCameraTapped), for: .touchUpInside)
        view.addSubview(openCameraButton)

        NSLayoutConstraint.activate([
            openCameraButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openCameraButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            openCameraButton.widthAnchor.constraint(equalToConstant: 180),
            openCameraButton.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    @objc private func openCameraTapped() {
        let cameraController = CameraViewController()
        navigationController?.pushViewController(cameraController, animated: true)
    }
}
