import Foundation
import Testing
@testable import ReportGitHubKit

/// A stub that answers the GraphQL POST with a canned body and counts requests.
/// Isolated statics so it never races other suites under parallel execution.
final class GraphQLStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var _count = 0
    private static var body = "{\"data\":{}}"
    private static var status = 200

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }

    static func reset(body: String, status: Int = 200) {
        lock.lock(); defer { lock.unlock() }
        _count = 0; Self.body = body; Self.status = status
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock(); Self._count += 1; let body = Self.body; let status = Self.status; Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["x-ratelimit-remaining": "4999",
                                                      "x-ratelimit-resource": "graphql"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("GraphQL batched reads", .serialized)
struct GraphQLBatchTests {
    private func client() -> LiveGitHubClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GraphQLStubProtocol.self]
        return LiveGitHubClient(apiHost: "https://api.github.com",
                                tokenProvider: { "tok" },
                                session: URLSession(configuration: config))
    }

    @Test("a batch resolves to entries aligned with input, absent for a missing blob")
    func alignedWithAbsent() async throws {
        GraphQLStubProtocol.reset(body: #"""
        {"data":{"r0":{"object":{"text":"alpha"}},"r1":{"object":null},"r2":{"object":{"text":"gamma"}}}}
        """#)
        let results = try await client().getContentBatch([
            ContentRequest(repo: "o/a", path: "f"),
            ContentRequest(repo: "o/b", path: "f"),
            ContentRequest(repo: "o/c", path: "f"),
        ])
        #expect(results == [.content("alpha"), .absent, .content("gamma")])
        #expect(GraphQLStubProtocol.requestCount == 1)   // one round-trip for three files
    }

    @Test("more than a chunk's worth of requests splits into multiple queries")
    func chunksLargeBatches() async throws {
        // A canned 100-alias response; each chunk reads only the aliases it asked
        // for (r0…), so one fixed body serves both the 100- and 20-item chunk.
        let aliases = (0..<100).map { "\"r\($0)\":{\"object\":{\"text\":\"x\"}}" }.joined(separator: ",")
        GraphQLStubProtocol.reset(body: "{\"data\":{\(aliases)}}")
        let requests = (0..<120).map { ContentRequest(repo: "o/r\($0)", path: "f") }
        let results = try await client().getContentBatch(requests)
        #expect(results.count == 120)
        #expect(results.allSatisfy { $0 == .content("x") })
        #expect(GraphQLStubProtocol.requestCount == 2)   // 100 + 20
    }

    @Test("a malformed repo yields an error and issues no query when the whole chunk is invalid")
    func malformedRepoErrors() async throws {
        GraphQLStubProtocol.reset(body: "{\"data\":{}}")
        let results = try await client().getContentBatch([ContentRequest(repo: "no-slash", path: "f")])
        #expect(results.count == 1)
        guard case .error = results[0] else { Issue.record("expected .error for a malformed repo"); return }
        #expect(GraphQLStubProtocol.requestCount == 0)   // nothing valid to fetch
    }

    @Test("an empty batch returns empty without a round-trip")
    func emptyBatch() async throws {
        GraphQLStubProtocol.reset(body: "{\"data\":{}}")
        let results = try await client().getContentBatch([])
        #expect(results.isEmpty)
        #expect(GraphQLStubProtocol.requestCount == 0)
    }

    @Test("a missing file resolves to absent without disturbing the other repos")
    func missingFileIsIsolated() async throws {
        // A file that doesn't exist is `object: null` — not even a GraphQL error.
        GraphQLStubProtocol.reset(body: #"""
        {"data":{"r0":{"object":{"text":"present"}},"r1":{"object":null},"r2":{"object":{"text":"also"}}}}
        """#)
        let results = try await client().getContentBatch([
            ContentRequest(repo: "o/has", path: "wanted"),
            ContentRequest(repo: "o/lacks", path: "wanted"),
            ContentRequest(repo: "o/has2", path: "wanted"),
        ])
        #expect(results == [.content("present"), .absent, .content("also")])
    }

    @Test("a per-repo NOT_FOUND (non-fatal errors array) surfaces as .error, not a batch failure")
    func perRepoErrorIsIsolated() async throws {
        // A missing/private/renamed repo yields a null alias AND a top-level
        // `errors` entry — but `data` is still present, so the batch must return
        // the repos it could resolve, surfacing the failed one as `.error`.
        GraphQLStubProtocol.reset(body: #"""
        {"data":{"r0":{"object":{"text":"alpha"}},"r1":null,"r2":{"object":{"text":"gamma"}}},
         "errors":[{"type":"NOT_FOUND","path":["r1"],"message":"Could not resolve to a Repository with the name 'o/gone'."}]}
        """#)
        let results = try await client().getContentBatch([
            ContentRequest(repo: "o/a", path: "f"),
            ContentRequest(repo: "o/gone", path: "f"),
            ContentRequest(repo: "o/c", path: "f"),
        ])
        #expect(results[0] == .content("alpha"))
        #expect(results[2] == .content("gamma"))
        guard case .error(let message) = results[1] else { Issue.record("expected .error for the unresolved repo"); return }
        #expect(message.contains("Could not resolve"))
        #expect(GraphQLStubProtocol.requestCount == 1)
    }

    @Test("a systemic failure (no data at all) rejects the whole batch")
    func systemicFailureThrows() async throws {
        // No `data` key — a query-level rejection (e.g. bad credentials). This is
        // NOT per-repo isolation; the whole call must throw so the recipe's
        // try/catch can surface it.
        GraphQLStubProtocol.reset(body: #"{"errors":[{"message":"Bad credentials"}]}"#)
        await #expect(throws: (any Error).self) {
            _ = try await client().getContentBatch([ContentRequest(repo: "o/a", path: "f")])
        }
    }
}
