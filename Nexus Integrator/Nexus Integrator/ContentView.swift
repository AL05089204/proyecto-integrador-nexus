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
import JWPlayerKit
import LocalAuthentication
import UserNotifications

@preconcurrency import Speech

enum LastLoginEmail {
    private static let key = "last-login-email"

    static func load() -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func save(_ email: String) {
        UserDefaults.standard.set(email, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum PhotoAspect: CaseIterable, Identifiable {
    case square, fourThree, sixteenNine
    var id: String { title }
    var title: String {
        switch self {
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .sixteenNine: return "16:9"
        }
    }
    var ratio: CGFloat {
        switch self {
        case .square: return 1.0
        case .fourThree: return 4.0/3.0
        case .sixteenNine: return 16.0/9.0
        }
    }
}

enum BiometricAuth {
    static func availability() -> (available: Bool, type: LABiometryType) {
        let ctx = LAContext()
        var err: NSError?
        let ok = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
        return (ok, ctx.biometryType)
    }

    static func authenticate(reason: String = "Autentícate para entrar") async -> Bool {
        let ctx = LAContext()
        // Si quieres permitir passcode si no hay Face ID, usa: .deviceOwnerAuthentication
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics

        return await withCheckedContinuation { cont in
            ctx.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                cont.resume(returning: success)
            }
        }
    }
}

struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        // Importar desde la Fototeca (o iCloud) como archivo temporal
        FileRepresentation(importedContentType: .movie) { received in
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.lastPathComponent.split(separator: ".").last.map(String.init) ?? "mov")

            // Limpia si existe y copia el archivo recibido a tu sandbox
            try? FileManager.default.removeItem(at: tmpURL)
            try FileManager.default.copyItem(at: received.file, to: tmpURL)
            return PickedVideo(url: tmpURL)
        }
    }
}

struct SlackTextPayload: Codable { let text: String }

enum SlackNotifyError: Error { case badURL, badStatus(Int) }

// Evento global para avisar "sesión expirada"
enum AuthEvents {
    static let expired = Notification.Name("AuthExpired")
}

extension Notification.Name {
    static let uploadFailed = Notification.Name("UploadFailedNotification")
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        
        
        return true
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        // Para tu identifier del uploader
        if identifier == "com.nmas.nexus.uploads.bg" {
            BackgroundUploader.shared.setBackgroundCompletionHandler(completionHandler)
        } else {
            completionHandler()
        }
    }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a = "M4A (AAC)"
    case wav = "WAV (PCM)"
    var id: String { rawValue }
    var fileExtension: String { self == .m4a ? "m4a" : "wav" }
    var mimeType: String { self == .m4a ? "audio/x-m4a" : "audio/wav" }
}

enum AudioBitrate: Int, CaseIterable, Identifiable {
    case kbps64  = 64_000
    case kbps128 = 128_000
    case kbps192 = 192_000
    var id: Int { rawValue }
    var label: String { "\(rawValue/1000) kbps" }
}

// MARK: - Configuración de Payload
enum PayloadConfig {
    
    static let uploadURL = URL(string: "")!
    static let postsURL = URL(string: "")!

    static let authCollection = "users"

    static let extraFields: [String: String] = [
        "alt": "Subido desde iOS",
        "title": "Subido desde Nexus"
    ]
    
    // Deriva origen (scheme+host+port) de uploadURL para construir URLs absolutas
    static var originURL: URL {
        let comps = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false)!
        var o = URLComponents()
        o.scheme = comps.scheme
        o.host = comps.host
        o.port = comps.port
        return o.url!
    }
    static var apiBase: URL { originURL.appendingPathComponent("api") }
    static var loginURL: URL { apiBase.appendingPathComponent(authCollection).appendingPathComponent("login") }
    static var meURL: URL { apiBase.appendingPathComponent(authCollection).appendingPathComponent("me") }
}

// MARK: - App State
final class AppState: ObservableObject {
    enum Phase { case splash, login, gallery }
    @Published var phase: Phase = .splash
    @Published var token: String? = nil
    @Published var _id: String? = nil
    @Published var name: String? = nil
    @Published var privacyBlur: Bool = false
}

// MARK: - Entry Point
@main
struct PayloadCMSDemoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate   // ⬅️ NUEVO
    @StateObject private var app = AppState()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
        }
    }
}

// MARK: - Root Flow
struct RootView: View {
    @EnvironmentObject var app: AppState
    
    var body: some View {
        Group {
            switch app.phase {
            case .splash:
                SplashView {
                    if let saved = Keychain.loadToken(), !TokenUtils.isExpired(saved, leeway: 15) {
                            app.token = saved; app.phase = .gallery
                    } else if let r = Keychain.loadRefresh() {
                        Task {
                            do {
                                let newAccess = try await APIClient.refresh(using: r)
                                let me = try await APIClient.me(token: newAccess)
                                await MainActor.run {
                                    app.token = newAccess
                                    app._id = me.id
                                    app.name = me.name
                                    //app.name = me.email
                                    app.phase = .gallery
                                }
                            } catch {
                                // refresh falló: limpia y manda a login
                                Keychain.deleteToken()
                                Keychain.deleteRefresh()
                                await MainActor.run { app.phase = .login }
                            }
                        }
                    } else {
                        Keychain.deleteToken()
                        app.phase = .login
                    }
                }
            case .login:
                LoginView()
            case .gallery:
                MainTabsView().onAppear { UploadQueue.shared.start() }
            }
        }.onReceive(NotificationCenter.default.publisher(for: AuthEvents.expired)) { _ in
            signOut()
        }
    }
    private func signOut() {
        Keychain.deleteToken()
        app.token = nil
        app._id = nil
        app.name = nil
        app.phase = .login
    }
}

// MARK: - Splash (animado, con fallback a reduce motion)
struct SplashView: View {
    var onFinish: () -> Void = {} // default para previews o usos simples
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appear = false
    @State private var pulse = false
    @State private var shine = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(.systemBackground), Color(.secondarySystemBackground)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ZStack {
                Image("AppLogo")
                    .renderingMode(.original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
                    .scaleEffect(appear ? 1.0 : 0.82)
                    .opacity(appear ? 1.0 : 0.0)
                    .rotationEffect(.degrees(appear ? 0 : -8))
                    .shadow(radius: 12)
                    .scaleEffect(reduceMotion ? 1.0 : (pulse ? 1.03 : 1.0))
                shimmerLayer
                    .mask(
                        Image("AppLogo").resizable().scaledToFit().frame(width: 140, height: 140)
                    )
            }
            VStack { Spacer().frame(height: 240); Text("Nexus").font(.title3.weight(.semibold)).opacity(0.9) }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.75, blendDuration: 0.2)) { appear = true }
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { pulse = true }
                withAnimation(.easeInOut(duration: 1.1).delay(0.25)) { shine = true }
            }
            // 1.1s de splash
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { onFinish() }
        }
    }

    private var shimmerLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Rectangle()
                .fill(LinearGradient(colors: [.clear, Color.white.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
                .frame(width: w * 0.6)
                .rotationEffect(.degrees(20))
                .offset(x: shine ? w * 1.5 : -w * 1.5)
                .allowsHitTesting(false)
        }
        .frame(width: 160, height: 160)
        .opacity(reduceMotion ? 0 : 1)
    }
}

// MARK: - Login (con API de Payload)
struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var email: String = Keychain.loadEmail() ?? ""
    
    @State private var password: String = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var showPassword = false

    @FocusState private var typing: Bool
    
    @State private var canUseBiometrics: Bool = false
    @State private var biometryType: LABiometryType = .none
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Iniciar sesión").font(.title.bold())
                    Text("Ingresa con tus accesos de usuario")
                }.frame(maxWidth: .infinity, alignment: .leading)

                TextField("Email", text: $email)
                  .keyboardType(.emailAddress)
                  .textContentType(.emailAddress)
                  .autocorrectionDisabled()
                  .textInputAutocapitalization(.never)
                  .padding(12)
                  .background(Color(.systemGray6))
                  .cornerRadius(12)
                
                ZStack {
                    // Campo (según showPassword)
                    Group {
                        if showPassword {
                            TextField("Contraseña", text: $password)
                        } else {
                            SecureField("Contraseña", text: $password)
                        }
                    }
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                    .focused($typing)

                    // Botón ojo a la derecha
                    HStack {
                        Spacer()
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.trailing, 12)
                        .accessibilityLabel(showPassword ? "Ocultar contraseña" : "Mostrar contraseña")
                    }
                }
                Button { Task { await doLogin() } } label: {
                    HStack { if isLoading { ProgressView().padding(.trailing, 6) }; Text(isLoading ? "Entrando…" : "Entrar").fontWeight(.semibold) }
                        .frame(maxWidth: .infinity).padding()
                        .background((isLoading || email.isEmpty || password.isEmpty) ? Color.gray.opacity(0.3) : Color.accentColor)
                        .foregroundColor((isLoading || email.isEmpty || password.isEmpty) ? .secondary : .white)
                        .cornerRadius(12)
                }.disabled(isLoading || email.isEmpty || password.isEmpty)
                
                // Botón biométrico (mostrar si hay token o refresh, no importa si el access está vencido)
                if canUseBiometrics, (Keychain.loadToken() != nil || Keychain.loadRefresh() != nil) {
                    Button {
                        Task { await biometricLogin(using: Keychain.loadToken() ?? "") }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: biometryType == .faceID ? "faceid" : "touchid")
                            Text(biometryType == .faceID ? "Entrar con Face ID" : "Entrar con Touch ID")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(12)
                    }
                }


                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Spacer()
                Text("")
                Text("")
            }
            .padding()
            .navigationTitle("N+")
            .task {
                // Detecta biometría disponible
                if email.isEmpty { email = LastLoginEmail.load() }
                let avail = BiometricAuth.availability()
                self.canUseBiometrics = avail.available
                self.biometryType = avail.type
            }
        }
    }

    private func doLogin() async {
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let login = try await APIClient.login(email: email, password: password)
            // login: (access: String, refresh: String?)

            let accessToken = login.access
            let refreshToken = login.refresh

            let me = try await APIClient.me(token: accessToken)

            await MainActor.run {
                app.token = accessToken
                app._id = me.id
                app.name = me.name
                Keychain.saveToken(accessToken)
                if let r = refreshToken { Keychain.saveRefresh(r) }  // si implementaste refresh
                Keychain.saveEmail(email)
                app.phase = .gallery
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
    
    private func biometricLogin(using savedToken: String) async {
        error = nil
        let ok = await BiometricAuth.authenticate(
            reason: biometryType == .faceID ? "Usa Face ID para entrar" : "Usa Touch ID para entrar"
        )
        guard ok else { error = "Autenticación cancelada o fallida."; return }

        do {
            var tokenToUse = savedToken
            if TokenUtils.isExpired(savedToken, leeway: 0), let r = Keychain.loadRefresh() {
                tokenToUse = try await APIClient.refresh(using: r)
            }
            let me = try await APIClient.me(token: tokenToUse)
            await MainActor.run {
                app.token = tokenToUse
                app._id = me.id
                app.name = me.name
                app.phase = .gallery
            }
        } catch {
            await MainActor.run { self.error = "Sesión inválida. Inicia con tu contraseña." }
            Keychain.deleteToken()
            Keychain.deleteRefresh()
        }
    }
}

// MARK: - Tabs (Galería + En vivo JWPlayer + Cola)
// MARK: - Tabs con Dock flotante (sin encimar la Tab Bar)
struct MainTabsView: View {
    @EnvironmentObject var app: AppState
    @State private var selectedTab = 0

    // Acciones rápidas
    @State private var showActionSheet = false
    @State private var showQuickPhoto = false
    @State private var showQuickVideo = false
    @State private var showUploader = false
    @State private var showBulkPicker = false

    
    @State private var showUploadError = false
    @State private var uploadErrorTitle = ""
    @State private var uploadErrorBody  = ""

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                GalleryView()
                    .tabItem { Label("Contribuciones", systemImage: "photo.on.rectangle") }
                    .tag(0)

                /*AudioRecorderTabView()
                    .tabItem { Label("Audio", systemImage: "mic") }
                    .tag(1)
                */
                QueueView()
                    .tabItem { Label("En proceso", systemImage: "tray.full") }
                    .tag(1)
            }.onReceive(NotificationCenter.default.publisher(for: .uploadFailed)) { note in
                uploadErrorTitle = (note.userInfo?["title"] as? String) ?? "Error de subida"
                uploadErrorBody  = (note.userInfo?["body"]  as? String) ?? "Ocurrió un problema subiendo el archivo."
                showUploadError = true
            }
            .alert(uploadErrorTitle, isPresented: $showUploadError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(uploadErrorBody)
            }
            .toolbarBackground(.visible, for: .tabBar)
            .zIndex(0)

            // Dock flotante SIEMPRE por encima y con padding calculado
            VStack {
                Spacer()
                ActionDock {
                    showActionSheet = true
                }
                .padding(.horizontal, 16)
                .padding(.bottom, tabBarClearance())
                .zIndex(1)
            }
            .allowsHitTesting(true)
        }
        // Menú de acciones
        .confirmationDialog("Acción rápida", isPresented: $showActionSheet, titleVisibility: .visible) {
            Button("Tomar foto") { showQuickPhoto = true }
            Button("Grabar video") { showQuickVideo = true }
            Button("Subir desde galería") { showUploader = true }
            Button("Subida múltiple") { showBulkPicker = true }
            Button("Cancelar", role: .cancel) { }
            
            
        }
        // Sheets
        .sheet(isPresented: $showBulkPicker) {
            BulkPickerUploaderView()
            // .environmentObject(app)  // opcional si usas AppState
        }
        .sheet(isPresented: $showQuickPhoto) {
            UploaderView(onSuccess: { showQuickPhoto = false }, autoOpen: .photo)
                .environmentObject(app)
        }
        .sheet(isPresented: $showQuickVideo) {
            UploaderView(onSuccess: { showQuickVideo = false }, autoOpen: .video)
                .environmentObject(app)
        }
        .sheet(isPresented: $showUploader) {
            UploaderView(onSuccess: { showUploader = false }, autoOpen: nil)
                .environmentObject(app)
        }
    }

    /// Altura total para despegar el dock de la Tab Bar:
    /// Tab bar estándar (49pt) + safe area bottom + separador visual.
    private func tabBarClearance(separator: CGFloat = 30) -> CGFloat {
        let bottomInset = UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0
        let tabBarHeight: CGFloat = 49 // altura estándar de UITabBar
        return bottomInset + tabBarHeight + separator
    }
}

/// Dock inferior moderno con botón grande de acción
private struct ActionDock: View {
    var onTap: () -> Void
    @State private var pressed = false

    var body: some View {
        HStack {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onTap()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "camera.on.rectangle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                    Text("Acción rápida")
                        .font(.headline)
                }
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .scaleEffect(pressed ? 0.98 : 1)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
        }
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.15))
                )
                .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
        )
    }
}

// Helper para obtener el keyWindow (para safeAreaInsets)
private extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

// MARK: - Galería (grid) con visor full-screen y reproductor video
struct GalleryView: View {
    @EnvironmentObject var app: AppState
    @State private var docs: [MediaDoc] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showUploader = false
    @State private var showLogoutConfirm = false
    @State private var viewerDoc: MediaDoc? = nil           // imagen a fullscreen
    @State private var viewerVideoDoc: MediaDoc? = nil      // video a fullscreen

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 1)]
    
    var body: some View {
        
        NavigationView {
            
            Group {
                if isLoading {
                    ProgressView("Cargando…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Text("No se pudieron cargar los medios").font(.headline)
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                        Button("Reintentar") { Task { await loadImages() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if docs.isEmpty {
                    VStack(spacing: 12) {
                        Text("Aún no hay medios").font(.headline)
                        Button { showUploader = true } label: { Label("Subir", systemImage: "square.and.arrow.up") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Más recientes primero").font(.footnote).foregroundStyle(.secondary)
                                Spacer()
                                Toggle("Privacidad", isOn: $app.privacyBlur).labelsHidden()
                                Image(systemName: app.privacyBlur ? "eye.slash" : "eye").foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            LazyVGrid(columns: columns, spacing: 0) {
                                ForEach(docs) { doc in
                                    if let url = doc.fileURL(base: PayloadConfig.originURL) {
                                        VStack(spacing: 0) {
                                            ZStack(alignment: .bottomTrailing) {
                                                if doc.isImage {
                                                    AsyncImage(url: url) { phase in
                                                        switch phase {
                                                        case .empty: ZStack { Color.secondary.opacity(0.1) }.overlay(ProgressView())
                                                        case .success(let image):
                                                            image.resizable().scaledToFit()
                                                                .blur(radius: app.privacyBlur ? 12 : 0)
                                                        case .failure: ZStack { Color.secondary.opacity(0.1) }.overlay(Image(systemName: "photo").font(.title3))
                                                        @unknown default: Color.secondary.opacity(0.1)
                                                        }
                                                    }
                                                } else if doc.isVideo {
                                                    ZStack {
                                                        Color.secondary.opacity(0.08)
                                                        Image(systemName: "play.circle.fill")
                                                            .font(.system(size: 34))
                                                            .symbolRenderingMode(.hierarchical)
                                                    }
                                                    .blur(radius: app.privacyBlur ? 12 : 0)
                                                } else {
                                                    ZStack { Color.secondary.opacity(0.1) }.overlay(Image(systemName: "questionmark").font(.title3))
                                                }
                                            }
                                            .frame(height: 65)
                                            .clipped()
                                            .cornerRadius(3)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                if app.privacyBlur { return }
                                                if doc.isImage { viewerDoc = doc }
                                                else if doc.isVideo { viewerVideoDoc = doc }
                                            }

                                            Text(doc.prettyDate).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }
                                }
                            }.padding(.top, 6)
                        }
                    }
                }
            }
            .navigationTitle("Contribuciones")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showLogoutConfirm = true } label: { Label("Salir", systemImage: "person.crop.circle.badge.xmark") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showUploader = true } label: { Label("Subir", systemImage: "square.and.arrow.up") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await loadImages() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task {
                if app._id == nil, let t = Keychain.loadToken() {
                    if let me = try? await APIClient.me(token: t) {
                        await MainActor.run { app._id = me.id }
                    }
                }
                await loadImages()
            }
            .sheet(isPresented: $showUploader) {
                UploaderView(onSuccess: { showUploader = false; Task { await loadImages() } }, autoOpen: nil)
                        .environmentObject(app)
            }
            .confirmationDialog("¿Cerrar sesión?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                Button("Cerrar sesión", role: .destructive) {
                    Keychain.deleteToken(); app.token = nil; app.phase = .login
                }
                Button("Cancelar", role: .cancel) { }
            }
            // Imagen fullscreen
            .fullScreenCover(item: $viewerDoc) { doc in
                if let url = doc.fileURL(base: PayloadConfig.originURL) {
                    ImageFullscreenViewer(url: url)
                }
            }
            // Video fullscreen
            .fullScreenCover(item: $viewerVideoDoc) { doc in
                if let url = doc.fileURL(base: PayloadConfig.originURL) {
                    VideoFullscreenPlayer(url: url)
                }
            }
        }
    }

    private func loadImages() async {
        await MainActor.run { isLoading = true; error = nil }
        do {
            let token = Keychain.loadToken()

            let list = try await APIClient.fetchMedia(token: token, id: app._id)
            await MainActor.run {
                self.docs = list
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}

// MARK: - Imagen a pantalla completa con zoom
struct ImageFullscreenViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification)
                        .gesture(pan)
                        .onTapGesture(count: 2) { toggleZoom() }
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: scale)
                        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: offset)
                case .failure:
                    VStack(spacing: 12) { Image(systemName: "exclamationmark.triangle").foregroundColor(.white); Text("No se pudo cargar la imagen").foregroundColor(.white) }
                @unknown default:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(radius: 4)
            }
            .padding(16)
        }
    }

    private var magnification: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = max(1.0, min(newScale, 4.0))
            }
            .onEnded { _ in
                lastScale = scale
                if scale == 1 { offset = .zero; lastOffset = .zero }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1.0 else { return }
                offset = CGSize(width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height)
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private func toggleZoom() {
        if scale > 1.01 {
            scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero
        } else {
            scale = 2.5; lastScale = 2.5
        }
    }
}

// MARK: - Video a pantalla completa (AVPlayer)
struct VideoFullscreenPlayer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer? = nil

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .onAppear {
                    player = AVPlayer(url: url)
                    player?.play()
                    //enableBackgroundPlayback()
                }
                .onDisappear {
                    player?.pause()
                    player = nil
                }

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
                    .shadow(radius: 4)
            }
            .padding(16)
        }
    }
}

func enableBackgroundPlayback() {
    do {
        let session = AVAudioSession.sharedInstance()
        // .playback mantiene audio/vídeo en background
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
        try session.setActive(true)
    } catch {
        print("AVAudioSession error:", error)
    }
}

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
                let urlCMS = "/admin/collections/media/" + assetId

                UIPasteboard.general.string = String(data: respData, encoding: .utf8) // opcional: copia respuesta
                Task {
                    try? await avisarSlackAssetListo(
                        webhookURL: "",
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

// MARK: - Cámara (UIImagePickerController wrapper)
struct CameraPicker: UIViewControllerRepresentable {
    enum Mode { case photo, video }
    var mode: Mode
    var onImage: (UIImage) -> Void
    var onVideo: (URL) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        switch mode {
        case .photo:
            picker.mediaTypes = [UTType.image.identifier]
            picker.cameraCaptureMode = .photo
        case .video:
            picker.mediaTypes = [UTType.movie.identifier]
            picker.cameraCaptureMode = .video
            picker.videoQuality = .typeHigh
        }
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.onCancel(); picker.dismiss(animated: true) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            defer { picker.dismiss(animated: true) }
            if let type = info[.mediaType] as? String {
                if type == UTType.image.identifier, let img = info[.originalImage] as? UIImage { parent.onImage(img); return }
                if type == UTType.movie.identifier, let url = info[.mediaURL] as? URL { parent.onVideo(url); return }
            }
        }
    }
}

// MARK: - MP4 Export
func exportToMP4(sourceURL: URL,
                 preset: String = AVAssetExportPreset1280x720) async throws -> URL {
    let asset = AVURLAsset(url: sourceURL)
    guard let exporter = AVAssetExportSession(asset: asset, presetName: preset) else {
        throw NSError(domain: "Export", code: -1, userInfo: [NSLocalizedDescriptionKey: "No se pudo crear exportador"])
    }
    let outURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mp4")

    exporter.outputURL = outURL
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true

    return try await withCheckedThrowingContinuation { cont in
        exporter.exportAsynchronously {
            switch exporter.status {
            case .completed:
                cont.resume(returning: outURL)
            case .failed, .cancelled:
                cont.resume(throwing: exporter.error ?? NSError(domain: "Export", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Fallo exportación"]))
            default:
                break
            }
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

    var data: Data { Data(base64Encoded: dataBase64) ?? Data() }
}

final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()
    @Published private(set) var items: [PendingUpload] = []
    private let storeURL: URL
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "UploadQueue")
    private var isProcessing = false
    private var retries: [String: Int] = [:] // id -> intentos
    
    private init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storeURL = dir.appendingPathComponent("pending-uploads.json")
        self.items = (try? Self.load(from: storeURL)) ?? []
        monitor.pathUpdateHandler = { [weak self] path in
            if path.status == .satisfied { self?.processNext() }
        }
        monitor.start(queue: queue)
    }

    func start() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.forceKick() }
        processNext()
    }
    
    func forceKick() {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isProcessing { self.processNext() }
        }
    }

    func enqueue(_ item: PendingUpload) throws {
        items.append(item)
        try persist()
        forceKick() // <-- asegúrate de reactivar el procesamiento
    }

    func remove(id: String) throws {
        items.removeAll { $0.id == id }
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: storeURL, options: .atomic)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    private static func load(from url: URL) throws -> [PendingUpload] {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([PendingUpload].self, from: data)
    }
    
    private func markRetry(for id: String) {
        let n = (retries[id] ?? 0) + 1
        retries[id] = n
        let base = pow(2.0, Double(min(n, 6))) // 2,4,8,16,32,64 (tope)
        let jitter = Double.random(in: 0...1.0)
        let delay = base + jitter
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processNext()
        }
    }

    func processNext() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.isProcessing, let next = self.items.first else { return }
            self.isProcessing = true

            Task {
                defer { self.isProcessing = false }
                do {
                    // construye request con tu builder (igual que antes)
                    let safeFields = ensureAltTitle(next.fields)

                    let (req, _) = try MultipartBuilder.makeRequest(
                        url: PayloadConfig.uploadURL,
                        fileFieldName: "file",
                        filename: next.filename,
                        mimeType: next.mimeType,
                        fileData: next.data,               // ← sigue usando data (veremos mejora abajo)
                        fields: safeFields,
                        bearerToken: next.token
                    )

                    // ⬅️ USA LA SESIÓN CONFIGURADA, no URLSession.shared
                    // Si el item es muy grande, mejor súbelo en BG y quítalo de la cola
                    let bigThreshold = 10 * 1024 * 1024
                    if next.data.count > bigThreshold {
                        // escribe el binario a un archivo temporal y súbelo en BG
                        let tmp = FileManager.default.temporaryDirectory
                            .appendingPathComponent("queue-\(next.id).bin")
                        do {
                            try next.data.write(to: tmp, options: .atomic)
                            try BackgroundUploader.shared.enqueueFile(
                                fileURL: tmp,
                                filename: next.filename,
                                mimeType: next.mimeType,
                                fields: next.fields,
                                token: next.token
                            )
                            // Ya delegamos al BG uploader → podemos quitarlo de la cola local
                            try self.remove(id: next.id)
                            self.processNext()
                            return
                        } catch {
                            // si falla, reintenta luego
                            self.scheduleRetry(backoff: true)
                            return
                        }
                    }

                    // Si no es grande, sigue el camino normal con self.session.data(for:)
                    let (respData, resp) = try await self.session.data(for: req)


                    guard let http = resp as? HTTPURLResponse else { self.scheduleRetry(); return }

                    if http.statusCode == 401 || http.statusCode == 403 {
                        NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
                        // deja el item en cola para que suba cuando el usuario re-inicie sesión
                        return
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        // 5xx o 4xx → reintento
                        self.scheduleRetry(backoff: true)
                        return
                    }

                    // Éxito → quita de la cola
                    try self.remove(id: next.id)
                    self.processNext()
                } catch {
                    // Error de red (-1005, etc.) → backoff y reintento
                    self.scheduleRetry(backoff: true)
                }
            }
        }
    }

    // backoff exponencial con jitter
    private var retryAttempt = 0
    private func scheduleRetry(backoff: Bool = false) {
        let delay: TimeInterval
        if backoff {
            retryAttempt = min(retryAttempt + 1, 6)
            let base = pow(2.0, Double(retryAttempt)) // 1,2,4,8,16,32
            delay = min(30, base * Double.random(in: 0.7...1.3))
        } else {
            retryAttempt = 0
            delay = 10
        }
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.processNext()
        }
    }


    private func scheduleRetry() {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.processNext()
        }
    }
    
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.allowsCellularAccess = true
        cfg.allowsExpensiveNetworkAccess = true
        cfg.allowsConstrainedNetworkAccess = true
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 60 * 10
        cfg.timeoutIntervalForResource = 60 * 60
        cfg.httpMaximumConnectionsPerHost = 4
        if #available(iOS 11.0, *) {
            cfg.multipathServiceType = .handover   // Wi-Fi → LTE sin cortar
        }
        return URLSession(configuration: cfg)
    }()
}

struct AudioRecorderTabView: View {
    @StateObject private var rec = AudioRecorderManager()
    @State private var player: AVAudioPlayer?
    @State private var recordedURL: URL?
    @State private var isPlaying = false
    @State private var title: String = ""
    @State private var notes: String = "video sin título " + Date().formatted(date: .numeric, time: .standard)
    @State private var useBackgroundUpload = false
    @State private var status: String?
    @StateObject private var transcriber = SpeechTranscriber()
    @State private var transcript: String = ""
    @State private var autoTranscribe = true
    @State private var localeID: String = "es-MX"
    @State private var selectedFormat: AudioFormat = .m4a
    @State private var selectedBitrate: AudioBitrate = .kbps128
    @FocusState private var focusedField: Bool
    @EnvironmentObject var app: AppState


    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    // Indicadores / niveles
                    LevelBars(level: rec.level, count: 20)
                        .frame(height: 40)
                        .animation(.easeInOut(duration: 0.15), value: rec.level)

                    Toggle("Transcribir automáticamente: ", isOn: $autoTranscribe)

                    HStack(spacing: 8) {
                        TextField("Idioma (ej. es-MX, es-ES)", text: $localeID)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .padding(10)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .focused($focusedField)

                        Button {
                            Task { await doTranscribe() }
                        } label: {
                            Label("Transcribir", systemImage: "text.alignleft")
                        }
                        .disabled(recordedURL == nil || rec.isRecording)
                    }

                    // Controles de grabación
                    HStack(spacing: 16) {
                        Button {
                            Task { await toggleRecord() }
                        } label: {
                            RecordButton(isRecording: rec.isRecording, isPaused: rec.isPaused)
                        }
                        .buttonStyle(.plain)

                        Button {
                            if rec.isRecording { rec.togglePauseResume() }
                        } label: {
                            Label(rec.isPaused ? "Reanudar" : "Pausar",
                                  systemImage: rec.isPaused ? "play.fill" : "pause.fill")
                        }
                        .disabled(!rec.isRecording)
                    }

                    // Tiempo y estado
                    Text(rec.elapsedString)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Divider()

                    // Preview / reproducción
                    Group {
                        if let url = recordedURL {
                            HStack(spacing: 14) {
                                Button {
                                    togglePlay(url: url)
                                } label: {
                                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                                        .font(.title2)
                                }
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent).font(.subheadline)
                                    Text(filesizeString(for: url))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        } else {
                            Text("Aún no hay grabación. Pulsa el botón rojo para grabar.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Metadatos básicos
                    Group {
                        TextField("Título (opcional)", text: $title)
                            .textInputAutocapitalization(.never)
                            .padding(12)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .focused($focusedField)

                        // Si quieres notas tipo multi-línea, descomenta:
                        /*
                        TextField("Notas (opcional)", text: $notes, axis: .vertical)
                            .lineLimit(2...4)
                            .padding(12)
                            .background(Color(.systemGray6))
                            .cornerRadius(10)
                            .focused($focusedField)
                        */

                        Toggle("Subir en segundo plano", isOn: $useBackgroundUpload)
                    }

                    if !transcript.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transcripción")
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $transcript)
                                .frame(minHeight: 140)
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                                .focused($focusedField)
                        }
                    }

                    if let status {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    // Acolchonado para que el último elemento no quede pegado al borde
                    Spacer(minLength: 24)
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                // margen extra para que el contenido no quede tapado por la barra inferior fija
                .padding(.bottom, 100)
            }
            .navigationTitle("Grabar audio")
            .navigationBarTitleDisplayMode(.inline)

            // Teclado y scroll friendly
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                // Botón para ocultar teclado cuando haya campos enfocados
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Ocultar teclado") { focusedField = false }
                }
            }

            // Barra de acciones fija que no se encima gracias a safeAreaInset
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button {
                        Task { await upload() }
                    } label: {
                        HStack { Image(systemName: "icloud.and.arrow.up"); Text("Subir") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recordedURL == nil || rec.isRecording)

                    Button {
                        Task { await createPostFromTranscript() }
                    } label: {
                        HStack { Image(systemName: "square.and.pencil"); Text("Enviar") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(recordedURL == nil
                              || transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || rec.isRecording)

                    Button(role: .destructive) {
                        deleteRecording()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(recordedURL == nil || rec.isRecording)
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.ultraThinMaterial) // se ve bien y respeta safe area/teclado
            }
        }
        .onDisappear { stopPlayback() }
    }

    // MARK: - Acciones

    private func togglePlay(url: URL) {
        if isPlaying { stopPlayback(); return }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.prepareToPlay()
            player?.play()
            isPlaying = true
        } catch {
            status = "No se pudo reproducir: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    private func deleteRecording() {
        stopPlayback()
        if let url = recordedURL { try? FileManager.default.removeItem(at: url) }
        recordedURL = nil
        status = "Grabación eliminada."
    }

    private func toggleRecord() async {
        if rec.isRecording {
            if let url = await rec.stop() {
                recordedURL = url
                status = "Grabación guardada."
                if autoTranscribe { await doTranscribe() }
            }
            return
        }
        do {
            let url = try await rec.start()
            recordedURL = url
            status = "Grabando…"
        } catch {
            status = error.localizedDescription
        }
    }

    private func doTranscribe() async {
        guard let url = recordedURL else { status = "No hay audio."; return }
        status = "Transcribiendo…"
        do {
            let text = try await transcriber.transcribeFile(url: url, localeID: localeID)
            transcript = text
            status = "Transcripción lista ✅"
        } catch {
            status = "Error de transcripción: \(error.localizedDescription)"
        }
    }

    /// Sube el audio y crea un post con la transcripción
    private func createPostFromTranscript() async {
        guard let url = recordedURL else { status = "No hay audio."; return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { status = "No hay texto para publicar."; return }

        if let t = Keychain.loadToken(), TokenUtils.isExpired(t) {
            NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
            status = "Sesión expirada. Inicia sesión nuevamente."
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let filename = suggestedFilename(ext: selectedFormat.fileExtension)
            let mime = selectedFormat.mimeType
            var fields = PayloadConfig.extraFields
            fields["title"] = "Subido desde Nexus por \(app.name ?? "Usuario")"
            if !title.isEmpty { fields["title"] = title; fields["alt"] = title }
            if !notes.isEmpty { fields["notes"] = notes }
            fields = ensureAltTitle(fields)   // 👈 al final, siempre

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
            if http.statusCode == 401 || http.statusCode == 403 {
                NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
                status = "Sesión expirada. Inicia sesión nuevamente."
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: respData, encoding: .utf8) ?? "<sin cuerpo>"
                throw NSError(domain: "Upload", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            }

            let mediaID: String = {
                if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
                   let doc  = json["doc"] as? [String: Any] {
                    return String(describing: (doc["id"] ?? doc["_id"] ?? ""))
                }
                return ""
            }()

            try await APIClient.createPost(
                title: title.isEmpty ? "Audio \(Date().formatted(date: .abbreviated, time: .shortened))" : title,
                body: text,
                mediaID: mediaID.isEmpty ? nil : mediaID
            )

            status = "¡Publicación creada! ✅"
        } catch {
            status = "Error creando publicación: \(error.localizedDescription)"
            print(status ?? "")
        }
    }

    private func upload() async {
        guard let url = recordedURL else { status = "Nada que subir."; return }

        let filename = suggestedFilename(ext: "m4a")
        let mime = "audio/x-m4a"
        var fields = PayloadConfig.extraFields
        fields["title"] = "Subido desde Nexus por \(app.name ?? "Usuario")"

        if !title.isEmpty { fields["title"] = title; fields["alt"] = title }
        if !notes.isEmpty { fields["notes"] = notes }

        if useBackgroundUpload {
            do {
                try BackgroundUploader.shared.enqueueFile(
                    fileURL: url,
                    filename: filename,
                    mimeType: mime,
                    fields: fields,
                    token: Keychain.loadToken()
                )
                status = "Enviado a segundo plano ✅"
            } catch {
                status = "Error BG upload: \(error.localizedDescription)"
            }
            return
        }

        do {
            let data = try Data(contentsOf: url)
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

            if http.statusCode == 401 || http.statusCode == 403 {
                NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
                status = "Sesión expirada. Inicia sesión nuevamente."
                return
            }
            if (200..<300).contains(http.statusCode) {
                status = "¡Audio subido! ✅"
            } else {
                let body = String(data: respData, encoding: .utf8) ?? "<sin cuerpo>"
                throw NSError(domain: "Upload", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
            }
        } catch {
            status = "Error al subir: \(error.localizedDescription)"
            print(status ?? "")
        }
    }

    private func suggestedFilename(ext: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "audio-\(stamp).\(ext)"
    }

    private func filesizeString(for url: URL) -> String {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"
    }
}

// MARK: - Vista de la Cola
struct QueueView: View {
    @ObservedObject var q = UploadQueue.shared
    var body: some View {
        NavigationView {
            List {
                if q.items.isEmpty {
                    Text("No hay elementos en cola").foregroundStyle(.secondary)
                } else {
                    ForEach(q.items) { item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.filename).font(.headline)
                            Text(item.mimeType).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Reintentar ahora") {
                                    UploadQueue.shared.forceKick()
                                }
                                Button("Eliminar", role: .destructive) {
                                    try? UploadQueue.shared.remove(id: item.id)
                                    UploadQueue.shared.forceKick()
                                }
                            }.buttonStyle(.bordered)
                        }
                    }
                    .refreshable { UploadQueue.shared.forceKick() }
                }
                BGUploadsSectionView()
            }
            .navigationTitle("Cola")
        }
    }
}

// MARK: - Tab de grabación y subida de audio

// MARK: - UI helpers
struct RecordButton: View {
    let isRecording: Bool
    let isPaused: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 4).frame(width: 80, height: 80)
            if isRecording {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPaused ? Color.yellow : Color.red)
                    .frame(width: isPaused ? 38 : 52, height: isPaused ? 38 : 52)
                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isPaused)
            } else {
                Circle().fill(.red).frame(width: 56, height: 56)
            }
        }
        .contentShape(Rectangle())
        .accessibilityLabel(isRecording ? (isPaused ? "Reanudar" : "Detener") : "Grabar")
    }
}

struct LevelBars: View {
    let level: CGFloat   // 0..1
    let count: Int
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width / CGFloat(count)
            HStack(spacing: w * 0.3) {
                ForEach(0..<count, id: \.self) { i in
                    // pequeña variación visual
                    let k = 0.75 + 0.25 * sin((Double(i)/Double(count)) * .pi)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: w * 0.7, height: max(4, geo.size.height * level * k))
                        .animation(.easeOut(duration: 0.1), value: level)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}

// MARK: - Grabador
@MainActor
final class AudioRecorderManager: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var level: CGFloat = 0
    @Published var elapsed: TimeInterval = 0

    var elapsedString: String {
        let s = Int(elapsed)
        return String(format: "%02d:%02d", s/60, s%60)
    }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startDate: Date?
    private(set) var fileURL: URL?

    // Inicia grabación (igual que tenías, pero asegurando main + metering)
    func start(format: AudioFormat = .m4a, bitrate: AudioBitrate? = .kbps128) async throws -> URL {
        let granted = await requestMicPermission()
        guard granted else { throw NSError(domain: "Mic", code: 1, userInfo: [NSLocalizedDescriptionKey: "Permiso de micrófono denegado"]) }

        try configureSession()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format.fileExtension)

        let settings: [String: Any]
        switch format {
        case .m4a:
            let br = (bitrate?.rawValue ?? AudioBitrate.kbps128.rawValue)
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: br,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        case .wav:
            settings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
        }

        recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder?.delegate = self
        recorder?.isMeteringEnabled = true

        guard recorder?.record() == true else {
            throw NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No se pudo iniciar la grabación"])
        }

        self.fileURL = url
        self.isRecording = true
        self.isPaused = false
        self.elapsed = 0
        self.startDate = Date()

        startMeters()
        return url
    }

    func togglePauseResume() {
        guard let rec = recorder, isRecording else { return }
        if isPaused {
            rec.record()
            isPaused = false
            startDate = Date().addingTimeInterval(-elapsed) // conserva cronómetro
        } else {
            rec.pause()
            isPaused = true
        }
    }

    func stop() async -> URL? {
        guard let rec = recorder else { return nil }
        rec.stop()
        stopMeters()
        isRecording = false
        isPaused = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return fileURL
    }

    // MARK: - Timers

    private func startMeters() {
        stopMeters()
        // Timer en main run loop y modo .common (no se detiene con scroll)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        meterTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopMeters() {
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func tick() {
        guard let rec = recorder else { return }
        rec.updateMeters()

        // Normaliza dB (-160...0) a 0...1
        let db = rec.averagePower(forChannel: 0)
        let norm = max(0, min(1, (db + 50) / 50))
        self.level = CGFloat(norm)

        if let start = self.startDate, !self.isPaused {
            self.elapsed = Date().timeIntervalSince(start)
        }
    }

    // MARK: - Permisos / sesión

    private func configureSession() throws {
        let ses = AVAudioSession.sharedInstance()
        try ses.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try ses.setActive(true)
    }

    private func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
        }
    }
}

// MARK: - Servicio de ubicación/rumbo
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    @Published var last: CLLocation?
    @Published var lastHeading: CLHeading?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.headingFilter = 5
    }

    func request() {
        if CLLocationManager.authorizationStatus() == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        last = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        lastHeading = newHeading
    }

    var summary: String {
        if let l = last {
            let lat = String(format: "%.5f", l.coordinate.latitude)
            let lon = String(format: "%.5f", l.coordinate.longitude)
            let alt = String(format: "%.0f m", l.altitude)
            return "GPS \(lat), \(lon) • \(alt)"
        }
        return "GPS sin datos"
    }
}

// MARK: - API Client
struct APIClient {
    
    struct APIError: Error, LocalizedError { let message: String; var errorDescription: String? { message } }

    static func login(email: String, password: String) async throws -> (access: String, refresh: String?) {
        var req = URLRequest(url: PayloadConfig.loginURL)
        req.httpMethod = "POST"
        req.networkServiceType = .responsiveData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Tu usuario o contraseña no son correctas")
        }
        let decoded = try JSONDecoder().decode(AuthLoginResponse.self, from: data)
        guard let access = decoded.token, !access.isEmpty else { throw APIError(message: "Sin token") }
        if let refresh = decoded.refreshToken { Keychain.saveRefresh(refresh) }
        Keychain.saveToken(access)
        return (access, decoded.refreshToken)
    }
    
    static func refresh(using refreshToken: String) async throws -> String {
        // Ajusta la URL a tu backend: /api/users/refresh (o similar)
        let url = PayloadConfig.apiBase.appendingPathComponent("\(PayloadConfig.authCollection)/refresh")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Refresh falló")
        }
        let decoded = try JSONDecoder().decode(AuthLoginResponse.self, from: data)
        guard let access = decoded.token, !access.isEmpty else { throw APIError(message: "Sin nuevo token") }
        Keychain.saveToken(access)
        if let newRefresh = decoded.refreshToken { Keychain.saveRefresh(newRefresh) } // opcional
        return access
    }

    static func me(token: String) async throws -> AuthUser {
        var req = URLRequest(url: PayloadConfig.meURL)
        req.httpMethod = "GET"
        req.setValue("JWT \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let txt = String(data: data, encoding: .utf8) ?? ""
            throw APIError(message: "ME falló: \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(txt)")
        }
        struct MeResp: Decodable { let user: AuthUser? }
        let me = try JSONDecoder().decode(MeResp.self, from: data)
        guard let u = me.user else { throw APIError(message: "ME sin usuario") }
        return u
    }

    static func fetchMedia(token: String?, id: String? = nil) async throws -> [MediaDoc] {
        // 1) Si no hay token o está vencido → notifica y falla
        if let t = token, TokenUtils.isExpired(t, leeway: 15) {
            NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
            throw APIError(message: "Sesión expirada. Inicia sesión nuevamente.")
        }
        
        var comps = URLComponents(url: PayloadConfig.uploadURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "sort", value: "-createdAt"),
            URLQueryItem(name: "where[createdBy][equals]", value: id),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "GET"
        if let t = token, !t.isEmpty {
            req.setValue("JWT \(t)", forHTTPHeaderField: "Authorization")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Respuesta inválida") }

        // 2) Si el servidor regresa 401/403 → notifica y falla
        if http.statusCode == 401 || http.statusCode == 403 {
            NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
            throw APIError(message: "Sesión expirada. Inicia sesión nuevamente.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
            throw APIError(message: "HTTP \(http.statusCode): \(body)")
        }

        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode(MediaListResponse.self, from: data) { return list.docs }
        if let arr  = try? decoder.decode([MediaDoc].self,       from: data) { return arr }
        throw APIError(message: "Formato de respuesta inesperado")
    }
}

// MARK: - Modelos de auth/media
struct AuthUser: Decodable {
    let id: String
    let email: String?
    let name: String?

    enum CodingKeys: String, CodingKey { case id, _id, email, name }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let v = try? c.decode(String.self, forKey: .id) {
            self.id = v
        } else if let v = try? c.decode(String.self, forKey: ._id) {
            self.id = v
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.id,
                .init(codingPath: decoder.codingPath, debugDescription: "AuthUser sin id/_id")
            )
        }
        self.email = try? c.decode(String.self, forKey: .email)
        self.name = try? c.decode(String.self, forKey: .name)
    }
}


struct AuthLoginResponse: Decodable { let token: String?; let refreshToken: String?; let user: AuthUser?; let exp: Double?; let message: String? }

extension Keychain {

    private static let refreshAccount = "payload-refresh"
    private static let emailAccount = "payload-last-email"
    
    static func saveEmail(_ email: String) {
            let data = email.data(using: .utf8)!
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: emailAccount
            ]
            SecItemDelete(q as CFDictionary)
            var add = q; add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }

        static func loadEmail() -> String? {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: emailAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var item: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data {
                return String(data: data, encoding: .utf8)
            }
            return nil
        }

        static func deleteEmail() {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: emailAccount
            ]
            SecItemDelete(q as CFDictionary)
        }

    static func saveRefresh(_ token: String) {
        let data = token.data(using: .utf8)!
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: refreshAccount
        ]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func loadRefresh() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: refreshAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func deleteRefresh() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: refreshAccount
        ]
        SecItemDelete(q as CFDictionary)
    }
}

struct MediaListResponse: Decodable { let docs: [MediaDoc] }

struct MediaDoc: Decodable, Identifiable, Equatable {
    
    let id: String
    let mimeType: String?
    let filename: String?
    let url: String?
    let createdAt: Date?
    let alt: String?
    let title: String?

    enum CodingKeys: String, CodingKey { case id, _id, mimeType, filename, url, createdAt, alt, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try? c.decode(String.self, forKey: .id) {
            self.id = id
        } else if let oid = try? c.decode(String.self, forKey: ._id) {
            self.id = oid
        } else {
            throw DecodingError.keyNotFound(CodingKeys.id,
                                            .init(codingPath: decoder.codingPath,
                                                  debugDescription: "no id/_id"))
        }
        self.mimeType  = try? c.decode(String.self, forKey: .mimeType)
        self.filename  = try? c.decode(String.self, forKey: .filename)
        self.url       = try? c.decode(String.self, forKey: .url)
        self.createdAt = try? c.decode(Date.self,   forKey: .createdAt)
        self.alt       = try? c.decode(String.self, forKey: .alt)
        self.title     = try? c.decode(String.self, forKey: .title)
    }

    func fileURL(base: URL) -> URL? {
        if let url = url, !url.isEmpty {
            if url.hasPrefix("http") { return URL(string: url) }
            let path = url.hasPrefix("/") ? String(url.dropFirst()) : url
            return base.appendingPathComponent(path)
        }
        if let filename = filename { return base.appendingPathComponent("media/\(filename)") }
        return nil
    }

    var isImage: Bool { mimeType?.hasPrefix("image/") == true }
    var isVideo: Bool { mimeType?.hasPrefix("video/") == true }

    var prettyDate: String {
        guard let createdAt else { return "" }
        return MediaDoc.dateFormatter.string(from: createdAt)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}


// MARK: - Multipart Builder
enum MultipartBuilder {
    struct Boundary {
        let raw = "Boundary-\(UUID().uuidString)"
        var headerValue: String { "multipart/form-data; boundary=\(raw)" }
    }

    static func makeRequest(
        url: URL,
        fileFieldName: String,
        filename: String,
        mimeType: String,
        fileData: Data,
        fields: [String: String],
        bearerToken: String?
    ) throws -> (URLRequest, Int) {
        let boundary = Boundary()
        var body = Data()
        var altValue = ""
        var titleValue = ""
        // Campos de texto
        for (key, value) in fields {
            body.appendString("--\(boundary.raw)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
            if(key == "alt"){
                altValue = value;
            }
        
            if(key == "title"){
                titleValue = value;
            }
        }
        // JSON
        body.appendString("--\(boundary.raw)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"_payload\"\r\n\r\n")
        let jsonStringValue = "{\"alt\":\"\(altValue)\", \"title\":\"\(titleValue)\"}"
        body.appendString(jsonStringValue)
        body.appendString("\r\n")
        
        // Archivo
        body.appendString("--\(boundary.raw)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"\(fileFieldName)\"; filename=\"\(filename)\"\r\n")
        body.appendString("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        body.appendString("\r\n")

        // Cierre
        body.appendString("--\(boundary.raw)--\r\n")
        /*if let stringBody = String(data: body, encoding: .utf8) {
            print(stringBody)
        } else {
            print("No se pudo convertir a String")
        }
        if let stringBody = String(data: body, encoding: .ascii) {
            print(stringBody)
        }
         */
         
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(boundary.headerValue, forHTTPHeaderField: "Content-Type")
        if let token = bearerToken, !token.isEmpty {
            req.setValue("JWT \(token)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        
        return (req, body.count)
    }
}

// MARK: - Keychain simple (guardar/leer/borrar JWT)
struct Keychain {
    private static let service = "com.tuapp.fieldapp"
    private static let account = "payload-token"

    static func saveToken(_ token: String) {
        let data = token.data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var toAdd = query
        toAdd[kSecValueData as String] = data
        SecItemAdd(toAdd as CFDictionary, nil)
    }

    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    static func deleteToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Utils
private extension Data { mutating func appendString(_ s: String) { if let d = s.data(using: .utf8) { append(d) } } }

// MARK: - 1. Estructura Principal del Payload (Cuerpo de la solicitud HTTP)
struct SlackPayload: Encodable {
    let blocks: [Block]
}

// MARK: - 2. Bloque Genérico
// Representa un elemento en el array 'blocks'.
struct Block: Encodable {
    let type: String
    let text: TextObject?
    let fields: [TextObject]?
    let image_url: String? // Para el bloque 'image'
    let alt_text: String?   // Para el bloque 'image'
    let elements: [Element]? // Para el bloque 'actions'

    // Inicializador conveniente para 'header' y 'section' simples
    init(type: String, text: TextObject? = nil, fields: [TextObject]? = nil, image_url: String? = nil, alt_text: String? = nil, elements: [Element]? = nil) {
        self.type = type
        self.text = text
        self.fields = fields
        self.image_url = image_url
        self.alt_text = alt_text
        self.elements = elements
    }
}

// MARK: - 3. Objetos de Texto Comunes
// Usados en 'header', 'fields' y dentro de 'button'
struct TextObject: Encodable {
    let type: String // "plain_text" o "mrkdwn"
    let text: String
}

// MARK: - 4. Elementos de Acción (Botones)
// Usados en el array 'elements' del bloque 'actions'
struct Element: Encodable {
    let type: String // "button"
    let text: TextObject
    let style: String?
    let url: String?
}

func avisarSlackAssetListo(
    webhookURL: String,
    assetNombre: String,
    assetTamano: String, // Añadido para los detalles
    usuario: String,     // Añadido para los detalles
    timestamp: String,   // Añadido para los detalles
    assetImageURL: URL,  // URL de la imagen (storage)
    cmsURL: URL          // URL del CMS (botón)
) async throws {
    guard let url = URL(string: webhookURL) else { throw SlackNotifyError.badURL }

    // 1. Construir los campos de la Sección de Detalles
    let fields = [
        TextObject(type: "mrkdwn", text: "*Archivo:* `\(assetNombre)`"),
        TextObject(type: "mrkdwn", text: "*Tamaño:* \(assetTamano)"),
        TextObject(type: "mrkdwn", text: "*Usuario:* @\(usuario)"),
        TextObject(type: "mrkdwn", text: "*Timestamp:* \(timestamp)")
    ]

    // 2. Crear los bloques usando las estructuras de Swift
    let blocks: [Block] = [
        // Bloque Header
        Block(
            type: "header",
            text: TextObject(type: "plain_text", text: "✅ Informe de Carga de Imagen Exitosa")
        ),
        // Bloque Section (Detalles)
        Block(
            type: "section",
            fields: fields
        ),
        // Bloque Image (Previsualización)
        Block(
            type: "image",
            image_url: assetImageURL.absoluteString,
            alt_text: "Vista previa de la imagen cargada"
        ),
        // Bloque Actions (Botón)
        Block(
            type: "actions",
            elements: [
                Element(
                    type: "button",
                    text: TextObject(type: "plain_text", text: "Revisar en el CMS"),
                    style: "primary",
                    url: cmsURL.absoluteString
                )
            ]
        )
    ]

    // 3. Crear el Payload final
    let payload = SlackPayload(blocks: blocks)

    // 4. Configurar y Enviar la Solicitud
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

    // Codifica la estructura Swift a JSON para el cuerpo HTTP
    req.httpBody = try JSONEncoder().encode(payload)

    let (_, resp) = try await URLSession.shared.data(for: req)
    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
        throw SlackNotifyError.badStatus(http.statusCode)
    }
}

struct HTTPDebug {
    let status: Int
    let statusText: String
    let headers: [String: String]
    let bodyData: Data
    var bodyTextUTF8: String { String(data: bodyData, encoding: .utf8) ?? "<no UTF-8>" }
}

func send(_ req: URLRequest) async throws -> HTTPDebug {
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }

    let headers = http.allHeaderFields.reduce(into: [String: String]()) { dict, pair in
        if let k = pair.key as? String, let v = pair.value as? CustomStringConvertible {
            dict[k] = v.description
        }
    }

    return HTTPDebug(
        status: http.statusCode,
        statusText: HTTPURLResponse.localizedString(forStatusCode: http.statusCode),
        headers: headers,
        bodyData: data
    )
}

// Utilidades para JWT: decodificar y checar `exp`
enum TokenUtils {
    /// Devuelve true si el token está vencido o por vencerse (leeway en segundos)
    static func isExpired(_ token: String, leeway: TimeInterval = 60) -> Bool {
        guard let payload = decodeJWT(token),
              let exp = payload["exp"] as? Double else {
            // Si no se puede leer, trátalo como inválido
            return true
        }
        let expiry = Date(timeIntervalSince1970: exp)
        return Date().addingTimeInterval(leeway) >= expiry
    }

    /// Decodifica el payload (no valida firma; solo lectura de `exp`)
    static func decodeJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        let payloadBase64 = base64urlToBase64(String(parts[1]))
        guard let data = Data(base64Encoded: payloadBase64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func base64urlToBase64(_ s: String) -> String {
        var base = s.replacingOccurrences(of: "-", with: "+")
                    .replacingOccurrences(of: "_", with: "/")
        let pad = base.count % 4
        if pad > 0 { base.append(String(repeating: "=", count: 4 - pad)) }
        return base
    }
}

/// Sube archivos en **segundo plano** con URLSession background + multipart/form-data.
/// Usa `enqueueFile(...)` para video grande (no carga en RAM).

fileprivate func ensureAltTitle(_ fields: [String:String]) -> [String:String] {
    var f = fields
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    if (f["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        f["title"] = "Subido desde iOS \(stamp)"
    }
    if (f["alt"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        f["alt"] = f["title"] ?? "Subido desde iOS \(stamp)"
    }
    return f
}

//Trasncriptor

final class SpeechTranscriber: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    enum STError: LocalizedError { case notAuthorized, notAvailable, noResult
        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Permiso de reconocimiento de voz denegado."
            case .notAvailable:  return "Reconocedor no disponible para este idioma."
            case .noResult:      return "No se obtuvo transcripción."
            }
        }
    }

    @MainActor
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    /// Transcribe un archivo de audio local (m4a/wav). `localeID` ej. "es-MX", "es-ES".
    func transcribeFile(url: URL, localeID: String = "es-MX") async throws -> String {
        guard await requestAuthorization() else { throw STError.notAuthorized }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)), recognizer.isAvailable
        else { throw STError.notAvailable }

        let req = SFSpeechURLRecognitionRequest(url: url)
        // Si el dispositivo tiene modelos on-device para ese idioma:
        if #available(iOS 13, *) { req.requiresOnDeviceRecognition = false } // cambia a true si quieres forzar on-device (si disponible)

        return try await withCheckedThrowingContinuation { cont in
            var finalText = ""
            let task = recognizer.recognitionTask(with: req) { result, error in
                if let error { cont.resume(throwing: error); return }
                guard let result else { return }
                finalText = result.bestTranscription.formattedString
                if result.isFinal { cont.resume(returning: finalText) }
            }
            // Cancel safeguard si nunca llega final
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
                if finalText.isEmpty { task.cancel(); cont.resume(throwing: STError.noResult) }
            }
        }
    }
}

struct PostResponse: Codable { let doc: PostDoc? }
struct PostDoc: Codable { let id: String? }

extension APIClient {
    
    static func refreshAccessToken() async throws -> String {
        guard let refresh = Keychain.loadRefresh(), !refresh.isEmpty else {
            throw APIError(message: "No hay refresh token")
        }
        var req = URLRequest(url: PayloadConfig.apiBase.appendingPathComponent("users/refresh-token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refresh])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError(message: "Refresh falló")
        }
        let dec = try JSONDecoder().decode(AuthLoginResponse.self, from: data)
        guard let newAccess = dec.token else { throw APIError(message: "Refresh sin token") }
        Keychain.saveToken(newAccess)
        if let r = dec.refreshToken { Keychain.saveRefresh(r) }
        return newAccess
    }
    
    static func createPost(title: String, body: String, mediaID: String?) async throws {
            var req = URLRequest(url: PayloadConfig.postsURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            if let t = Keychain.loadToken(), !t.isEmpty {
                req.setValue("JWT \(t)", forHTTPHeaderField: "Authorization")
            }
            let contentStructure = createRichTextContent(from: body)
            var payload: [String: Any] = [
                "title": title,
                "excerpt": title,
                "content": contentStructure,
                "_status": "draft",
                "readTime": 1,
                "slug": title.lowercased().replacingOccurrences(of: " ", with: "-"),
                "creator": ""
            ]
        
            if let mediaID { payload["audio"] = mediaID } // ajusta clave a tu schema si aplica
        
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw APIError(message: "Respuesta inválida") }
            if http.statusCode == 401 || http.statusCode == 403 {
                NotificationCenter.default.post(name: AuthEvents.expired, object: nil)
                throw APIError(message: "Sesión expirada. Inicia sesión nuevamente.")
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
                throw APIError(message: "HTTP \(http.statusCode): \(body)")
            }
        }
}

func createRichTextContent(from body: String) -> [String: Any] {
    
    // Verificación de contenido
    let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // --- 1. Nodo de Texto (El más interno) ---
    let textNode: [String: Any] = [
        "detail": 0 as Int,
        "format": 0 as Int,
        "mode": "normal" as String,
        "style": "" as String,
        "text": cleanBody as String,
        "type": "text" as String,
        "version": 1 as Int
    ]
    
    // --- 2. Nodo de Párrafo (El bloque que contiene el texto) ---
    let paragraphNode: [String: Any] = [
        "children": [textNode],
        "direction": "ltr" as String,
        "format": "" as String,
        "indent": 0 as Int,
        "type": "paragraph" as String,
        "version": 1 as Int,
        "textFormat": 0 as Int,
        "textStyle": "" as String
    ]
    
    // --- 3. Nodo Raíz (El documento completo) ---
    let rootNode: [String: Any] = [
        "children": [paragraphNode], // El nodo raíz contiene el párrafo
        "direction": "ltr" as String,
        "format": "" as String,
        "indent": 0 as Int,
        "type": "root" as String,
        "version": 1 as Int
    ]
    
    // --- 4. Objeto de Contenido (La clave "content" espera este objeto) ---
    return ["root": rootNode]
}
