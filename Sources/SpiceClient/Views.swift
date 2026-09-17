import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SessionCore
import ConnectionCore
import SwiftSpice
import SwiftSpiceAdapter

struct LauncherView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Spice Client", systemImage: "desktopcomputer").font(.largeTitle.bold())
            Text(L.text("intro")).foregroundStyle(.secondary)
            Button(L.text("open"), action: model.chooseFile).buttonStyle(.borderedProminent)
            Divider()
            TextField(L.text("portalURL"), text: $model.portalURL).textFieldStyle(.roundedBorder)
                .onSubmit(model.openPortal)
            Button(L.text("portal"), action: model.openPortal).disabled(model.portalURL.isEmpty)
            if let message = model.message {
                Text(message).foregroundStyle(.orange).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Text(AppInfo.version)
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
        .padding(28).frame(minWidth: 440, minHeight: 340)
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first else { return false }
            model.receive(first)
            if urls.count > 1 { model.message = L.text("busy") }
            return true
        }
        .sheet(item: Binding(get: { model.pending }, set: { value in
            if value == nil, let pending = model.pending { model.cancel(pending.id) }
        })) { candidate in ConfirmationView(candidate: candidate, model: model) }
    }
}

struct ConfirmationView: View {
    let candidate: ConnectionCandidate
    let model: ApplicationModel
    @State private var clipboard = false
    private var protection: String {
        switch candidate.plan.security {
        case .plain: L.text("plain")
        case .systemTLS: L.text("systemTLS")
        case .certificateAuthority(_, let subject): L.text(subject == nil ? "customTLS" : "subjectTLS")
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L.text("confirm")).font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                GridRow { Text(L.text("source")); Text(candidate.source).textSelection(.enabled) }
                GridRow { Text(L.text("host")); Text(candidate.plan.host).font(.body.monospaced()).textSelection(.enabled) }
                GridRow { Text(L.text("port")); Text(String(candidate.plan.port)) }
                GridRow { Text(L.text("security")); Text(protection).foregroundStyle(candidate.plan.usesTLS ? Color.primary : Color.orange) }
            }
            Divider()
            Toggle(L.text("clipboard"), isOn: $clipboard)
            Text(L.text("clipboardHelp")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L.text("cancel")) { model.cancel(candidate.id) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.text("connect")) { model.confirm(candidate.id, clipboard: clipboard) }
                    .buttonStyle(.borderedProminent)
                // No implicit Return-to-connect: the destination deserves an explicit click.
            }
        }.padding(24).frame(minWidth: 520, idealWidth: 560)
    }
}

struct SettingsView: View {
    @Bindable var model: ApplicationModel
    var body: some View {
        Form {
            Toggle(L.text("trash"), isOn: $model.trashAfterConnection)
            Button(L.text("clearLogin"), action: model.clearPortalData)
            Text(L.text("clipboardHelp")).foregroundStyle(.secondary)
            Text(L.text("noUpdates")).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 480, minHeight: 220)
    }
}

struct SessionView: View {
    @Bindable var controller: SessionController
    @State private var showDiagnostics = false
    private var report: String { AppInfo.versionLine + "\n" + controller.summary }
    private var phase: String {
        if let failure = controller.failure { return L.text(failure.rawValue) }
        switch controller.lifecycle.phase {
        case .idle: return L.text("idle")
        case .connecting: return L.text("connecting")
        case .connected: return L.text("connected")
        case .stopping: return L.text("stopping")
        case .closed: return L.text("closed")
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(phase).lineLimit(2)
                Spacer()
                Toggle(L.text("clipboard"), isOn: $controller.shareClipboard).toggleStyle(.checkbox)
                Button(L.text("disconnect"), action: controller.disconnect)
                    .disabled(controller.lifecycle.phase == .stopping || controller.lifecycle.phase == .closed)
                Button(L.text("diagnostics")) {
                    showDiagnostics.toggle(); controller.setDiagnostics(showDiagnostics)
                }
            }.padding(10)
            if controller.audioUnavailable { Text(L.text("audioUnavailable")).foregroundStyle(.orange) }
            if controller.agentUnavailable { Text(L.text("agentUnavailable")).foregroundStyle(.orange) }
            if let desktop = controller.desktop, controller.lifecycle.phase != .closed {
                SpiceDesktopView(desktop: desktop, onInput: controller.submit)
                    .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                        controller.resize(width: Int(size.width), height: Int(size.height))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ContentUnavailableView(phase, systemImage: "display").frame(maxWidth: .infinity, maxHeight: .infinity) }
            if showDiagnostics {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L.text("diagnosticsHelp")).font(.caption)
                    ScrollView { Text(report).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                    Button(L.text("copy")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                    }.disabled(controller.summary.isEmpty)
                }.padding().frame(height: 220)
            }
        }.frame(minWidth: 640, minHeight: 400)
    }
}
