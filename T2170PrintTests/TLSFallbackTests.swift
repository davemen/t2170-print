import Foundation
import Testing
@testable import T2170Print

// The real T2170 answers plain-HTTP IPP on port 631 with 426 (or an empty 500) and wants TLS.
// URLSession can't do an HTTP upgrade, so the client retries over HTTPS and keeps what works.

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var plainStatus = 426
    nonisolated(unsafe) static var tlsWorks = true
    nonisolated(unsafe) static var seen: [String] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.lock.lock(); Self.seen.append("\(url.scheme!)://\(url.host()!):\(url.port ?? 0)"); Self.lock.unlock()
        let ok = url.scheme == "https" && Self.tlsWorks
        let status = ok ? 200 : (url.scheme == "http" ? Self.plainStatus : 500)
        var headers: [String: String] = [:]
        var body = Data()
        if ok {
            headers["Content-Type"] = "application/ipp"
            body = Data([2, 0, 0, 0, 0, 0, 0, 1, 0x01, 0x47, 0, 18] + Array("attributes-charset".utf8) + [0, 5] + Array("utf-8".utf8) + [0x03])
        } else if status == 426 {
            headers["Content-Type"] = "application/ipp"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeClient() -> IPPClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    StubProtocol.lock.lock(); StubProtocol.seen = []; StubProtocol.lock.unlock()
    return IPPClient(printerURI: URL(string: "ipp://192.168.1.89:631/ipp/print")!,
                     session: URLSession(configuration: configuration))
}

@Suite(.serialized) struct TLSFallbackTests {
    @Test func upgradeRequiredFallsBackToHTTPSAndSticks() async {
        StubProtocol.plainStatus = 426; StubProtocol.tlsWorks = true
        let client = makeClient()
        let first = await client.rawPrinterAttributes()
        #expect(first.httpStatus == 200)
        #expect(await client.currentEndpoint.scheme == "https")
        let second = await client.rawPrinterAttributes()
        #expect(second.httpStatus == 200)
        #expect(StubProtocol.seen == ["http://192.168.1.89:631", "https://192.168.1.89:631", "https://192.168.1.89:631"])
    }

    @Test func emptyServerErrorAlsoTriesTLS() async {
        StubProtocol.plainStatus = 500; StubProtocol.tlsWorks = true
        let client = makeClient()
        #expect(await client.rawPrinterAttributes().httpStatus == 200)
    }

    @Test func tlsDeadEndKeepsTheOriginalAnswer() async {
        StubProtocol.plainStatus = 426; StubProtocol.tlsWorks = false
        let client = makeClient()
        let response = await client.rawPrinterAttributes()
        #expect(response.httpStatus == 426)
        #expect(await client.currentEndpoint.scheme == "http")
        #expect(StubProtocol.seen == ["http://192.168.1.89:631", "https://192.168.1.89:631", "https://192.168.1.89:443"])
    }
}
