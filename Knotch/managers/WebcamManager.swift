//
//  WebcamManager.swift
//  Knotch
//
//  Created by Harsh Vardhan  Goswami  on 19/08/24.
//
@preconcurrency import AVFoundation
import SwiftUI

@MainActor
final class WebcamManager: NSObject, ObservableObject {
    static let shared = WebcamManager()
    
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    
    // All access is serialized through sessionQueue. AVCaptureSession is not
    // Sendable, so the queue is the synchronization boundary rather than an
    // actor hop around each blocking start/stop call.
    nonisolated(unsafe) private var captureSession: AVCaptureSession?
    @Published var isSessionRunning: Bool = false
    
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    
    @Published var cameraAvailable: Bool = false

    nonisolated private let sessionQueue = DispatchQueue(
        label: "Knotch.WebcamManager.SessionQueue",
        qos: .userInitiated
    )
    
    // MARK: - Constants
    
    enum WebcamError: Error, LocalizedError {
        case deviceUnavailable
        case accessDenied
        case configurationFailed(String)
        
        var errorDescription: String? {
            switch self {
            case .deviceUnavailable:
                return "No camera devices available"
            case .accessDenied:
                return "Camera access denied"
            case .configurationFailed(let message):
                return "Camera configuration failed: \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasDisconnected), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceWasConnected), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        checkCameraAvailability()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        
        if let session = captureSession {
            if session.isRunning {
                session.stopRunning()
            }
        }
        captureSession = nil
            
    }

    // MARK: - Camera Management
    
    /// Checks current authorization status and requests access if needed
    func checkAndRequestVideoAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        authorizationStatus = status
        
        switch status {
        case .authorized:
            checkCameraAvailability() // Check availability if authorized
        case .notDetermined:
            requestVideoAccess()
        case .denied, .restricted:
            NSLog("Camera access denied or restricted")
        @unknown default:
            NSLog("Unknown authorization status")
        }
    }
    
    /// Requests access to the camera
    private func requestVideoAccess() {
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.authorizationStatus = granted ? .authorized : .denied
            if granted {
                self.checkCameraAvailability() // Check availability if access granted
            }
        }
    }

    /// Unlike checkAndRequestVideoAuthorization() (which only requests while
    /// status is .notDetermined), this always attempts the request — used by
    /// the Settings "Grant Access" fallback so it's never a dead click even
    /// if status is .denied. AVFoundation simply won't show a dialog once
    /// the OS has truly decided.
    func requestVideoAccessAlways() {
        Task { @MainActor [weak self] in
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard let self else { return }
            self.authorizationStatus = granted ? .authorized : AVCaptureDevice.authorizationStatus(for: .video)
            if granted {
                self.checkCameraAvailability()
            }
        }
    }
    
    /// Checks if any camera devices are available and sets up capture session if needed
    func checkCameraAvailability() {
        let availableDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
        
        let hasAvailableDevices = !availableDevices.isEmpty
        
        cameraAvailable = hasAvailableDevices
    }
    
    /// Sets up the capture session with a completion handler
    nonisolated private func setupCaptureSession() -> AVCaptureSession? {
            // Clean up any existing session before creating a new one
            cleanupExistingSession()
            
            let session = AVCaptureSession()
            
            do {
                // Get available devices and prefer external camera if available
                let discoverySession = AVCaptureDevice.DiscoverySession(
                    deviceTypes: [.external, .builtInWideAngleCamera],
                    mediaType: .video,
                    position: .unspecified
                )
                
                guard let videoDevice = discoverySession.devices.first else {
                    NSLog("No video devices available")
                    Task { @MainActor [weak self] in
                        self?.isSessionRunning = false
                        self?.cameraAvailable = false
                    }
                    return nil
                }
                
                NSLog("Using camera: \(videoDevice.localizedName)")
                
                // Lock device for configuration
                try videoDevice.lockForConfiguration()
                defer { videoDevice.unlockForConfiguration() }
                
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                guard session.canAddInput(videoInput) else {
                    throw NSError(domain: "Knotch.WebcamManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
                }
                
                session.beginConfiguration()
                // The preview is displayed in a compact notch surface. A
                // medium preset is visually sufficient and avoids keeping the
                // camera/ISP on a high-resolution pipeline unnecessarily.
                session.sessionPreset = .medium
                session.addInput(videoInput)
                session.commitConfiguration()
                
                self.captureSession = session
                
                // Create and set up preview layer on main thread
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.cameraAvailable = true
                    let previewLayer = AVCaptureVideoPreviewLayer(session: session)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                }
                
                NSLog("Capture session setup completed successfully")
                return session
            } catch {
                NSLog("Failed to setup capture session: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.isSessionRunning = false
                    self?.cameraAvailable = false
                    self?.previewLayer = nil
                }
                return nil
            }
    }
    
    /// Cleans up an existing capture session, removing all inputs and outputs
    nonisolated private func cleanupExistingSession() {
        if let existingSession = self.captureSession {
            // First stop the session if running
            if existingSession.isRunning {
                existingSession.stopRunning()
            }
            
            // Then perform configuration cleanup
            existingSession.beginConfiguration()
            
            // Remove all inputs and outputs
            for input in existingSession.inputs {
                existingSession.removeInput(input)
            }
            for output in existingSession.outputs {
                existingSession.removeOutput(output)
            }
            
            existingSession.commitConfiguration()
            self.captureSession = nil
            
            // Clear preview layer on main thread
            Task { @MainActor [weak self] in
                self?.previewLayer = nil
            }
        }
    }

    // AVFoundation posts device connection notifications on an unspecified
    // queue. Keep the Objective-C selector nonisolated, then explicitly hop
    // to the main actor before touching observable/UI state.
    @objc nonisolated private func deviceWasDisconnected(notification: Notification) {
        if AudioHardwareReconfig.isLikelyBounce {
            NSLog("Camera device was disconnected — ignoring, likely a CoreAudio aggregate device bounce")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            NSLog("Camera device was disconnected")
            self.stopSession()
            self.cameraAvailable = false
        }
    }

    @objc nonisolated private func deviceWasConnected(notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            NSLog("Camera device was connected")
            self.checkCameraAvailability()
        }
    }

    nonisolated private func updateSessionState() {
        let isRunning = self.captureSession?.isRunning ?? false
        Task { @MainActor [weak self] in
            self?.isSessionRunning = isRunning
        }
    }
    
    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If no session exists, create new session
            let session = self.captureSession ?? self.setupCaptureSession()
            guard let session, !session.isRunning else { return }
            self.startRunningCaptureSession(session)
        }
    }
    
    nonisolated private func startRunningCaptureSession(_ session: AVCaptureSession) {
        session.startRunning()
        updateSessionState()
        NSLog("Capture session started successfully")
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Update state to indicate we're stopping
            Task { @MainActor in
                self.isSessionRunning = false
            }
            
            self.cleanupExistingSession()
            
            NSLog("Capture session stopped and cleaned up")
        }
    }
}
