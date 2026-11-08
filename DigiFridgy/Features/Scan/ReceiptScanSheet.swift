import SwiftUI
import UIKit
import PhotosUI
import VisionKit

/// Receipt → OCR → parse → normalize → mandatory review → batch write. Never auto-saves OCR output.
struct ReceiptScanSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    /// What one unit cost: the receipt line's total split over its quantity.
    nonisolated static func unitPrice(lineTotal: Double?, count: Int) -> Double? {
        guard let lineTotal, lineTotal > 0 else { return nil }
        return (lineTotal / Double(max(count, 1)) * 100).rounded() / 100
    }

    struct Draft: Identifiable, Hashable {
        let id = UUID()
        var include = true
        var name: String
        var count: Int
        var category: String
        var price: Double?
        var raw: String
    }

    enum Stage: Equatable { case pick, processing(String), review, saving }

    @State private var stage: Stage = .pick
    @State private var drafts: [Draft] = []
    @State private var rawLines: [String] = []
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var usedModel = false

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .pick: pickView
                case .processing(let message):
                    progress(message)
                case .saving:
                    progress("Adding items…")
                case .review: reviewView
                }
            }
            .navigationTitle("Scan receipt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCameraView { images in
                    showCamera = false
                    Task { await process(images: images) }
                } onCancel: {
                    showCamera = false
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    stage = .processing("Reading photo…")
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        await process(images: [image])
                    } else {
                        app.showMessage("Couldn't load that photo.")
                        stage = .pick
                    }
                    photoItem = nil
                }
            }
        }
    }

    private func progress(_ message: String) -> some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(message).foregroundStyle(.secondary)
        }
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: Pick

    private var pickView: some View {
        List {
            Section {
                if VNDocumentCameraViewController.isSupported && !Self.isSimulator {
                    Button("Scan with camera", systemImage: "doc.viewfinder") { showCamera = true }
                }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose receipt photo", systemImage: "photo.on.rectangle")
                }
            } footer: {
                Text("Lay the receipt flat in good light. You'll review every item before anything is added.")
            }
            Section("Sample receipts") {
                ForEach(SampleReceipts.all, id: \.name) { sample in
                    Button("\(sample.name) receipt", systemImage: "doc.text") {
                        Task { await process(lines: sample.text.components(separatedBy: .newlines)) }
                    }
                }
            }
        }
    }

    // MARK: Review

    private var reviewView: some View {
        List {
            if drafts.isEmpty {
                EmptyStateView(symbol: "doc.text.magnifyingglass",
                               title: "No items found",
                               message: "Couldn't read product lines on this receipt. Lay it flat in good light and try again.",
                               primaryTitle: "Retake photo", primary: { stage = .pick })
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach($drafts) { $draft in
                        DraftRow(draft: $draft)
                    }
                } header: {
                    Text("\(drafts.filter(\.include).count) of \(drafts.count) selected")
                } footer: {
                    Label(usedModel ? "Names expanded with the on-device Apple Intelligence model."
                                    : "Names expanded with the abbreviation dictionary.",
                          systemImage: usedModel ? "apple.intelligence" : "character.book.closed")
                }
            }
            if !rawLines.isEmpty {
                Section {
                    DisclosureGroup("Raw OCR text (\(rawLines.count) lines)") {
                        Text(rawLines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !drafts.isEmpty {
                let count = drafts.filter(\.include).count
                Button {
                    Task { await save() }
                } label: {
                    Text("Add \(count) item\(count == 1 ? "" : "s") to fridge").bold()
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .disabled(count == 0)
                .padding()
            }
        }
    }

    // MARK: Processing

    private func process(images: [UIImage]) async {
        stage = .processing("Reading receipt…")
        var lines: [String] = []
        do {
            for image in images {
                guard let cgImage = image.uprightCGImage else { continue }
                lines += try await app.services.ocr.recognizeLines(in: cgImage)
            }
        } catch {
            app.showError(error)
            stage = .pick
            return
        }
        await process(lines: lines)
    }

    private func process(lines: [String]) async {
        rawLines = lines
        stage = .processing("Finding items…")
        let parsed = app.services.parser.parse(lines)
        stage = .processing(app.services.normalizer.usesOnDeviceModel ? "Expanding names with Apple Intelligence…" : "Expanding names…")
        usedModel = app.services.normalizer.usesOnDeviceModel
        let normalized = await app.services.normalizer.normalize(parsed)
        drafts = normalized.map {
            Draft(name: $0.name, count: $0.line.quantity, category: $0.categoryID, price: $0.line.price, raw: $0.line.raw)
        }
        stage = .review
    }

    private func save() async {
        stage = .saving
        let selected = drafts.filter(\.include)
        let uid = app.user?.uid ?? ""
        let products = app.services.products
        // Nutrition via CalorieNinjas by name — best effort, concurrently.
        let nutrition: [UUID: Nutrition] = await withTaskGroup(of: (UUID, Nutrition?).self) { group in
            for draft in selected {
                let name = draft.name
                group.addTask { (draft.id, try? await products.nutrition(forName: name)) }
            }
            var result: [UUID: Nutrition] = [:]
            for await (id, value) in group { if let value { result[id] = value } }
            return result
        }
        let items = selected.map { draft in
            FridgeItem(
                name: draft.name, category: draft.category, count: draft.count, addedBy: uid,
                expiresAt: app.shelfLife.estimatedExpiry(categoryID: draft.category),
                source: .receipt, nutrition: nutrition[draft.id],
                allergens: Allergen.implied(byCategory: draft.category).map(\.rawValue),
                price: ReceiptScanSheet.unitPrice(lineTotal: draft.price, count: draft.count)
            )
        }
        if await app.saveReceiptItems(items) {
            dismiss()
        } else {
            stage = .review
        }
    }
}

private struct DraftRow: View {
    @Environment(AppState.self) private var app
    @Binding var draft: ReceiptScanSheet.Draft

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                draft.include.toggle()
            } label: {
                Image(systemName: draft.include ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(draft.include ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Include \(draft.name.isEmpty ? "item" : draft.name)")
            .accessibilityAddTraits(draft.include ? .isSelected : [])
            .sensoryFeedback(.selection, trigger: draft.include)

            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $draft.name).font(.body.weight(.medium))
                ViewThatFits(in: .horizontal) {
                    HStack { categoryPicker; Spacer(); countStepper }
                    VStack(alignment: .leading) { categoryPicker; countStepper }
                }
                HStack {
                    Text(draft.raw).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    Spacer()
                    Text("Keeps about \(app.shelfLife.fridgeDays(for: draft.category)) days")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .opacity(draft.include ? 1 : 0.45)
        }
    }

    private var categoryPicker: some View {
                    Picker("Category", selection: $draft.category) {
                        ForEach(app.shelfLife.categories) { c in
                            Text("\(CategoryStyle.emoji(for: c.id)) \(c.name)").tag(c.id)
                        }
                        Text("🛒 Other").tag(ShelfLifeService.unknownCategoryID)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
    }

    private var countStepper: some View {
        Stepper("×\(draft.count)", value: $draft.count, in: 1...99)
            .fixedSize()
            .font(.subheadline.monospacedDigit())
            .accessibilityLabel("Quantity")
            .accessibilityValue("\(draft.count)")
    }
}

/// VisionKit document camera; returns every scanned page.
struct DocumentCameraView: UIViewControllerRepresentable {
    var onFinish: ([UIImage]) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish, onCancel: onCancel) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onFinish: ([UIImage]) -> Void
        let onCancel: () -> Void

        init(onFinish: @escaping ([UIImage]) -> Void, onCancel: @escaping () -> Void) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            onFinish((0..<scan.pageCount).map { scan.imageOfPage(at: $0) })
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: any Error) {
            onCancel()
        }
    }
}

extension UIImage {
    /// Redraws with `.up` orientation so Vision sees the text upright.
    var uprightCGImage: CGImage? {
        if imageOrientation == .up, let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }
}
