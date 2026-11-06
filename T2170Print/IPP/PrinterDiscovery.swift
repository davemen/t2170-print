import Foundation
import Network
import Observation

/// A printer discovered via Bonjour (`_ipp._tcp` / `_ipps._tcp`) or entered manually.
struct DiscoveredPrinter: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var name: String
    var host: String
    var port: Int
    var isTLS: Bool
    var resourcePath: String
    var txt: [String: String]

    init(
        id: String,
        name: String,
        host: String,
        port: Int = 631,
        isTLS: Bool = false,
        resourcePath: String = "/ipp/print",
        txt: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.isTLS = isTLS
        self.resourcePath = Self.normalizeResourcePath(resourcePath)
        self.txt = txt
    }

    /// Constructed `ipp://` or `ipps://` URI for this printer.
    var uri: URL {
        var components = URLComponents()
        components.scheme = isTLS ? "ipps" : "ipp"
        let cleanHost = Self.stripInterfaceScope(from: host)
        components.host = cleanHost.isEmpty ? "localhost" : cleanHost
        components.port = port
        components.path = Self.normalizeResourcePath(resourcePath)
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func normalizeResourcePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/ipp/print" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }

    fileprivate static func stripInterfaceScope(from rawHost: String) -> String {
        let trimmed = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let percentIndex = trimmed.firstIndex(of: "%") {
            return String(trimmed[..<percentIndex])
        }
        return trimmed
    }
}

/// Discovers IPP and IPPS printers on the local network using `NWBrowser`.
@MainActor
@Observable
final class PrinterDiscovery {
    var printers: [DiscoveredPrinter] = []
    var isBrowsing: Bool = false
    var lastError: String?

    private var browsers: [NWBrowser] = []
    private var resolvers: [String: NWConnection] = [:]
    private let browserQueue = DispatchQueue(label: "T2170Print.PrinterDiscovery")

    init() {}

    /// Starts browsing for `_ipp._tcp` and `_ipps._tcp` Bonjour services.
    func start() {
        stop()
        lastError = nil
        isBrowsing = true

        let serviceTypes: [(type: String, isTLS: Bool)] = [
            ("_ipp._tcp", false),
            ("_ipps._tcp", true)
        ]

        for entry in serviceTypes {
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: entry.type,
                domain: "local."
            )
            let browser = NWBrowser(for: descriptor, using: parameters)
            let isTLS = entry.isTLS

            browser.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleBrowserState(state)
                }
            }

            browser.browseResultsChangedHandler = { [weak self] _, changes in
                Task { @MainActor [weak self] in
                    self?.handleBrowseChanges(changes, isTLS: isTLS)
                }
            }

            browsers.append(browser)
            browser.start(queue: browserQueue)
        }
    }

    /// Stops all active Bonjour browsers and endpoint resolvers.
    func stop() {
        for browser in browsers {
            browser.stateUpdateHandler = nil
            browser.browseResultsChangedHandler = nil
            browser.cancel()
        }
        browsers.removeAll()

        for (_, connection) in resolvers {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        resolvers.removeAll()

        isBrowsing = false
    }

    /// Creates a `DiscoveredPrinter` for a manually entered host/IP address and adds it to `printers`.
    @discardableResult
    func manual(host: String, port: Int = 631, tls: Bool = false) -> DiscoveredPrinter {
        let cleanHost = DiscoveredPrinter.stripInterfaceScope(from: host)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let port = (1...65535).contains(port) ? port : 631
        let serviceType = tls ? "_ipps._tcp" : "_ipp._tcp"
        let printer = DiscoveredPrinter(
            id: "\(cleanHost):\(port)|\(serviceType)",
            name: cleanHost,
            host: cleanHost,
            port: port,
            isTLS: tls,
            resourcePath: "/ipp/print",
            txt: [:]
        )
        upsertPrinter(printer)
        return printer
    }

    // MARK: - Internal Resolution

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            lastError = nil
        case .failed(let error):
            lastError = error.localizedDescription
        case .waiting(let error):
            lastError = error.localizedDescription
        default:
            break
        }
    }

    private func handleBrowseChanges(_ changes: Set<NWBrowser.Result.Change>, isTLS: Bool) {
        for change in changes {
            switch change {
            case .removed(let result):
                guard case let .service(name, type, _, _) = result.endpoint else { continue }
                let serviceID = "\(name)|\(type)"
                cleanupResolver(for: serviceID)
                printers.removeAll { $0.id == serviceID }
            case .added(let result):
                resolveIfNeeded(result, isTLS: isTLS)
            case .changed(_, let newResult, _):
                resolveIfNeeded(newResult, isTLS: isTLS)
            case .identical:
                break
            @unknown default:
                break
            }
        }
    }

    private func resolveIfNeeded(_ result: NWBrowser.Result, isTLS: Bool) {
        guard case let .service(name, type, _, _) = result.endpoint else { return }

        let serviceID = "\(name)|\(type)"
        if resolvers[serviceID] != nil || printers.contains(where: { $0.id == serviceID }) {
            return
        }

        let txtDict = Self.extractTXTRecord(from: result.metadata)
        let rp = txtDict["rp"].map(DiscoveredPrinter.normalizeResourcePath) ?? "/ipp/print"

        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        resolvers[serviceID] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let remote = connection.currentPath?.remoteEndpoint
                Task { @MainActor [weak self] in
                    self?.completeResolution(
                        serviceID: serviceID,
                        name: name,
                        isTLS: isTLS,
                        resourcePath: rp,
                        txt: txtDict,
                        remoteEndpoint: remote
                    )
                }
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    self?.cleanupResolver(for: serviceID)
                }
            default:
                break
            }
        }

        connection.start(queue: browserQueue)
    }

    private func completeResolution(
        serviceID: String,
        name: String,
        isTLS: Bool,
        resourcePath: String,
        txt: [String: String],
        remoteEndpoint: NWEndpoint?
    ) {
        cleanupResolver(for: serviceID)

        // Without a concrete host/port there is nothing usable to print to; skip.
        guard case let .hostPort(host, port) = remoteEndpoint else { return }
        let resolvedHost = Self.hostString(from: host)
        let resolvedPort = Int(port.rawValue)

        let printer = DiscoveredPrinter(
            id: serviceID,
            name: name,
            host: resolvedHost,
            port: resolvedPort,
            isTLS: isTLS,
            resourcePath: resourcePath,
            txt: txt
        )
        upsertPrinter(printer)
    }

    private func cleanupResolver(for serviceID: String) {
        if let connection = resolvers.removeValue(forKey: serviceID) {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
    }

    private func upsertPrinter(_ printer: DiscoveredPrinter) {
        if let index = printers.firstIndex(where: { $0.id == printer.id }) {
            printers[index] = printer
        } else {
            printers.append(printer)
        }
    }

    private static func extractTXTRecord(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        guard case let .bonjour(txtRecord) = metadata else {
            return [:]
        }
        return txtRecord.dictionary
    }

    private static func hostString(from host: NWEndpoint.Host) -> String {
        switch host {
        case .name(let hostname, _):
            return DiscoveredPrinter.stripInterfaceScope(from: hostname)
        case .ipv4(let address):
            return DiscoveredPrinter.stripInterfaceScope(from: "\(address)")
        case .ipv6(let address):
            return DiscoveredPrinter.stripInterfaceScope(from: "\(address)")
        @unknown default:
            return DiscoveredPrinter.stripInterfaceScope(from: "\(host)")
        }
    }
}
