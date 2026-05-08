//
//  CameraViewController.swift
//  CustomCameraAutoDetect
//
//  Created by Lê Minh Hiếu on 15/1/26.
//

import UIKit
import AVFoundation

final class CameraViewController: UIViewController {
    // MARK: - Config

    private enum CaptureConfig {
        static let lockedOrientation: AVCaptureVideoOrientation = .portrait
        // Nếu ảnh bị xoay sai, chỉnh giá trị này: 1 (không xoay), 6 (xoay phải), 8 (xoay trái)
        static let rotationFixExif: Int32 = 8
    }

    // MARK: - Camera

    private let cameraManager = CameraManager(orientation: CaptureConfig.lockedOrientation)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let overlayLayer = CAShapeLayer()
    private var currentRect: CGRect?
    private let guideFrameView = UIView()

    // MARK: - UI

    private let topBarView = UIView()
    private let backButton = UIButton(type: .system)
    private let flashButton = UIButton(type: .system)

    private let bottomBarView = UIView()
    private let captureButton = UIButton(type: .system)
    private let libraryButton = UIButton(type: .system)
    private let tipsButton = UIButton(type: .system)

    private var isTorchOn = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupOverlay()
        setupGuideFrame()
        setupTopBar()
        setupBottomBar()
        setupPreviewLayer()
        startCameraIfAuthorized()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        overlayLayer.frame = view.bounds
        layoutGuideFrame()
    }

    // MARK: - UI

    private func setupOverlay() {
        overlayLayer.strokeColor = UIColor.systemGreen.cgColor
        overlayLayer.fillColor = UIColor.clear.cgColor
        overlayLayer.lineWidth = 4
        overlayLayer.lineCap = .round
        overlayLayer.lineJoin = .round
        view.layer.addSublayer(overlayLayer)
        overlayLayer.isHidden = true
    }

    private func setupGuideFrame() {
        guideFrameView.translatesAutoresizingMaskIntoConstraints = true
        guideFrameView.layer.borderColor = UIColor.systemGreen.cgColor
        guideFrameView.layer.borderWidth = 2
        guideFrameView.layer.cornerRadius = 12
        guideFrameView.isUserInteractionEnabled = false
        view.addSubview(guideFrameView)
    }

    private func layoutGuideFrame() {
        let maxWidth = view.bounds.width * 0.72
        let targetWidth = min(maxWidth, 320)
        let targetHeight = targetWidth * 1.35
        let centerY = view.bounds.midY - 12
        guideFrameView.frame = CGRect(
            x: (view.bounds.width - targetWidth) / 2,
            y: centerY - targetHeight / 2,
            width: targetWidth,
            height: targetHeight
        )
    }

    private func setupTopBar() {
        topBarView.translatesAutoresizingMaskIntoConstraints = false
        topBarView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        view.addSubview(topBarView)

        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
        topBarView.addSubview(backButton)

        flashButton.translatesAutoresizingMaskIntoConstraints = false
        flashButton.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
        flashButton.tintColor = .white
        flashButton.addTarget(self, action: #selector(flashButtonTapped), for: .touchUpInside)
        topBarView.addSubview(flashButton)

        NSLayoutConstraint.activate([
            topBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBarView.heightAnchor.constraint(equalToConstant: 64),

            backButton.leadingAnchor.constraint(equalTo: topBarView.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 28),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            flashButton.trailingAnchor.constraint(equalTo: topBarView.trailingAnchor, constant: -16),
            flashButton.centerYAnchor.constraint(equalTo: topBarView.centerYAnchor),
            flashButton.widthAnchor.constraint(equalToConstant: 28),
            flashButton.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupBottomBar() {
        bottomBarView.translatesAutoresizingMaskIntoConstraints = false
        bottomBarView.backgroundColor = UIColor.black.withAlphaComponent(0.0)
        view.addSubview(bottomBarView)

        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.setImage(UIImage(systemName: "photo.on.rectangle"), for: .normal)
        libraryButton.tintColor = .white
        libraryButton.addTarget(self, action: #selector(libraryButtonTapped), for: .touchUpInside)
        bottomBarView.addSubview(libraryButton)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setTitle(nil, for: .normal)
        captureButton.backgroundColor = .white
        captureButton.layer.cornerRadius = 32
        captureButton.layer.borderColor = UIColor.white.withAlphaComponent(0.8).cgColor
        captureButton.layer.borderWidth = 3
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        bottomBarView.addSubview(captureButton)

        tipsButton.translatesAutoresizingMaskIntoConstraints = false
        tipsButton.setImage(UIImage(systemName: "lightbulb"), for: .normal)
        tipsButton.tintColor = .white
        tipsButton.addTarget(self, action: #selector(tipsButtonTapped), for: .touchUpInside)
        bottomBarView.addSubview(tipsButton)

        NSLayoutConstraint.activate([
            bottomBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBarView.heightAnchor.constraint(equalToConstant: 110),

            libraryButton.leadingAnchor.constraint(equalTo: bottomBarView.leadingAnchor, constant: 16),
            libraryButton.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),

            captureButton.centerXAnchor.constraint(equalTo: bottomBarView.centerXAnchor),
            captureButton.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 64),
            captureButton.heightAnchor.constraint(equalToConstant: 64),

            tipsButton.trailingAnchor.constraint(equalTo: bottomBarView.trailingAnchor, constant: -16),
            tipsButton.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor)
        ])
    }

    // MARK: - Camera

    private func setupPreviewLayer() {
        let preview = AVCaptureVideoPreviewLayer(session: cameraManager.getSession())
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.connection?.videoOrientation = CaptureConfig.lockedOrientation
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func startCameraIfAuthorized() {
        cameraManager.delegate = self
        cameraManager.requestAccess { [weak self] granted in
            DispatchQueue.main.async {
                guard granted else { return }
                self?.cameraManager.start()
            }
        }
    }
}

// MARK: - CameraManagerDelegate

extension CameraViewController: CameraManagerDelegate {
    func cameraManager(_ manager: CameraManager, didDetect rect: CGRect?) {
        currentRect = rect
        updateOverlay(rect: rect)
    }
}

// MARK: - Overlay

private extension CameraViewController {
    func updateOverlay(rect: CGRect?) {
        guard let previewLayer = previewLayer else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard let rect = rect else {
                self.overlayLayer.path = nil
                return
            }
            let metadataRect = CGRect(
                x: rect.origin.x,
                y: 1.0 - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
            let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
            self.overlayLayer.path = self.cornerPath(for: converted).cgPath
        }
    }

    func cornerPath(for rect: CGRect) -> UIBezierPath {
        let path = UIBezierPath()
        let cornerLength = min(rect.width, rect.height) * 0.18
        let cornerRadius = max(6, cornerLength * 0.35)

        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)

        path.move(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerLength))
        path.addLine(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerRadius))
        path.addQuadCurve(to: CGPoint(x: topLeft.x + cornerRadius, y: topLeft.y),
                          controlPoint: topLeft)
        path.addLine(to: CGPoint(x: topLeft.x + cornerLength, y: topLeft.y))

        path.move(to: CGPoint(x: topRight.x - cornerLength, y: topRight.y))
        path.addLine(to: CGPoint(x: topRight.x - cornerRadius, y: topRight.y))
        path.addQuadCurve(to: CGPoint(x: topRight.x, y: topRight.y + cornerRadius),
                          controlPoint: topRight)
        path.addLine(to: CGPoint(x: topRight.x, y: topRight.y + cornerLength))

        path.move(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerLength))
        path.addLine(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerRadius))
        path.addQuadCurve(to: CGPoint(x: bottomLeft.x + cornerRadius, y: bottomLeft.y),
                          controlPoint: bottomLeft)
        path.addLine(to: CGPoint(x: bottomLeft.x + cornerLength, y: bottomLeft.y))

        path.move(to: CGPoint(x: bottomRight.x - cornerLength, y: bottomRight.y))
        path.addLine(to: CGPoint(x: bottomRight.x - cornerRadius, y: bottomRight.y))
        path.addQuadCurve(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerRadius),
                          controlPoint: bottomRight)
        path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerLength))

        return path
    }
}

// MARK: - Actions

private extension CameraViewController {
    @objc func captureButtonTapped() {
        let image = cameraManager.captureImage(
            cropRect: currentRect,
            orientation: CaptureConfig.lockedOrientation,
            rotationFixExif: CaptureConfig.rotationFixExif
        )
        guard let image = image else { return }
        let preview = ImagePreviewViewController(image: image)
        navigationController?.pushViewController(preview, animated: true)
    }

    @objc func backButtonTapped() {
        navigationController?.popViewController(animated: true)
    }

    @objc func flashButtonTapped() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if isTorchOn {
                device.torchMode = .off
                flashButton.setImage(UIImage(systemName: "bolt.fill"), for: .normal)
            } else {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                flashButton.setImage(UIImage(systemName: "bolt.slash.fill"), for: .normal)
            }
            isTorchOn.toggle()
            device.unlockForConfiguration()
        } catch {
            return
        }
    }

    @objc func libraryButtonTapped() {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc func tipsButtonTapped() {
        let alert = UIAlertController(
            title: "Snaptips",
            message: "Giữ máy ổn định, đặt thẻ trong khung và tránh phản chiếu mạnh.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - UIImagePickerControllerDelegate

extension CameraViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(_ picker: UIImagePickerController,
                               didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage else { return }
        let preview = ImagePreviewViewController(image: image)
        navigationController?.pushViewController(preview, animated: true)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}
