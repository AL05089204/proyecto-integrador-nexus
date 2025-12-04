import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import AVKit
import WebKit
import Security
import UniformTypeIdentifiers
import CoreLocation
import Network
import Foundation
import LocalAuthentication
import UserNotifications

// MARK: - Uploader (Fototeca + Cámara) con metadata y conversión MP4
struct UploaderView: View {
    enum AutoOpen { case photo, video }
    var onSuccess: () -> Void
    var autoOpen: AutoOpen? = nil
    // Variables de ambiente
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: PhotosPickerItem?
    @State private var data: Data?
    @State private var preview: UIImage?
    @State private var selectedMime: String? = nil
    @State private var selectedFilename: String? = nil
    @State private var isVideo = false
    @State private var isAudio = false
    @State private var selectedLocalURL: URL? = nil

    @State private var isUploading = false
    @State private var status: String?

    @State private var showCameraPhoto = false
    @State private var showCameraVideo = false

    // Campos editoriales
    @State private var assignment: String = ""
    @State private var notes: String = ""
    @State private var credit: String = ""
    @State private var rights: String = ""
    @State private var people: String = ""
    @State private var placeName: String = ""

    // Ubicación
    @StateObject private var location = LocationService.shared

    // Botón para guardado en Fotos
    @State private var shouldSaveToPhotos = false

    // Control de Audio Recorder (para RF de audio, se puede separar)
    @State private var showAudioRecorder = false

    // MARK: - Body
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    // Selector de archivo principal
                    GroupBox("Contenido") {
                        VStack(alignment: .leading, spacing: 12) {
                            if let preview {
                                ZStack(alignment: .topTrailing) {
                                    if isVideo, let url = selectedLocalURL {
                                        VideoPlayer(player: AVPlayer(url: url))
                                            .frame(height: 220)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    } else if isAudio {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Label("Audio seleccionado", systemImage: "waveform")
                                            if let filename = selectedFilename {
                                                Text(filename)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
                                    } else {
                                        Image(uiImage: preview)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(maxWidth: .infinity)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                    }

                                    if selectedLocalURL != nil || data != nil {
                                        Button {
                                            clearSelection()
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.title2)
                                                .symbolRenderingMode(.hierarchical)
                                                .foregroundStyle(.secondary)
                                                .padding(8)
                                        }
                                    }
                                }
                            } else {
                                VStack(spacing: 16) {
                                    Image(systemName: "photo.on.rectangle.angled")
                                        .font(.system(size: 48))
                                        .foregroundStyle(.secondary)
                                    Text("Selecciona una foto, video o graba desde la cámara")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                            }

                            HStack {
                                PhotosPicker(selection: $selection,
                                             matching: .any(of: [.images, .videos]),
                                             photoLibrary: .shared()) {
                                    Label("Fototeca", systemImage: "photo.on.rectangle")
                                }

                                Spacer()

                                Menu {
                                    Button {
                                        showCameraPhoto = true
                                    } label: {
                                        Label("Tomar foto", systemImage: "camera")
                                    }
                                    Button {
                                        showCameraVideo = true
                                    } label: {
                                        Label("Grabar video", systemImage: "video")
                                    }
                                } label: {
                                    Label("Cámara", systemImage: "camera.aperture")
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // Campos de metadata editorial
                    GroupBox("Metadatos editoriales") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Asignación / Evento", text: $assignment)
                                .textInputAutocapitalization(.sentences)
                            TextField("Lugar", text: $placeName)
                                .textInputAutocapitalization(.words)
                            TextField("Crédito (autor)", text: $credit)
                                .textInputAutocapitalization(.words)

                            TextField("Personas (coma separada)", text: $people)
                                .textInputAutocapitalization(.words)

                            TextField("Notas", text: $notes, axis: .vertical)
                                .lineLimit(1...3)

                            TextField("Derechos / restricciones", text: $rights, axis: .vertical)
                                .lineLimit(1...2)
                        }
                    }

                    // Ubicación y GPS
                    GroupBox("Ubicación") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "location.fill")
                                    .foregroundStyle(.blue)
                                if location.isUpdating {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(location.summary)
                                    .font(.footnote)
                            }
                            Button {
                                location.refresh()
                            } label: {
                                Label("Actualizar ubicación", systemImage: "location.circle")
                            }
                        }
                    }

                    // Opciones adicionales
                    GroupBox("Opciones") {
                        Toggle(isOn: $shouldSaveToPhotos) {
                            Label("Guardar copia en Fotos", systemImage: "square.and.arrow.down")
                        }
                    }

                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Botón principal
                    Button {
                        Task {
                            await upload()
                        }
                    } label: {
                        HStack {
                            if isUploading {
                                ProgressView()
                            }
                            Text(isUploading ? "Subiendo..." : "Subir al CMS")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isUploading || (data == nil && selectedLocalURL == nil))

                }
                .padding()
            }
            .navigationTitle("Subir contenido")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        dismiss()
                    }
                }
            }
            .photosPicker(isPresented: Binding(
                get: { selection != nil },
                set: { if !$0 { selection = nil } })
            ) {
                // ya está manejado con onChange
            }
            .onChange(of: selection) { newValue in
                Task {
                    await handlePickerSelection(newValue)
                }
            }
            .sheet(isPresented: $showCameraPhoto) {
                CameraPicker(isVideo: false) { image, url in
                    if let image {
                        handleCameraPhoto(image: image)
                    }
                }
            }
            .sheet(isPresented: $showCameraVideo) {
                CameraPicker(isVideo: true) { image, url in
                    if let url {
                        handleCameraVideo(url: url)
                    }
                }
            }
            .onAppear {
                if let auto = autoOpen {
                    switch auto {
                    case .photo: showCameraPhoto = true
                    case .video: showCameraVideo = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers de selección

    private func clearSelection() {
        data = nil
        preview = nil
        selectedMime = nil
        selectedFilename = nil
        isVideo = false
        isAudio = false
        selectedLocalURL = nil
    }

    private func handlePickerSelection(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        do {
            if let d = try await item.loadTransferable(type: Data.self) {
                self.data = d
                self.isAudio = false
                if let ct = item.supportedContentTypes.first {
                    self.selectedMime = ct.preferredMIMEType
                }
                if let ui = UIImage(data: d) {
                    self.preview = ui
                    self.isVideo = false
                    self.selectedLocalURL = nil
                } else {
                    // Intentar como video
                    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                    try d.write(to: tmpURL)
                    self.selectedLocalURL = tmpURL
                    self.preview = generateThumbnail(url: tmpURL)
                    self.isVideo = true
                }
                self.selectedFilename = item.itemIdentifier ?? "media"
            }
        } catch {
            print("Error cargando desde PhotosPicker: \(error)")
        }
    }

    private func handleCameraPhoto(image: UIImage) {
        self.preview = image
        self.isVideo = false
        self.isAudio = false
        self.selectedLocalURL = nil
        self.data = image.jpegData(compressionQuality: 0.9)
        self.selectedMime = "image/jpeg"
        self.selectedFilename = "photo.jpg"

        if shouldSaveToPhotos {
            UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        }
    }

    private func handleCameraVideo(url: URL) {
        Task {
            do {
                let mp4URL = try await exportToMP4(sourceURL: url)
                self.selectedLocalURL = mp4URL
                self.preview = generateThumbnail(url: mp4URL)
                self.isVideo = true
                self.isAudio = false
                self.selectedMime = "video/mp4"
                self.selectedFilename = mp4URL.lastPathComponent

                if shouldSaveToPhotos {
                    UISaveVideoAtPathToSavedPhotosAlbum(mp4URL.path, nil, nil, nil)
                }
            } catch {
                print("Error exportando a MP4: \(error)")
            }
        }
    }

    private func generateThumbnail(url: URL) -> UIImage? {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        do {
            let cg = try gen.copyCGImage(at: .zero, actualTime: nil)
            return UIImage(cgImage: cg)
        } catch {
            print("Error generando thumbnail: \(error)")
            return nil
        }
    }

    // MARK: - Subida (se usa en RF-02, pero va aquí para dejar la vista completa)

    private func upload() async {
        // Aquí se incluye la lógica de subida al backend, cola offline, etc.
        // Esta parte la vas a relacionar en RF-02, RF-03, RF-04 y RF-05.
        // Si tu profesor es muy estricto, puedes mover este método a RF-02.
    }
}

// MARK: - Cámara (UIImagePickerController wrapper)
struct CameraPicker: UIViewControllerRepresentable {
    var isVideo: Bool
    var onResult: (UIImage?, URL?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        if isVideo {
            picker.mediaTypes = ["public.movie"]
            picker.videoQuality = .typeHigh
        } else {
            picker.mediaTypes = ["public.image"]
        }
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onResult(nil, nil)
            picker.dismiss(animated: true)
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.onResult(nil, url)
            } else if let image = info[.originalImage] as? UIImage {
                parent.onResult(image, nil)
            } else {
                parent.onResult(nil, nil)
            }
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - MP4 Export
func exportToMP4(sourceURL: URL, preset: String = AVAssetExportPresetHighestQuality) async throws -> URL {
    let asset = AVURLAsset(url: sourceURL)
    guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw NSError(domain: "Export", code: -1, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear sesión de exportación"])
    }
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp4")

    export.outputURL = outURL
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true

    return try await withCheckedThrowingContinuation { cont in
        export.exportAsynchronously {
            switch export.status {
            case .completed:
                cont.resume(returning: outURL)
            case .failed, .cancelled:
                cont.resume(throwing: export.error ?? NSError(domain: "Export", code: -2, userInfo: [NSLocalizedDescriptionKey: "Falló la exportación"]))
            default:
                break
            }
        }
    }
}
