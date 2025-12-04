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
