//
//  ContentView.swift
//  Nexus Integrator
//
//  Created by Hever Gonzalez on 03/12/25.
//

import SwiftUI

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
    
   
    // Conversión
    //enum Quality: String, CaseIterable { case auto = "Auto", p720 = "720p", p1080 = "1080p", original = "Original" }
    enum Quality: String, CaseIterable { case auto = "Auto", original = "Original" }
    @State private var convertToMP4 = true
    @State private var quality: Quality = .original

    // Ubicación
    @StateObject private var location = LocationService.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos])) {
                            Label("", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity).padding(10)
                                .background(Color(.systemGray6)).cornerRadius(12)
                        }
                        Button { showCameraPhoto = true } label: {
                            Label("", systemImage: "camera").frame(maxWidth: .infinity).padding(10).background(Color(.systemGray6)).cornerRadius(12)
                        }
                        Button { showCameraVideo = true } label: {
                            Label("", systemImage: "video").frame(maxWidth: .infinity).padding(10).background(Color(.systemGray6)).cornerRadius(12)
                        }
                    }
                    .buttonStyle(.plain)
                    .onChange(of: selection) { oldItem, newItem in
                        Task {
                            await loadFromPicker(item: newItem)
                        }
                    }

                    if let img = preview {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 260)
                                .cornerRadius(12).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                            if isVideo { Image(systemName: "play.circle.fill").font(.system(size: 36)).symbolRenderingMode(.hierarchical).padding(8) }
                        }
                    } else { Text("Selecciona o captura una imagen/video").foregroundStyle(.secondary) }

                    // Conversión
                    if isVideo {
                        Toggle("Convertir a MP4 (H.264)", isOn: $convertToMP4)
                        Picker("Calidad", selection: $quality) {
                            ForEach(Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    // Metadatos
                    Group {
                        
                        TextField("Asignación / Evento", text: $assignment).textContentType(.none).padding().background(Color(.systemGray6)).cornerRadius(10)
                        //TextField("Personas", text: $people).padding().background(Color(.systemGray6)).cornerRadius(10)
                        TextField("Lugar", text: $placeName).padding().background(Color(.systemGray6)).cornerRadius(10)
                        TextField("Crédito (autor)", text: $credit).padding().background(Color(.systemGray6)).cornerRadius(10)
                        //TextField("Derechos/licencia", text: $rights).padding().background(Color(.systemGray6)).cornerRadius(10)
                        //TextField("Notas", text: $notes, axis: .vertical).lineLimit(2...4).padding().background(Color(.systemGray6)).cornerRadius(10)
                        HStack(spacing: 8) {
                            Image(systemName: "location")
                            Text(location.summary).font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                            Button("Actualizar") { location.request() }
                        }
                    }

                    Button { Task { await upload() } } label: {
                        HStack { if isUploading { ProgressView().padding(.trailing, 6) }; Text(isUploading ? "Subiendo…" : "Subir al CMS").fontWeight(.semibold) }
                            .frame(maxWidth: .infinity).padding()
                            .background((isUploading || data == nil) ? Color.gray.opacity(0.3) : Color.accentColor)
                            .foregroundColor((isUploading || data == nil) ? .secondary : .white)
                            .cornerRadius(12)
                    }.disabled(isUploading || data == nil)

                    if let status { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Spacer(minLength: 20)
                }
                .padding()
                .navigationTitle("Subir")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
                .sheet(isPresented: $showCameraPhoto) {
                    CameraPicker(mode: .photo) { ui in
                        if let jpeg = ui.jpegData(compressionQuality: 1.0) {
                            // 1) Guardar en sandbox de la app
                            if let localURL = try? LocalMediaStore.savePhotoToApp(data: jpeg, ext: "jpg", excludeFromBackup: false) {
                                print("Foto guardada en app:", localURL.path)
                                self.selectedLocalURL = localURL       // 👈 guarda URL
                            }

                            // 2) (Opcional) Guardar también en Fotos
                            LocalMediaStore.savePhotoToPhotosLibrary(data: jpeg) { result in
                                if case .failure(let e) = result { print("Fotos error:", e.localizedDescription) }
                            }

                            // 3) Asignar para subir (lo que ya hacías)
                            self.data = jpeg
                            self.preview = UIImage(data: jpeg)
                            self.selectedMime = "image/jpeg"
                            self.selectedFilename = suggestedFilename(ext: "jpg")
                            self.isVideo = false
                        }
                    } onVideo: { _ in } onCancel: { }
                    .ignoresSafeArea()
                     
                    /*ProCameraView(initialAspect: .fourThree) { ui in
                            // 1) Guardar en sandbox (como hacías)
                            if let jpeg = ui.jpegData(compressionQuality: 1.0) {
                                if let localURL = try? LocalMediaStore.savePhotoToApp(data: jpeg, ext: "jpg", excludeFromBackup: false) {
                                    print("Foto guardada en app:", localURL.path)
                                }
                                // (Opcional) guardar en Fotos
                                LocalMediaStore.savePhotoToPhotosLibrary(data: jpeg) { result in
                                    if case .failure(let e) = result { print("Fotos error:", e.localizedDescription) }
                                }
                                // 2) Preparar para subir
                                self.data = jpeg
                                self.preview = UIImage(data: jpeg)
                                self.selectedMime = "image/jpeg"
                                self.selectedFilename = suggestedFilename(ext: "jpg")
                                self.isVideo = false
                            }
                            showCameraPhoto = false
                        } onCancel: {
                            showCameraPhoto = false
                        }
                        .ignoresSafeArea()*/
                }
                .sheet(isPresented: $showCameraVideo) {
                    CameraPicker(mode: .video) { _ in } onVideo: { url in
                        Task {
                            do {
                                // 1) Convertir si lo tienes activado
                                let finalURL: URL
                                if convertToMP4 {
                                    let preset = presetForQuality(quality, source: url)
                                    finalURL = try await exportToMP4(sourceURL: url, preset: preset)
                                } else {
                                    finalURL = url
                                }

                                // 2) Guardar en sandbox de la app
                                if let localURL = try? LocalMediaStore.saveVideoToApp(from: finalURL, extOverride: finalURL.pathExtension, excludeFromBackup: true) {
                                    self.selectedLocalURL = localURL       // 👈 guarda URL
                                    print("Video guardado en app:", localURL.path)
                                }

                                // 3) (Opcional) Guardar también en Fotos
                                LocalMediaStore.saveVideoToPhotosLibrary(fileURL: finalURL) { result in
                                    if case .failure(let e) = result { print("Fotos error:", e.localizedDescription) }
                                }

                                // 4) Asignar para subir (lo que ya hacías)
                                let d = try Data(contentsOf: finalURL)
                                self.data = d
                                self.preview = try? generateThumbnail(url: finalURL)
                                let ext = finalURL.pathExtension.lowercased()
                                self.selectedMime = (ext == "mp4") ? "video/mp4" : "video/quicktime"
                                self.selectedFilename = suggestedFilename(ext: ext.isEmpty ? "mp4" : ext)
                                self.isVideo = true
                            } catch {
                                self.status = "Error al preparar video: \(error.localizedDescription)"
                            }
                        }
                    } onCancel: { }
                    .ignoresSafeArea()
                }
            }
        }
        .onAppear {
            switch autoOpen {
                case .some(.photo):
                    showCameraPhoto = true
                case .some(.video):
                    showCameraVideo = true
                case .none:
                    break
            }
        }
        .onAppear { location.request() }
    }

    private func loadFromPicker(item: PhotosPickerItem?) async {
        guard let item = item else { return }
        do {
            // 1) Intentar como VIDEO usando Transferable propio
            if let picked = try await item.loadTransferable(type: PickedVideo.self) {
                do {
                    let finalURL: URL
                    if convertToMP4 {
                        let preset = presetForQuality(quality, source: picked.url)
                        finalURL = try await exportToMP4(sourceURL: picked.url, preset: preset)
                        self.selectedLocalURL = finalURL
                    } else {
                        finalURL = picked.url
                        self.selectedLocalURL = finalURL
                    }

                    let d = try Data(contentsOf: finalURL)
                    self.data = d
                    self.preview = try? generateThumbnail(url: finalURL)
                    let ext = finalURL.pathExtension.lowercased()
                    self.selectedMime = (ext == "mp4") ? "video/mp4" : "video/quicktime"
                    self.selectedFilename = suggestedFilename(ext: ext.isEmpty ? "mp4" : ext)
                    self.isVideo = true
                } catch {
                    self.status = "Error al preparar video: \(error.localizedDescription)"
                }
                return
            }

            // 2) Si no fue video, intentar como IMAGEN (Data -> UIImage)
            if let raw = try await item.loadTransferable(type: Data.self),
               let ui = UIImage(data: raw) {
                let jpeg = ui.jpegData(compressionQuality: 1.0) ?? raw
                self.data = jpeg
                self.preview = UIImage(data: jpeg)
                self.selectedMime = "image/jpeg"
                self.selectedFilename = suggestedFilename(ext: "jpg")
                self.isVideo = false
                return
            }

            self.status = "No se pudo leer el medio seleccionado."
        } catch {
            self.status = error.localizedDescription
        }
    }

    private func generateThumbnail(url: URL) throws -> UIImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true
        let cg = try gen.copyCGImage(at: CMTime(seconds: 0.0, preferredTimescale: 600), actualTime: nil)
        return UIImage(cgImage: cg)
    }

    private func upload() async {
        
        // Antes de construir el request:
        if let t = Keychain.loadToken(), TokenUtils.isExpired(t) {
            NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
            self.status = "Sesión expirada. Inicia sesión nuevamente."
            return
        }
        
        guard let data = data else { return }
        isUploading = true; status = "Subiendo…"; defer { isUploading = false }
        let filename = selectedFilename ?? suggestedFilename(ext: isVideo ? "mp4" : "jpg")
        let mime = selectedMime ?? (isVideo ? "video/mp4" : "image/jpeg")

        // Merge fields (editoriales + gps) con los extraFields del config
        var fields = PayloadConfig.extraFields
        fields["title"] = "Subido desde Nexus por \(app.name ?? app._id ?? "")"

        if !assignment.isEmpty { fields["assignment"] = assignment }
        if !notes.isEmpty { fields["notes"] = notes }
        if !credit.isEmpty { fields["credit"] = credit }
        if !rights.isEmpty { fields["rights"] = rights }
        if !people.isEmpty { fields["people"] = people }
        if !placeName.isEmpty { fields["placeName"] = placeName }
        if let loc = location.last {
            fields["gps_lat"] = "\(loc.coordinate.latitude)"
            fields["gps_lon"] = "\(loc.coordinate.longitude)"
            fields["gps_alt"] = String(format: "%.1f", loc.altitude)
            if let h = location.lastHeading { fields["gps_heading"] = String(format: "%.0f", h.trueHeading > 0 ? h.trueHeading : h.magneticHeading) }
        }
        
        // 🔵 Política: video SIEMPRE al background (y opcional: archivos >15MB)
        if let fileURL = selectedLocalURL,
           let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize),
           size > 15 * 1024 * 1024 {   // >10MB
            let safeFields = ensureAltTitle(fields)

            do {
                try BackgroundUploader.shared.enqueueFile(
                    fileURL: fileURL,
                    filename: filename,
                    mimeType: mime,
                    fields: safeFields,
                    token: Keychain.loadToken()
                )
                self.status = "Enviado a segundo plano ✅"
                onSuccess()
                return
            } catch {
                self.status = "No se pudo encolar en BG: \(error.localizedDescription)"
                // si falla, seguirá el flujo normal (data) abajo
            }
        }

        do {
            let (req, _) = try MultipartBuilder.makeRequest(
                url: PayloadConfig.uploadURL,
                fileFieldName: "file",
                filename: filename,
                mimeType: mime,
                fileData: data,
                fields: fields,
                bearerToken: Keychain.loadToken()
            )
            let (respData, resp) = try await URLSession.shared.data(for: req)
            
            guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            if (200..<300).contains(http.statusCode) {
                self.status = "¡Listo!"
                let obj = try JSONSerialization.jsonObject(with: respData) as! [String: Any]
                let doc = obj["doc"] as! [String: Any]
                let urlStr = doc["url"] as! String
                let titleStr = doc["filename"] as! String
                let fileSize = doc["filesizeMB"] as! String
                let timestamp = doc["createdAt"] as! String
                let assetId = doc["id"] as! String
                let urlCMS = "https://backend-payload-cms-staging.nmas.live/admin/collections/media/" + assetId

                UIPasteboard.general.string = String(data: respData, encoding: .utf8) // opcional: copia respuesta
                Task {
                    try? await avisarSlackAssetListo(
                        webhookURL: "https://hooks.slack.com/services/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",
                        assetNombre: titleStr,
                        assetTamano: fileSize, // Añadido para los detalles
                        usuario: app.name ?? app._id ?? "",     // Añadido para los detalles
                        timestamp: timestamp,   // Añadido para los detalles
                        assetImageURL: URL(string: urlStr)!,  // URL de la imagen (storage)
                        cmsURL: URL(string: urlCMS)!
                                        
                    )
                }
                
                if(isVideo){
                    print(urlStr)
                    let meta = AltaVideoMeta(
                        sourceFileName: "clip-\(Int(Date().timeIntervalSince1970)).mp4",
                        masterVideoURL: URL(string: urlStr)!,
                        //snapshotURL: URL(string: "https://www.nmas.com.mx/_next/static/media/screen-foro.d029a8a9.jpg"),
                        title: assignment,
                        description: notes,
                        programID: "2479"
                    )
                    
                    Task {
                        do {
                            let r = try await AktaIngestService.ingest(meta)
                            print("INGEST status:", r.statusCode, "body:", r.body)
                            // 2xx => ok; si no, imprime el body para depurar firma/params
                        } catch {
                            print("INGEST error:", error.localizedDescription)
                        }
                    }
                }
                onSuccess()
            } else {
                //let body = String(data: respData, encoding: .utf-8) or "<sin cuerpo>"
                if http.statusCode == 401 || http.statusCode == 403 {
                    NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
                    self.status = "Sesión expirada. Inicia sesión nuevamente."
                    return
                }
                let body = String(data: respData, encoding: .utf8) ?? "<sin cuerpo>";
                throw NSError(domain: "Upload", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            }
        } catch {
            // Encola para subir luego
            let item = PendingUpload(filename: filename, mimeType: mime, data: data, fields: ensureAltTitle(fields), token: Keychain.loadToken())
            do {
                try UploadQueue.shared.enqueue(item)
                self.status = "Sin conexión o error. Guardado en COLA para reintento."
                onSuccess()
            } catch {
                self.status = "No se pudo guardar en cola: \(error.localizedDescription)"
            }
        }
    }

    private func suggestedFilename(ext: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "capture-\(stamp).\(ext)"
    }

    private func presetForQuality(_ q: Quality, source: URL) -> String {
        switch q {
        case .original:
            return AVAssetExportPresetPassthrough   // conserva resolución/códec si es posible
        case .auto:
            return AVAssetExportPresetHighestQuality // deja que iOS elija, suele conservar 4K si el origen lo es
        }
    }
}

// MARK: - Multipart Builder
struct MultipartBuilder {
    let boundary: String = "Boundary-\(UUID().uuidString)"

    func makeRequest(url: URL,
                     method: String = "POST",
                     fields: [String: Any],
                     fileData: Data,
                     fileName: String,
                     mimeType: String,
                     token: String?) throws -> URLRequest {

        var request = URLRequest(url: url)
        request.httpMethod = method

        var body = Data()

        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        for (k, v) in fields {
            switch v {
            case let s as String:
                appendField(name: k, value: s)
            case let b as Bool:
                appendField(name: k, value: b ? "true" : "false")
            case let i as Int:
                appendField(name: k, value: "\(i)")
            case let d as Double:
                appendField(name: k, value: "\(d)")
            default:
                continue
            }
        }

        // Parte del archivo
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        if let token {
            request.setValue("JWT \(token)", forHTTPHeaderField: "Authorization")
        }

        return request
    }
}

// MARK: - 1. Estructura Principal del Payload (Cuerpo de la solicitud HTTP)
struct SlackPayload: Encodable {
    var text: String
    var blocks: [SlackBlock]
}

enum SlackBlockType: String, Encodable {
    case section
    case actions
    case header
    case divider
    case context
}

protocol SlackBlock: Encodable {
    var type: SlackBlockType { get }
}

// MARK: - 2. Bloque Genérico
struct SectionBlock: SlackBlock {
    let type: SlackBlockType = .section
    var text: SlackTextObject?
    var fields: [SlackTextObject]?
    var accessory: SlackAccessory?

    enum CodingKeys: String, CodingKey {
        case type, text, fields, accessory
    }
}

struct HeaderBlock: SlackBlock {
    let type: SlackBlockType = .header
    var text: SlackTextObject

    enum CodingKeys: String, CodingKey {
        case type, text
    }
}

struct DividerBlock: SlackBlock {
    let type: SlackBlockType = .divider

    enum CodingKeys: String, CodingKey {
        case type
    }
}

struct ContextBlock: SlackBlock {
    let type: SlackBlockType = .context
    var elements: [SlackTextObject]

    enum CodingKeys: String, CodingKey {
        case type, elements
    }
}

struct ActionsBlock: SlackBlock {
    let type: SlackBlockType = .actions
    var elements: [SlackElement]

    enum CodingKeys: String, CodingKey {
        case type, elements
    }
}

// MARK: - 3. Objetos de Texto Comunes
struct SlackTextObject: Encodable {
    var type: String = "mrkdwn"
    var text: String
}

struct SlackAccessory: Encodable {
    var type: String
    var image_url: String?
    var alt_text: String?
    var fallback: String?

    enum CodingKeys: String, CodingKey {
        case type, image_url, alt_text, fallback
    }
}

protocol SlackElement: Encodable {}

struct SlackButtonElement: SlackElement {
    var type: String = "button"
    var text: SlackTextObject
    var url: String?
    var action_id: String?
}

// MARK: - 4. Elementos de Acción (Botones)

func avisarSlackAssetListo(assetId: String,
                           filename: String,
                           size: Int?,
                           mimeType: String,
                           userName: String,
                           assignment: String,
                           place: String) async {
    guard let webhookString = ProcessInfo.processInfo.environment["SLACK_WEBHOOK"],
          let url = URL(string: webhookString) else {
        print("No se encontró SLACK_WEBHOOK en variables de entorno")
        return
    }

    let title = "Nuevo asset cargado desde App Nexus"
    let mainText = "*\(filename)* (\(mimeType)) fue subido por *\(userName)*."

    var fields: [SlackTextObject] = []
    if !assignment.isEmpty {
        fields.append(SlackTextObject(text: "*Asignación:* \(assignment)"))
    }
    if !place.isEmpty {
        fields.append(SlackTextObject(text: "*Lugar:* \(place)"))
    }
    if let size {
        let kb = Double(size) / 1024.0
        fields.append(SlackTextObject(text: String(format: "*Tamaño:* %.1f KB", kb)))
    }

    let header = HeaderBlock(text: SlackTextObject(text: title))
    let section = SectionBlock(text: SlackTextObject(text: mainText),
                               fields: fields.isEmpty ? nil : fields,
                               accessory: nil)
    let divider = DividerBlock()

    // Botones de acción
    let verEnCMS = SlackButtonElement(
        text: SlackTextObject(text: "Ver en Payload"),
        url: "\(PayloadConfig.originURL)/admin/collections/media/\(assetId)",
        action_id: "ver_en_cms"
    )

    let blocks: [SlackBlock] = [
        header,
        section,
        divider,
        ActionsBlock(elements: [verEnCMS])
    ]

    let payload = SlackPayload(
        text: mainText,
        blocks: blocks
    )

    do {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        req.httpBody = try enc.encode(AnySlackPayload(payload: payload))

        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
            print("Slack webhook respondió \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
    } catch {
        print("Error enviando a Slack: \(error)")
    }
}

// Helper para codificar [SlackBlock] heterogéneos
struct AnySlackPayload: Encodable {
    let payload: SlackPayload

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(payload.text, forKey: .text)

        var blocksContainer = container.nestedUnkeyedContainer(forKey: .blocks)
        for block in payload.blocks {
            switch block {
            case let h as HeaderBlock:
                try blocksContainer.encode(h)
            case let s as SectionBlock:
                try blocksContainer.encode(s)
            case let a as ActionsBlock:
                try blocksContainer.encode(a)
            case let d as DividerBlock:
                try blocksContainer.encode(d)
            case let c as ContextBlock:
                try blocksContainer.encode(c)
            default:
                break
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case text, blocks
    }
}
