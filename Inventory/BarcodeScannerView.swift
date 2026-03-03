import SwiftUI
import AVFoundation
import Combine
import UIKit

final class BarcodeScannerModel: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    let session = AVCaptureSession()
    @Published var isAuthorized = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined

    @Published var torchOn = false
    private var captureDevice: AVCaptureDevice?

    private var lastCode: String?
    private var lastTime: Date = .distantPast

    var onCode: ((String) -> Void)?

    @MainActor
    func configure() async {
        authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authorizationStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = granted ? .authorized : .denied
        }
        isAuthorized = (authorizationStatus == .authorized)
        guard isAuthorized else { return }
        setupSession()
    }

    @MainActor
    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        self.captureDevice = device

        let metadata = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadata) else {
            session.commitConfiguration()
            return
        }
        session.addOutput(metadata)
        metadata.setMetadataObjectsDelegate(self, queue: .main)
        metadata.metadataObjectTypes = [
            .ean13, .ean8, .upce,
            .code128, .code39, .code93, .itf14,
            .qr, .pdf417
        ]

        session.commitConfiguration()
    }

    func start() {
        guard isAuthorized else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func toggleTorch() {
        guard let device = captureDevice, device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            if device.torchMode == .on {
                device.torchMode = .off
                torchOn = false
            } else {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                torchOn = true
            }
            device.unlockForConfiguration()
        } catch {
            print("Torch error: \(error)")
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard
            let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            let value = obj.stringValue
        else { return }

        let now = Date()
        if value == lastCode, now.timeIntervalSince(lastTime) < 1.0 { return }
        lastCode = value
        lastTime = now
        onCode?(value)
    }
}

struct BarcodeScannerView: View {
    @StateObject private var model = BarcodeScannerModel()
    var onCode: (String) -> Void
    @State private var qty: Int = 1
    @State private var movementType: Int = 0
    @State private var lastCode: String = ""

    var body: some View {
        ZStack {
            #if targetEnvironment(simulator)
            VStack(spacing: 12) {
                Text("Simulador sin cámara")
                Button("Simular escaneo (7501032900001)") { onCode("7501032900001") }
            }
            .padding()
            #else
            if model.isAuthorized {
                ZStack {
                    CameraPreview(session: model.session)
                        .ignoresSafeArea()
                        .onAppear {
                            model.onCode = { code in
                                if lastCode != code {
                                    lastCode = code
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    onCode(code)
                                }
                            }
                            model.start()
                        }
                        .onDisappear { model.stop() }

                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                model.toggleTorch()
                            } label: {
                                Image(systemName: model.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.title3)
                                    .padding(10)
                                    .background(.ultraThinMaterial, in: Circle())
                            }
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                        }
                        Spacer()
                        VStack(spacing: 10) {
                            Picker("Tipo", selection: $movementType) {
                                Text("Entrada").tag(0)
                                Text("Consumo").tag(1)
                                Text("Ajuste").tag(2)
                            }
                            .pickerStyle(.segmented)

                            HStack {
                                Stepper("Cantidad: \(qty)", value: $qty, in: 1...10000)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(lastCode.isEmpty ? "—" : lastCode)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Button {
                                guard !lastCode.isEmpty else { return }
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                NotificationCenter.default.post(name: Notification.Name("ScanAction"), object: nil, userInfo: ["code": lastCode, "qty": qty, "type": movementType])
                                NotificationCenter.default.post(name: Notification.Name("InventoryUpdated"), object: nil)
                            } label: {
                                Label("Registrar", systemImage: "checkmark.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            } else if model.authorizationStatus == .denied {
                VStack(spacing: 10) {
                    Text("Sin permiso de cámara").font(.headline)
                    Text("Ve a Ajustes → Privacidad → Cámara y activa el permiso para esta app.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                }
                .padding()
            } else {
                ProgressView("Solicitando acceso a la cámara…")
                    .task {
                        await model.configure()
                        if model.isAuthorized { model.start() }
                    }
            }
            #endif
        }
        .task {
            #if !targetEnvironment(simulator)
            if !model.isAuthorized { await model.configure() }
            #endif
        }
        .onDisappear { model.stop() }
    }
}
