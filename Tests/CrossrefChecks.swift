import Foundation
import BibTeXKit
@testable import TypeNBash

final class CrossrefStub: URLProtocol, @unchecked Sendable {
    static var handler: (URLRequest) throws -> (Int, Data) = { _ in (500, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@main struct CrossrefChecks {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CrossrefStub.self]
        let service = CrossrefService(session: URLSession(configuration: config))
        let work = #"{"DOI":"10.1234/example","type":"journal-article","title":["A & B"],"container-title":["Journal"],"author":[{"given":"Ada","family":"Lovelace"},{"name":"Research Group"}],"issued":{"date-parts":[[2024,2]]},"volume":"12","page":"1-9"}"#
        CrossrefStub.handler = { request in
            let url = request.url!
            precondition(url.host == "api.crossref.org" && url.path == "/works")
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            precondition(query.contains(URLQueryItem(name: "query.bibliographic", value: "A & B")))
            precondition(query.contains(URLQueryItem(name: "rows", value: "100")))
            return (200, Data("{\"message\":{\"items\":[\(work)]}}".utf8))
        }
        let results = try await service.searchSources(query: " A & B ", maxRows: 999)
        let citation = results[0].citation
        precondition(citation.title == "A & B" && citation.type == "article-journal")
        precondition(citation.year == "2024" && citation.containerTitle == "Journal")
        precondition(citation.authors[1].literal == "Research Group" && !citation.id.isEmpty)
        CrossrefStub.handler = { request in
            precondition(request.url!.path == "/works/10.1234/example")
            precondition(request.url!.query == nil)
            return (200, Data("{\"message\":\(work)}".utf8))
        }
        let empty = try await service.searchSources(query: " ")
        precondition(empty.isEmpty)
        let exact = try await service.searchSources(query: "https://doi.org/10.1234/example")
        precondition(exact.count == 1)
        precondition(CrossrefService.normalizedDOI("doi: 10.1234/example") == "10.1234/example")
        precondition(CrossrefService.normalizedDOI("https://example.com/10.1234/example") == nil)
        CrossrefStub.handler = { request in
            precondition(request.url!.query == nil && request.url!.fragment == nil)
            precondition(request.url!.path == "/works/10.1234/a?b#c")
            return (200, Data("{\"message\":\(work)}".utf8))
        }
        _ = try await service.lookup(doi: "10.1234/a?b#c")
        for status in [404, 429, 503] {
            CrossrefStub.handler = { _ in (status, Data()) }
            do {
                _ = try await service.lookup(doi: "10.1234/example")
                preconditionFailure("Expected HTTP error")
            } catch CrossrefError.http(let actual) { precondition(actual == status) }
        }
        CrossrefStub.handler = { _ in (200, Data(#"{"message":{"DOI":"10.1234/minimal","type":"book"}}"#.utf8)) }
        let minimal = try await service.lookup(doi: "10.1234/minimal")
        precondition(minimal.citation.authors.isEmpty && minimal.citation.year == nil)
        if let fixture = ProcessInfo.processInfo.environment["CROSSREF_LIVE_FIXTURE"] {
            let live = try JSONDecoder().decode(CrossrefResponse<AcademicSource>.self,
                from: Data(contentsOf: URL(fileURLWithPath: fixture)))
            precondition(live.message.doi == "10.1038/nphys1170")
            precondition(!live.message.citation.title.isEmpty)
        }
        let model = CrossrefSearchModel(service: service)
        model.query = "10.1234/minimal"
        model.search()
        while model.isSearching { await Task.yield() }
        precondition(model.results.count == 1)
        model.search()
        model.cancel()
        await Task.yield()
        precondition(!model.isSearching && model.results.isEmpty)
        print("Crossref checks passed: query encoding, exact lookup, DOI normalization, metadata, missing fields, and HTTP errors.")
    }
}
