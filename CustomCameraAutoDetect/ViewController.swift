//
//  ViewController.swift
//  CustomCameraAutoDetect
//
//  Created by Lê Minh Hiếu on 15/1/26.
//

import UIKit
import AVFoundation
import Vision
import CoreML

class ViewController: UIViewController {
    // Camera capture + preview
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.customcamera.vision.queue")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    // Overlay for rectangle boxes
    private let overlayLayerAll = CAShapeLayer()
    private let overlayLayerAccepted = CAShapeLayer()
    // Simple UI controls
    private let bottomBarView = UIView()
    private let captureButton = UIButton(type: .system)
    private let capturedImageView = UIImageView()
    private let latestBufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext()
    private var lastStableRect: CGRect?
    private var lastStableRectTimestamp: CFTimeInterval = 0
    private let stableHoldDuration: CFTimeInterval = 0.25
    private var currentVideoOrientation: AVCaptureVideoOrientation = .portrait
    // Throttle frame processing (avoid overlapping Vision requests)
    private var isProcessingFrame = false
    // Optional CoreML model to verify card-like rectangles
    private var coreMLModel: VNCoreMLModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupOverlay()
        setupBottomBar()
        setupCoreMLIfAvailable()
        checkCameraPermissionAndStart()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        overlayLayerAll.frame = view.bounds
        overlayLayerAccepted.frame = view.bounds
        updateVideoOrientation()
    }

    private func setupOverlay() {
        overlayLayerAll.strokeColor = UIColor.systemYellow.cgColor
        overlayLayerAll.fillColor = UIColor.clear.cgColor
        overlayLayerAll.lineWidth = 2

        overlayLayerAccepted.strokeColor = UIColor.systemGreen.cgColor
        overlayLayerAccepted.fillColor = UIColor.clear.cgColor
        overlayLayerAccepted.lineWidth = 2

        view.layer.addSublayer(overlayLayerAll)
        view.layer.addSublayer(overlayLayerAccepted)
    }

    private func setupBottomBar() {
        bottomBarView.translatesAutoresizingMaskIntoConstraints = false
        bottomBarView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.addSubview(bottomBarView)

        capturedImageView.translatesAutoresizingMaskIntoConstraints = false
        capturedImageView.contentMode = .scaleAspectFill
        capturedImageView.clipsToBounds = true
        capturedImageView.layer.cornerRadius = 8
        capturedImageView.backgroundColor = UIColor(white: 0.1, alpha: 1.0)
        bottomBarView.addSubview(capturedImageView)

        captureButton.translatesAutoresizingMaskIntoConstraints = false
        captureButton.setTitle("Capture", for: .normal)
        captureButton.setTitleColor(.white, for: .normal)
        captureButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        captureButton.backgroundColor = UIColor.systemBlue
        captureButton.layer.cornerRadius = 20
        captureButton.addTarget(self, action: #selector(captureButtonTapped), for: .touchUpInside)
        bottomBarView.addSubview(captureButton)

        NSLayoutConstraint.activate([
            bottomBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBarView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomBarView.heightAnchor.constraint(equalToConstant: 110),

            capturedImageView.leadingAnchor.constraint(equalTo: bottomBarView.leadingAnchor, constant: 16),
            capturedImageView.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),
            capturedImageView.widthAnchor.constraint(equalToConstant: 80),
            capturedImageView.heightAnchor.constraint(equalToConstant: 80),

            captureButton.trailingAnchor.constraint(equalTo: bottomBarView.trailingAnchor, constant: -16),
            captureButton.centerYAnchor.constraint(equalTo: bottomBarView.centerYAnchor),
            captureButton.widthAnchor.constraint(equalToConstant: 140),
            captureButton.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    private func setupCoreMLIfAvailable() {
        // Load CardDetector.mlmodelc if it exists in app bundle
        guard let modelURL = Bundle.main.url(forResource: "CardDetector", withExtension: "mlmodelc"),
              let model = try? MLModel(contentsOf: modelURL),
              let visionModel = try? VNCoreMLModel(for: model) else {
            return
        }
        coreMLModel = visionModel
    }

    private func checkCameraPermissionAndStart() {
        // Ask for camera permission before starting capture session
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCaptureSession()
            captureSession.startRunning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else { return }
                    self?.setupCaptureSession()
                    self?.captureSession.startRunning()
                }
            }
        default:
            return
        }
    }

    private func setupCaptureSession() {
        captureSession.beginConfiguration()
        captureSession.sessionPreset = .high

        // Back camera input
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addInput(input)

        // Frame output for Vision/CoreML
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            return
        }

        captureSession.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = .portrait
            currentVideoOrientation = connection.videoOrientation
        }

        captureSession.commitConfiguration()

        // Live preview layer
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func updateVideoOrientation() {
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation
        let newOrientation = videoOrientation(
            for: interfaceOrientation ?? .portrait,
            fallbackDevice: UIDevice.current.orientation
        )
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = newOrientation
        }
        if let connection = previewLayer?.connection {
            connection.videoOrientation = newOrientation
        }
        currentVideoOrientation = newOrientation
    }

    private func handleRectangles(_ observations: [VNRectangleObservation],
                                  pixelBuffer: CVPixelBuffer) {
        guard let previewLayer = previewLayer else { return }

        // Filter to card-like sizes/aspect ratios
        let filtered = observations.filter { observation in
            let rect = observation.boundingBox
            let aspectRatio = rect.width / rect.height
            let isCardLike = (0.55...0.85).contains(aspectRatio) || (1.15...1.65).contains(aspectRatio)
            let isLargeEnough = rect.width * rect.height > 0.08
            return isCardLike && isLargeEnough
        }

        // Pick one best rectangle: largest area, then closest to center
        let sorted = filtered.sorted { left, right in
            let leftArea = left.boundingBox.width * left.boundingBox.height
            let rightArea = right.boundingBox.width * right.boundingBox.height
            if leftArea != rightArea {
                return leftArea > rightArea
            }
            let leftCenter = CGPoint(x: left.boundingBox.midX, y: left.boundingBox.midY)
            let rightCenter = CGPoint(x: right.boundingBox.midX, y: right.boundingBox.midY)
            let leftDistance = hypot(leftCenter.x - 0.5, leftCenter.y - 0.5)
            let rightDistance = hypot(rightCenter.x - 0.5, rightCenter.y - 0.5)
            return leftDistance < rightDistance
        }

        guard let bestCandidate = sorted.first else {
            let now = CACurrentMediaTime()
            if let lastRect = lastStableRect, now - lastStableRectTimestamp < stableHoldDuration {
                let metadataRect = CGRect(
                    x: lastRect.origin.x,
                    y: 1.0 - lastRect.origin.y - lastRect.height,
                    width: lastRect.width,
                    height: lastRect.height
                )
                let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
                DispatchQueue.main.async { [weak self] in
                    self?.overlayLayerAll.path = UIBezierPath(rect: converted).cgPath
                }
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.overlayLayerAll.path = nil
                self?.overlayLayerAccepted.path = nil
            }
            return
        }

        var chosenRect = bestCandidate.boundingBox
        if let lastRect = lastStableRect,
           let closest = filtered.min(by: { left, right in
               let leftCenter = CGPoint(x: left.boundingBox.midX, y: left.boundingBox.midY)
               let rightCenter = CGPoint(x: right.boundingBox.midX, y: right.boundingBox.midY)
               let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
               let leftDistance = hypot(leftCenter.x - lastCenter.x, leftCenter.y - lastCenter.y)
               let rightDistance = hypot(rightCenter.x - lastCenter.x, rightCenter.y - lastCenter.y)
               return leftDistance < rightDistance
           }) {
            let closestRect = closest.boundingBox
            let closestCenter = CGPoint(x: closestRect.midX, y: closestRect.midY)
            let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
            let distanceToLast = hypot(closestCenter.x - lastCenter.x, closestCenter.y - lastCenter.y)
            if distanceToLast < 0.12 {
                let bestArea = chosenRect.width * chosenRect.height
                let closestArea = closestRect.width * closestRect.height
                let bestCenter = CGPoint(x: chosenRect.midX, y: chosenRect.midY)
                let closestCenterDist = hypot(closestCenter.x - 0.5, closestCenter.y - 0.5)
                let bestCenterDist = hypot(bestCenter.x - 0.5, bestCenter.y - 0.5)
                let isSignificantlyBetter = bestArea > closestArea * 1.25 &&
                    bestCenterDist < closestCenterDist * 0.8
                if !isSignificantlyBetter {
                    chosenRect = closestRect
                }
            }
        }
        if let lastRect = lastStableRect {
            let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
            let newCenter = CGPoint(x: chosenRect.midX, y: chosenRect.midY)
            let jump = hypot(newCenter.x - lastCenter.x, newCenter.y - lastCenter.y)
            // If jump is large, snap quickly; otherwise smooth a bit
            let alpha: CGFloat = jump > 0.12 ? 0.85 : 0.5
            chosenRect = lerpRect(from: lastRect, to: chosenRect, alpha: alpha)
        }
        lastStableRect = chosenRect
        lastStableRectTimestamp = CACurrentMediaTime()

        // If CoreML is active, avoid drawing yellow to prevent double boxes
        if coreMLModel != nil {
            DispatchQueue.main.async { [weak self] in
                self?.overlayLayerAll.path = nil
            }
        }

        // Draw best candidate in yellow (only when CoreML is not used)
        let metadataRect = CGRect(
            x: chosenRect.origin.x,
            y: 1.0 - chosenRect.origin.y - chosenRect.height,
            width: chosenRect.width,
            height: chosenRect.height
        )
        let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
        if coreMLModel == nil {
            let allPath = UIBezierPath(rect: converted)
            DispatchQueue.main.async { [weak self] in
                self?.overlayLayerAll.path = allPath.cgPath
                self?.overlayLayerAccepted.path = nil
            }
        }

        // If no CoreML model, stop after drawing all
        guard let coreMLModel = coreMLModel else {
            return
        }

        // If CoreML exists, verify each rectangle ROI before drawing
        let group = DispatchGroup()
        var accepted: [CGRect] = []
        let acceptedLock = NSLock()

        group.enter()
        let request = VNCoreMLRequest(model: coreMLModel) { request, _ in
            defer { group.leave() }
            guard let results = request.results as? [VNClassificationObservation],
                  let best = results.first else { return }
            let isCard = best.confidence >= 0.6 &&
                best.identifier.lowercased().contains("card")
            guard isCard else { return }
            acceptedLock.lock()
            accepted.append(chosenRect)
            acceptedLock.unlock()
        }
        request.imageCropAndScaleOption = .centerCrop
        request.regionOfInterest = chosenRect

        // Run CoreML on the full frame but limited to ROI
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )
        do {
            try handler.perform([request])
        } catch {
            group.leave()
        }

        // Draw accepted rectangles on main thread (green)
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            guard let rect = accepted.first else {
                self.overlayLayerAccepted.path = nil
                return
            }
            let metadataRect = CGRect(
                x: rect.origin.x,
                y: 1.0 - rect.origin.y - rect.height,
                width: rect.width,
                height: rect.height
            )
            let converted = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
            self.overlayLayerAccepted.path = UIBezierPath(rect: converted).cgPath
        }
    }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Skip if a previous frame is still processing
        guard !isProcessingFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBufferLock.lock()
        latestPixelBuffer = pixelBuffer
        latestBufferLock.unlock()
        let requestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])

        // Rectangle detection request
        var requests: [VNRequest] = []
        let rectangleRequest = VNDetectRectanglesRequest { [weak self] request, _ in
            guard let results = request.results as? [VNRectangleObservation] else { return }
            self?.handleRectangles(results, pixelBuffer: pixelBuffer)
        }
        // Sensitivity tuning:
        // - maximumObservations: limit how many rectangles are returned
        // - minimumConfidence: higher = fewer false positives (but may miss)
        // - minimumAspectRatio/maximumAspectRatio: clamp rectangle shape
        // - quadratureTolerance: lower = stricter rectangle angles
        rectangleRequest.maximumObservations = 4
        rectangleRequest.minimumConfidence = 0.5
        rectangleRequest.minimumAspectRatio = 0.5
        rectangleRequest.maximumAspectRatio = 2.0
        rectangleRequest.quadratureTolerance = 20.0
        requests.append(rectangleRequest)

        do {
            try requestHandler.perform(requests)
        } catch {
            return
        }
    }
}

private extension ViewController {
    @objc func captureButtonTapped() {
        let interfaceOrientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let captureOrientation = videoOrientation(
            for: interfaceOrientation,
            fallbackDevice: UIDevice.current.orientation
        )
        currentVideoOrientation = captureOrientation
        latestBufferLock.lock()
        let buffer = latestPixelBuffer
        latestBufferLock.unlock()

        guard let pixelBuffer = buffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ciImage.oriented(forExifOrientation: exifOrientation(for: captureOrientation))
        let outputImage: CIImage
        if let rect = lastStableRect {
            outputImage = cropImage(oriented, normalizedRect: rect)
        } else {
            outputImage = oriented
        }
        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        capturedImageView.image = image

        let preview = ImagePreviewViewController(image: image)
        if let navigationController = navigationController {
            navigationController.pushViewController(preview, animated: true)
        } else {
            present(preview, animated: true)
        }
    }

    func lerpRect(from: CGRect, to: CGRect, alpha: CGFloat) -> CGRect {
        let clamped = min(max(alpha, 0), 1)
        let x = from.origin.x + (to.origin.x - from.origin.x) * clamped
        let y = from.origin.y + (to.origin.y - from.origin.y) * clamped
        let w = from.size.width + (to.size.width - from.size.width) * clamped
        let h = from.size.height + (to.size.height - from.size.height) * clamped
        return CGRect(x: x, y: y, width: w, height: h)
    }

    func cropImage(_ image: CIImage, normalizedRect: CGRect) -> CIImage {
        let width = image.extent.width
        let height = image.extent.height
        let rect = CGRect(
            x: normalizedRect.origin.x * width,
            y: normalizedRect.origin.y * height,
            width: normalizedRect.width * width,
            height: normalizedRect.height * height
        ).intersection(image.extent)
        return image.cropped(to: rect)
    }

    func exifOrientation(for orientation: AVCaptureVideoOrientation) -> Int32 {
        switch orientation {
        case .portrait:
            return 6
        case .portraitUpsideDown:
            return 8
        case .landscapeRight:
            return 3
        case .landscapeLeft:
            return 1
        @unknown default:
            return 6
        }
    }

    func videoOrientation(for interfaceOrientation: UIInterfaceOrientation,
                          fallbackDevice: UIDeviceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeLeft
        case .landscapeRight:
            return .landscapeRight
        default:
            break
        }

        switch fallbackDevice {
        case .portrait:
            return .portrait
        case .portraitUpsideDown:
            return .portraitUpsideDown
        case .landscapeLeft:
            return .landscapeRight
        case .landscapeRight:
            return .landscapeLeft
        default:
            return .portrait
        }
    }
}
