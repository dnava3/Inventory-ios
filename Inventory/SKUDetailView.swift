import SwiftUI
import PhotosUI

struct SKUDetailView: View {
    let sku: String

    @State private var pickedItem: PhotosPickerItem? = nil
    @State private var uiImage: UIImage? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sku)
                            .font(.largeTitle.weight(.semibold))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)

                        Text("Toca la imagen para cambiarla")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                GlassCard {
                    PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)

                            if let img = uiImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                    .padding(6)
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "photo")
                                        .font(.system(size: 34, weight: .semibold))
                                    Text("Agregar foto")
                                        .font(.headline)
                                    Text("Opcional")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(24)
                            }
                        }
                        .frame(height: 260)
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Acciones")
                            .font(.headline)

                        Button {
                            ImageStore.deleteImage(for: sku)
                            uiImage = nil
                        } label: {
                            Label("Eliminar foto", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(uiImage == nil)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Detalle")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            uiImage = ImageStore.loadImage(for: sku)
        }
        .onChange(of: pickedItem) { _, newValue in
            guard let item = newValue else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    ImageStore.saveImageData(data, for: sku)
                    await MainActor.run { self.uiImage = img }
                }
            }
        }
    }
}

enum ImageStore {
    static func url(for sku: String) -> URL {
        let safe = sku
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent("sku_\(safe).jpg")
    }

    static func saveImageData(_ data: Data, for sku: String) {
        let u = url(for: sku)
        do { try data.write(to: u, options: [.atomic]) }
        catch { print("Save image error: \(error)") }
    }

    static func loadImage(for sku: String) -> UIImage? {
        let u = url(for: sku)
        guard let data = try? Data(contentsOf: u) else { return nil }
        return UIImage(data: data)
    }

    static func deleteImage(for sku: String) {
        try? FileManager.default.removeItem(at: url(for: sku))
    }
}
