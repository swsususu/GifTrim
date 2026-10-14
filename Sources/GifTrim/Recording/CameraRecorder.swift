import AppKit
@preconcurrency import AVFoundation
import CoreMediaIO
import SwiftUI

/// Records from a camera (built-in, external, Continuity Camera, or a USB-connected iPhone/iPad screen).
@MainActor
@Observable
final class CameraRecorder: NSObject {
    var devices: [AVCaptureDevice] = []
    var selectedID: String?
    var isRecording = false
    var authorized = false
    var errorMessage: String?
    var elapsed: Double = 0

    let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private var currentInput: AVCaptureDeviceInput?
    @ObservationIgnored private var finishHandler: ((URL?) -> Void)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "giftrim.camera")

    override init() {
        super.init()
        Self.enableScreenCaptureDevices()
        if session.canAddOutput(output) { session.addOutput(output) }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDevices() }
            })
        }
    }

    /// Lets iOS devices connected over USB appear as capture devices (muxed screen capture).
    static func enableScreenCaptureDevices() {
        var prop = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &prop, 0, nil,
                                  UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .video)
        default: authorized = false
        }
        guard authorized else {
            errorMessage = "没有摄像头权限。请在“系统设置 › 隐私与安全性 › 摄像头”中允许 GifTrim。"
            return
        }
        refreshDevices()
        // iOS devices can take a moment to show up after enabling the property.
        try? await Task.sleep(for: .seconds(1))
        refreshDevices()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
            mediaType: nil, position: .unspecified)
        devices = discovery.devices.filter { $0.hasMediaType(.video) || $0.hasMediaType(.muxed) }
        if selectedID == nil || !devices.contains(where: { $0.uniqueID == selectedID }) {
            selectedID = devices.first?.uniqueID
        }
        select(selectedID)
    }

    func select(_ id: String?) {
        guard let id, let device = devices.first(where: { $0.uniqueID == id }) else { return }
        if currentInput?.device.uniqueID == id { ensureRunning(); return }
        selectedID = id
        session.beginConfiguration()
        if let currentInput { session.removeInput(currentInput) }
        currentInput = nil
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        } else {
            errorMessage = "无法使用设备：\(device.localizedName)"
        }
        session.sessionPreset = session.canSetSessionPreset(.high) ? .high : session.sessionPreset
        session.commitConfiguration()
        ensureRunning()
    }

    private func ensureRunning() {
        let s = session
        sessionQueue.async { if !s.isRunning { s.startRunning() } }
    }

    func stopSession() {
        if isRecording { output.stopRecording() }
        let s = session
        sessionQueue.async { s.stopRunning() }
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        timer?.invalidate()
    }

    func toggleRecording(onFinish: @escaping (URL?) -> Void) {
        if isRecording {
            output.stopRecording()
            return
        }
        finishHandler = onFinish
        let url = AppSettings.newRecordingURL(prefix: "摄像头录制")
        if let connection = output.connection(with: .video) {
            output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
        }
        output.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        elapsed = 0
        let began = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.elapsed = Date().timeIntervalSince(began) }
        }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        // Recording may end with a non-fatal error while still producing a usable file.
        let ok = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        Task { @MainActor in
            self.isRecording = false
            self.timer?.invalidate()
            if !ok { self.errorMessage = error?.localizedDescription }
            let handler = self.finishHandler
            self.finishHandler = nil
            handler?(ok ? outputFileURL : nil)
        }
    }
}

struct CameraRecorderView: View {
    let onDone: (URL?) -> Void
    @State private var recorder = CameraRecorder()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("摄像头 / iPhone 录制").font(.title3.bold())
                Spacer()
                Picker("设备", selection: Binding(get: { recorder.selectedID }, set: { recorder.select($0) })) {
                    ForEach(recorder.devices, id: \.uniqueID) { d in
                        Text(d.localizedName).tag(Optional(d.uniqueID))
                    }
                }
                .frame(width: 280)
                .disabled(recorder.isRecording)
            }

            ZStack {
                Color.black
                if recorder.authorized {
                    CapturePreview(session: recorder.session)
                }
                if let msg = recorder.errorMessage {
                    Text(msg).foregroundStyle(.white).padding().multilineTextAlignment(.center)
                } else if recorder.authorized && recorder.devices.isEmpty {
                    Text("没有找到摄像头").foregroundStyle(.white)
                }
                if recorder.isRecording {
                    VStack {
                        HStack {
                            Circle().fill(.red).frame(width: 10, height: 10)
                            Text(String(format: "%d:%02d", Int(recorder.elapsed) / 60, Int(recorder.elapsed) % 60))
                                .monospacedDigit().foregroundStyle(.white)
                        }
                        .padding(8)
                        .background(.black.opacity(0.5), in: Capsule())
                        Spacer()
                    }
                    .padding(10)
                }
            }
            .frame(width: 640, height: 400)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("录制 iPhone/iPad 屏幕：用数据线连接并在设备上“信任此电脑”，然后在上方选择设备。")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("取消") {
                    recorder.stopSession()
                    onDone(nil)
                }
                .keyboardShortcut(.cancelAction)
                .disabled(recorder.isRecording)
                Spacer()
                Button(recorder.isRecording ? "停止并编辑" : "开始录制") {
                    recorder.toggleRecording { url in
                        recorder.stopSession()
                        onDone(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .tint(recorder.isRecording ? .red : nil)
                .disabled(!recorder.authorized || recorder.selectedID == nil)
            }
        }
        .padding(20)
        .task { await recorder.start() }
    }
}

struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        v.layer = layer
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
