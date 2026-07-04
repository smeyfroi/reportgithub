import Foundation

public enum GitHubClientError: Error, LocalizedError, Equatable {
    case notFound(String)
    case http(Int, String)
    case rateLimited(retryAfter: Double?)
    case network(String)
    case missingCredentials
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): return "Not found: \(what)"
        case .http(let code, let message): return "HTTP \(code): \(message)"
        case .rateLimited(let after):
            return "Rate limited" + (after.map { ", retry after \(Int($0))s" } ?? "")
        case .network(let message): return "Network error: \(message)"
        case .missingCredentials: return "No GitHub token configured"
        case .invalidResponse(let message): return "Invalid response: \(message)"
        }
    }
}

/// The read-only GitHub surface used by find-phase scripts.
public protocol GitHubClient: Sendable {
    func listOrgRepos(org: String) async throws -> [RepoRef]
    /// One repository's metadata — the authoritative source for defaultBranch.
    /// (Code-search results don't carry default_branch, so repos surfaced via
    /// searchCode may claim "main" on a master-default repo.)
    func getRepo(fullName: String) async throws -> RepoRef
    /// Code search scoped to the organisation. Results are candidate evidence only.
    func searchCode(org: String, query: String) async throws -> [RepoRef]
    /// Returns nil when the file does not exist at that path/ref.
    func getContent(repo: String, path: String, ref: String?) async throws -> String?
    /// Batched file reads: one round-trip per ~100 `(repo, path)` pairs (via
    /// GraphQL in the live client, against the separate GraphQL quota pool — the
    /// lever for scanning a large estate without exhausting the REST budget).
    /// Returns an entry aligned to each request: `.content` when the file was
    /// fetched, `.absent` when the repo/file is missing or the blob is binary,
    /// `.error` when THAT repo's fetch failed. Per-entry isolation — one bad
    /// repo never fails the whole batch. Conformers without an override read
    /// serially. Surfacing `.error` (rather than collapsing it to `.absent`)
    /// lets a recipe still mark that repo failed, so nothing drops silently.
    func getContentBatch(_ requests: [ContentRequest]) async throws -> [BatchEntry]
    /// All blob paths in the repository tree at ref (default branch HEAD when
    /// nil). Glob filtering happens host-side — GitHub has no glob endpoint.
    func listFiles(repo: String, ref: String?) async throws -> [String]
    /// Returns the SHA for a ref (e.g. "heads/main"), or nil if the ref does not exist.
    func getRef(repo: String, ref: String) async throws -> String?
    func listPRs(repo: String, head: String?, state: String) async throws -> [PullRequestRef]
    func searchPRs(org: String, query: String) async throws -> [PullRequestRef]

    // MARK: Custom properties (org-owned repos, read-only)

    /// Authoritative bulk read of every org repo with its custom-property
    /// values — the backbone for property reports (no search-index staleness).
    func listOrgProperties(org: String) async throws -> [RepoProperties]
    /// One repository's custom-property values (authoritative, per-repo).
    func getProperties(repo: String) async throws -> [String: PropertyValue]
    /// The organisation's custom-property definitions (schema + allowed values).
    func listPropertyDefs(org: String) async throws -> [PropertyDef]
}

/// One entry in a batched file read: which file to fetch from which repo, at an
/// optional ref (nil = the repo's default branch HEAD).
public struct ContentRequest: Sendable, Equatable {
    public let repo: String
    public let path: String
    public let ref: String?
    public init(repo: String, path: String, ref: String? = nil) {
        self.repo = repo
        self.path = path
        self.ref = ref
    }
}

/// The outcome of one entry in a batched read. Distinguishing `.absent` from
/// `.error` is the whole point of the richer result: a report that silently
/// drops a repo that FAILED to fetch (as opposed to one that genuinely lacks
/// the file) would be misleading, so the error is surfaced for the recipe to
/// act on (e.g. mark the repo failed).
public enum BatchEntry: Sendable, Equatable {
    /// The file was fetched; the associated value is its UTF-8 text.
    case content(String)
    /// The repository or file does not exist, or the blob is binary (no text).
    case absent
    /// This repository's fetch failed; the associated value is a message.
    case error(String)
}

public extension GitHubClient {
    /// Serial fallback for conformers without a batched implementation (e.g. the
    /// fixture client): read each file in turn. The live client overrides this
    /// with a single GraphQL round-trip per chunk.
    ///
    /// Per-entry isolation mirrors the GraphQL path: a missing file/repo resolves
    /// to `.absent` and a fetch that throws resolves to `.error` for that entry
    /// alone, so one bad repo never fails the whole batch. Cancellation still
    /// propagates.
    func getContentBatch(_ requests: [ContentRequest]) async throws -> [BatchEntry] {
        var results: [BatchEntry] = []
        results.reserveCapacity(requests.count)
        for request in requests {
            do {
                let text = try await getContent(repo: request.repo, path: request.path, ref: request.ref)
                results.append(text.map(BatchEntry.content) ?? .absent)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                results.append(.error(message))
            }
        }
        return results
    }
}
