import SwiftUI
import VisionKit
import Vision

/// Scan → look up → (increment existing | confirm new | ask for a name when unknown).
struct BarcodeScanSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    enum Stage: Equatable {
        case scanning
        case lookingUp(String)
        case unknown(String)
        case confirm
    }

    @State private var stage: Stage = .scanning
    @State private var draft: FridgeItem?
    /// What the lookup returned before the user's edits; nil when the user typed the product in.
    @State private var lookedUp: FridgeItem?
    @State private var manualCode = ""
    @State private var unknownName = ""
    @State private var scanCount = 0
    @State private var isSaving = false

    private var scannerAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .scanning:
                    scanningView
                case .lookingUp(let code):
                    VStack(spacing: 16) {
                        ProgressView().controlSize(.large)
                        Text("Looking up \(code)…").foregroundStyle(.secondary)
                    }
                case .unknown(let code):
                    unknownView(code)
                case .confirm:
                    if let draft {
                        ItemConfirmationView(draft: draft,
                                             usesSavedCorrections: app.hasSavedCorrections(barcode: draft.barcode),
                                             isSaving: isSaving) { saved in
                            guard !isSaving else { return }
                            isSaving = true
                            Task {
                                let ok = await app.saveScanned(saved, original: lookedUp)
                                isSaving = false
                                if ok {
                                    scanCount += 1
                                    app.showMessage("Added \(saved.name)")
                                    dismiss()
                                }
                            }
                        } onRescan: {
                            self.draft = nil
                            stage = .scanning
                        }
                    }
                }
            }
            .navigationTitle(stage == .confirm ? "Add to fridge" : "Scan barcode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sensoryFeedback(.success, trigger: scanCount)
    }

    // MARK: Scanning

    private var scanningView: some View {
        VStack(spacing: 0) {
            if scannerAvailable {
                BarcodeScannerView { code in handle(code) }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point at a barcode (EAN-13, EAN-8, UPC-E)")
                            .font(.footnote)
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .glassEffect(.regular, in: .capsule)
                            .padding(.bottom, 24)
                    }
                manualEntry.padding()
            } else {
                Form {
                    Section {
                        Label("The camera can't scan barcodes on this device. Type the number under the barcode instead.",
                              systemImage: "camera.badge.ellipsis")
                            .font(.subheadline)
                    }
                    Section("Barcode") {
                        TextField("e.g. 0078742351865", text: $manualCode)
                            .keyboardType(.numberPad)
                            .font(.body.monospaced())
                        Button("Look up") { handle(manualCode) }
                            .disabled(manualCode.filter(\.isNumber).count < 8)
                    }
                    Section("Test barcodes") {
                        ForEach(DemoData.seedBarcodes, id: \.code) { seed in
                            Button {
                                handle(seed.code)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(seed.label)
                                    Text(seed.code).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var manualEntry: some View {
        HStack {
            TextField("Or type a barcode", text: $manualCode)
                .keyboardType(.numberPad)
                .font(.body.monospaced())
                .filledField()
            Button("Go") { handle(manualCode) }
                .buttonStyle(.glassProminent)
                .disabled(manualCode.filter(\.isNumber).count < 8)
        }
    }

    // MARK: Unknown product

    private func unknownView(_ code: String) -> some View {
        Form {
            Section {
                Label("Open Food Facts doesn't know \(code) yet.", systemImage: "questionmark.circle")
            }
            Section("What is it?") {
                TextField("e.g. Baby spinach", text: $unknownName)
                Button("Continue") {
                    Task {
                        stage = .lookingUp(code)
                        draft = await app.draft(name: unknownName, barcode: code)
                        lookedUp = nil
                        stage = .confirm
                    }
                }
                .disabled(unknownName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Section {
                Button("Scan another") { stage = .scanning }
            }
        }
    }

    // MARK: Flow

    private func handle(_ raw: String) {
        let code = Barcode.normalize(raw)
        guard code.count >= 8, case .scanning = stage else { return }
        scanCount += 1
        manualCode = ""

        // Same product with the same fresh estimate and no recall flag: just add one. Otherwise the scan
        // becomes a new unit with its own expiry estimate (it doesn't inherit an old date or flag).
        if let existing = app.bumpableItem(barcode: code) {
            Task {
                await app.adjustCount(existing, by: 1)
                app.showMessage("Added another \(existing.name) (now \(existing.count + 1))")
                dismiss()
            }
            return
        }

        stage = .lookingUp(code)
        Task {
            do {
                if let scanned = try await app.draftForScan(barcode: code) {
                    draft = scanned
                    lookedUp = scanned
                    stage = .confirm
                } else {
                    unknownName = ""
                    stage = .unknown(code)
                }
            } catch {
                app.showError(error)
                unknownName = ""
                stage = .unknown(code)
            }
        }
    }
}

/// VisionKit live barcode scanner. Pauses after the first hit.
struct BarcodeScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean13, .ean8, .upce])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.onScan = onScan
        if !controller.isScanning && !context.coordinator.didScan {
            Task { @MainActor in try? controller.startScanning() }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScan: (String) -> Void
        var didScan = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !didScan else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let code = barcode.payloadStringValue {
                    didScan = true
                    dataScanner.stopScanning()
                    onScan(code)
                    return
                }
            }
        }
    }
}
