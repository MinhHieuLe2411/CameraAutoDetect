//
//  CameraManager.swift
//  CustomCameraAutoDetect
//
//  Created by Lê Minh Hiếu on 15/1/26.
//

import AVFoundation
import Vision
import UIKit
import CoreImage

protocol CameraManagerDelegate: AnyObject {
    // Trả về rect đã được xử lý (đã lọc + ổn định + làm mượt)
    func cameraManager(_ manager: CameraManager, didDetect rect: CGRect?)
}

final class CameraManager: NSObject {
    // MARK: - Config

    private enum DetectionConfig {
        static let minArea: CGFloat = 0.04 // Diện tích tối thiểu để lọc nhiễu
        static let aspectPortrait = ClosedRange(uncheckedBounds: (lower: 0.55, upper: 0.85)) // Tỉ lệ dọc
        static let aspectLandscape = ClosedRange(uncheckedBounds: (lower: 1.15, upper: 1.65)) // Tỉ lệ ngang
        static let maxObservations = 4 // Giới hạn số rect từ Vision
        static let minConfidence: VNConfidence = 0.45 // Độ tin cậy tối thiểu
        static let minAspectRatio: VNAspectRatio = 0.5 // Aspect ratio nhỏ nhất
        static let maxAspectRatio: VNAspectRatio = 2.2 // Aspect ratio lớn nhất
        static let quadratureTolerance: Float = 28.0 // Độ lệch góc cho phép
        static let stableHoldDuration: CFTimeInterval = 0.9 // Giữ khung cũ để tránh nhấp nháy
        static let stickDistance: CGFloat = 0.3 // Ngưỡng bám khung theo frame trước
        static let betterAreaMultiplier: CGFloat = 1.25 // Khung mới phải lớn hơn bao nhiêu lần
        static let betterCenterMultiplier: CGFloat = 0.8 // Khung mới phải gần tâm hơn bao nhiêu lần
        static let smoothJumpThreshold: CGFloat = 0.22 // Ngưỡng coi là nhảy lớn
        static let smoothAlphaNear: CGFloat = 0.12 // Mượt khi di chuyển nhỏ
        static let smoothAlphaJump: CGFloat = 0.5 // Mượt khi nhảy lớn
        static let notifyInterval: CFTimeInterval = 0.12 // Tần suất cập nhật overlay
        static let notifyMinDelta: CGFloat = 0.015 // Delta tối thiểu để update
    }

    // MARK: - Camera

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "com.customcamera.camera.queue")
    private let orientation: AVCaptureVideoOrientation
    private var isConfigured = false

    private let latestBufferLock = NSLock()
    private var latestPixelBuffer: CVPixelBuffer?
    private let ciContext = CIContext()

    private var lastStableRect: CGRect? // Rect ổn định gần nhất
    private var lastStableRectTimestamp: CFTimeInterval = 0 // Thời gian cập nhật rect gần nhất
    private var lastNotifiedRect: CGRect? // Rect đã notify lần gần nhất
    private var lastNotifyTimestamp: CFTimeInterval = 0 // Thời gian notify lần gần nhất

    weak var delegate: CameraManagerDelegate?

    init(orientation: AVCaptureVideoOrientation = .portrait) {
        self.orientation = orientation
        super.init()
        configureSession()
    }

    // Xin quyền camera
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video, completionHandler: completion)
        default:
            completion(false)
        }
    }

    // Bắt đầu session
    func start() {
        guard isConfigured, !session.isRunning else { return }
        session.startRunning()
    }

    // Dừng session
    func stop() {
        guard session.isRunning else { return }
        session.stopRunning()
    }

    // Lấy AVCaptureSession để dùng cho preview
    func getSession() -> AVCaptureSession {
        session
    }

    // Chụp ảnh từ frame mới nhất (có crop theo rect nếu có)
    func captureImage(cropRect: CGRect?,
                      orientation: AVCaptureVideoOrientation,
                      rotationFixExif: Int32) -> UIImage? {
        latestBufferLock.lock()
        let buffer = latestPixelBuffer
        latestBufferLock.unlock()

        guard let pixelBuffer = buffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let oriented = ciImage.oriented(forExifOrientation: exifOrientation(for: orientation))
        let outputImage: CIImage
        if let rect = cropRect {
            outputImage = cropImage(oriented, normalizedRect: rect)
        } else {
            outputImage = oriented
        }
        let finalImage = outputImage.oriented(forExifOrientation: rotationFixExif)
        guard let cgImage = ciContext.createCGImage(finalImage, from: finalImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // Cấu hình session
    private func configureSession() {
        guard !isConfigured else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }

        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            return
        }

        session.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            connection.videoOrientation = orientation
        }

        session.commitConfiguration()
        isConfigured = true
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestBufferLock.lock()
        latestPixelBuffer = pixelBuffer
        latestBufferLock.unlock()

        let requestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .right,
            options: [:]
        )

        let rectangleRequest = VNDetectRectanglesRequest { [weak self] request, _ in
            guard let self = self else { return }
            guard let results = request.results as? [VNRectangleObservation] else { return }
            let rect = self.processRectangles(results)
            if self.shouldNotify(rect: rect) {
                DispatchQueue.main.async {
                    self.delegate?.cameraManager(self, didDetect: rect)
                }
            }
        }
        rectangleRequest.maximumObservations = DetectionConfig.maxObservations
        rectangleRequest.minimumConfidence = DetectionConfig.minConfidence
        rectangleRequest.minimumAspectRatio = DetectionConfig.minAspectRatio
        rectangleRequest.maximumAspectRatio = DetectionConfig.maxAspectRatio
        rectangleRequest.quadratureTolerance = DetectionConfig.quadratureTolerance

        do {
            try requestHandler.perform([rectangleRequest])
        } catch {
            return
        }
    }
}

// MARK: - Detection

private extension CameraManager {
    // Lọc + chọn + ổn định rect
    func processRectangles(_ observations: [VNRectangleObservation]) -> CGRect? {
        let filtered = observations.filter { observation in
            let rect = observation.boundingBox
            let aspectRatio = rect.width / rect.height
            let isCardLike = DetectionConfig.aspectPortrait.contains(aspectRatio) ||
                DetectionConfig.aspectLandscape.contains(aspectRatio)
            let isLargeEnough = rect.width * rect.height > DetectionConfig.minArea
            return isCardLike && isLargeEnough
        }

        guard let bestCandidate = bestCandidate(from: filtered) else {
            return holdLastRectIfNeeded()
        }

        var chosenRect = stabilizedRect(bestRect: bestCandidate.boundingBox, candidates: filtered)
        chosenRect = smoothedRect(from: lastStableRect, to: chosenRect)
        lastStableRect = chosenRect
        lastStableRectTimestamp = CACurrentMediaTime()
        return chosenRect
    }

    // Ưu tiên lớn nhất, sau đó gần giữa
    func bestCandidate(from observations: [VNRectangleObservation]) -> VNRectangleObservation? {
        observations.sorted { left, right in
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
        }.first
    }

    // Bám rect gần nhất, trừ khi có rect tốt hơn rõ rệt
    func stabilizedRect(bestRect: CGRect, candidates: [VNRectangleObservation]) -> CGRect {
        guard let lastRect = lastStableRect,
              let closest = candidates.min(by: { left, right in
                  let leftCenter = CGPoint(x: left.boundingBox.midX, y: left.boundingBox.midY)
                  let rightCenter = CGPoint(x: right.boundingBox.midX, y: right.boundingBox.midY)
                  let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
                  let leftDistance = hypot(leftCenter.x - lastCenter.x, leftCenter.y - lastCenter.y)
                  let rightDistance = hypot(rightCenter.x - lastCenter.x, rightCenter.y - lastCenter.y)
                  return leftDistance < rightDistance
              }) else {
            return bestRect
        }

        let closestRect = closest.boundingBox
        let closestCenter = CGPoint(x: closestRect.midX, y: closestRect.midY)
        let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
        let distanceToLast = hypot(closestCenter.x - lastCenter.x, closestCenter.y - lastCenter.y)
        guard distanceToLast < DetectionConfig.stickDistance else { return bestRect }

        let bestArea = bestRect.width * bestRect.height
        let closestArea = closestRect.width * closestRect.height
        let bestCenter = CGPoint(x: bestRect.midX, y: bestRect.midY)
        let closestCenterDist = hypot(closestCenter.x - 0.5, closestCenter.y - 0.5)
        let bestCenterDist = hypot(bestCenter.x - 0.5, bestCenter.y - 0.5)
        let isSignificantlyBetter = bestArea > closestArea * DetectionConfig.betterAreaMultiplier &&
            bestCenterDist < closestCenterDist * DetectionConfig.betterCenterMultiplier
        return isSignificantlyBetter ? bestRect : closestRect
    }

    // Làm mượt để giảm giật
    func smoothedRect(from lastRect: CGRect?, to newRect: CGRect) -> CGRect {
        guard let lastRect = lastRect else { return newRect }
        let lastCenter = CGPoint(x: lastRect.midX, y: lastRect.midY)
        let newCenter = CGPoint(x: newRect.midX, y: newRect.midY)
        let jump = hypot(newCenter.x - lastCenter.x, newCenter.y - lastCenter.y)
        let alpha: CGFloat = jump > DetectionConfig.smoothJumpThreshold
            ? DetectionConfig.smoothAlphaJump
            : DetectionConfig.smoothAlphaNear
        return lerpRect(from: lastRect, to: newRect, alpha: alpha)
    }

    // Giữ rect cũ một thời gian nếu mất detect
    func holdLastRectIfNeeded() -> CGRect? {
        let now = CACurrentMediaTime()
        if let lastRect = lastStableRect,
           now - lastStableRectTimestamp < DetectionConfig.stableHoldDuration {
            return lastRect
        }
        return nil
    }

    // Chỉ notify khi đủ thời gian và delta đủ lớn
    func shouldNotify(rect: CGRect?) -> Bool {
        let now = CACurrentMediaTime()
        if now - lastNotifyTimestamp < DetectionConfig.notifyInterval {
            return false
        }
        lastNotifyTimestamp = now

        guard let rect = rect else {
            let shouldClear = lastNotifiedRect != nil
            if shouldClear {
                lastNotifiedRect = nil
            }
            return shouldClear
        }

        defer { lastNotifiedRect = rect }
        guard let last = lastNotifiedRect else { return true }

        let dx = abs(rect.midX - last.midX)
        let dy = abs(rect.midY - last.midY)
        let dw = abs(rect.width - last.width)
        let dh = abs(rect.height - last.height)
        return max(dx, dy, dw, dh) > DetectionConfig.notifyMinDelta
    }
}

// MARK: - Helpers

private extension CameraManager {
    // Nội suy tuyến tính để làm mượt
    func lerpRect(from: CGRect, to: CGRect, alpha: CGFloat) -> CGRect {
        let clamped = min(max(alpha, 0), 1)
        let x = from.origin.x + (to.origin.x - from.origin.x) * clamped
        let y = from.origin.y + (to.origin.y - from.origin.y) * clamped
        let w = from.size.width + (to.size.width - from.size.width) * clamped
        let h = from.size.height + (to.size.height - from.size.height) * clamped
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // Đổi rect chuẩn hoá (0..1) sang rect pixel
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

    // Map orientation sang EXIF
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
}
