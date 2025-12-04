//
//  ContentView.swift
//  Nexus Integrator
//
//  Created by Hever Gonzalez on 03/12/25.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
    }
}

#Preview {
    ContentView()
}

// MARK: - Vista de la Cola
struct QueueView: View {
    @ObservedObject var q = UploadQueue.shared

    var body: some View {
        NavigationView {
            List {
                if q.items.isEmpty {
                    Text("No hay elementos en cola")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(q.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.filename)
                                .font(.headline)
                            Text(item.mimeType)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Reintentar ahora") {
                                    UploadQueue.shared.forceKick()
                                }
                                Button("Eliminar", role: .destructive) {
                                    try? UploadQueue.shared.remove(id: item.id)
                                    UploadQueue.shared.forceKick()
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .navigationTitle("Cola")
        }
    }
}


// MARK: - Cola Offline de Subidas
struct PendingUpload: Codable, Identifiable, Equatable {
    let id: String
    let filename: String
    let mimeType: String
    let dataBase64: String
    let fields: [String: String]
    let token: String?

    init(filename: String, mimeType: String, data: Data, fields: [String: String], token: String?) {
        self.id = UUID().uuidString
        self.filename = filename
        self.mimeType = mimeType
        self.dataBase64 = data.base64EncodedString()
        self.fields = fields
        self.token = token
    }

    var data: Data {
        Data(base64Encoded: dataBase64) ?? Data()
    }
}

final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()
    @Published private(set) var items: [PendingUpload] = []

    private let storeURL: URL
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "UploadQueue")
    private var isProcessing = false

    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storeURL = dir.appendingPathComponent("pending-uploads.json")
        self.items = (try? Self.load(from: storeURL)) ?? []

        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied {
                self?.processNext()
            }
        }
        monitor.start(queue: queue)
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.forceKick()
        }
        processNext()
    }

    func forceKick() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isProcessing {
                self.processNext()
            }
        }
    }

    func enqueue(_ item: PendingUpload) throws {
        items.append(item)
        try persist()
        forceKick()
    }

    func remove(id: String) throws {
        items.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: storeURL, options: .atomic)
        DispatchQueue.main.async {
            self.objectWillChange.send()
        }
    }

    private static func load(from url: URL) throws -> [PendingUpload] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PendingUpload].self, from: data)
    }

    private func processNext() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isProcessing, let next = self.items.first else { return }
            self.isProcessing = true

            Task {
                defer { self.isProcessing = false }
                do {
                    let safeFields = ensureAltTitle(next.fields)

                    let request = try MultipartBuilder().makeRequest(
                        url: PayloadConfig.uploadURL,
                        method: "POST",
                        fields: safeFields,
                        fileData: next.data,
                        fileName: next.filename,
                        mimeType: next.mimeType,
                        token: next.token
                    )

                    let (dataResp, resp) = try await URLSession.shared.data(for: request)
                    guard let http = resp as? HTTPURLResponse else {
                        throw NSError(domain: "UploadQueue", code: -1, userInfo: [NSLocalizedDescriptionKey: "Respuesta inválida"])
                    }

                    if (200..<300).contains(http.statusCode) {
                        // éxito → lo sacamos de la cola
                        try self.remove(id: next.id)
                        self.processNext()
                    } else {
                        let body = String(data: dataResp, encoding: .utf8) ?? "<sin cuerpo>"
                        throw NSError(domain: "UploadQueue", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
                    }
                } catch {
                    // Error de red → reintento simple más adelante
                    self.scheduleRetry()
                }
            }
        }
    }

    // reintento simple (+ puedes mejorarlo en RF-05)
    private func scheduleRetry() {
        let delay: TimeInterval = 10
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processNext()
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
