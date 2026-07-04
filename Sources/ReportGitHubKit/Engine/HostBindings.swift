import Foundation
import JavaScriptCore
import Yams

enum HostError: Error {
    case cancelled
    case invalidArgument(String)

    var message: String {
        switch self {
        case .cancelled: return "JobCancelled: the run was cancelled"
        case .invalidArgument(let m): return m
        }
    }
}

/// Simple counting semaphore for Swift concurrency; bounds concurrent host
/// calls so scripts can fan out naively with Promise.all.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ count: Int) { self.available = max(1, count) }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

final class CancelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
}

/// Builds the capability objects (`gh`, `job`, `parse`, `console`) injected
/// into a script context. The injected surface is the script's entire world:
/// a JSC context has no ambient filesystem, network, or process access.
///
/// Phase determines the capability set. Check phase installs the read-only
/// GitHub surface — write methods simply do not exist on the object.
enum HostBindings {

    static func install(in context: JSContext,
                        phase: JobPhase,
                        params: [String: String],
                        github: GitHubClient,
                        organisation: String,
                        collector: JobCollector,
                        limiter: AsyncSemaphore,
                        cancel: CancelBox,
                        vmQueue: DispatchQueue) {
        installGitHub(in: context, github: github, organisation: organisation,
                      collector: collector, limiter: limiter, cancel: cancel, vmQueue: vmQueue)
        installJob(in: context, params: params, collector: collector)
        installParse(in: context)
        installConsole(in: context, collector: collector)
    }

    // MARK: - gh

    private static func installGitHub(in context: JSContext,
                                      github: GitHubClient, organisation: String,
                                      collector: JobCollector, limiter: AsyncSemaphore,
                                      cancel: CancelBox, vmQueue: DispatchQueue) {
        guard let gh = JSValue(newObjectIn: context) else { return }

        let listOrgRepos: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repos = try await github.listOrgRepos(org: organisation)
                collector.registerCandidates(repos)
                collector.audit(kind: "gh.listOrgRepos", repo: nil, detail: "→ \(repos.count) repos")
                return repos.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listOrgRepos, to: AnyObject.self),
                     forKeyedSubscript: "listOrgRepos" as NSString)

        let getRepo: @convention(block) (JSValue?) -> JSValue = { repoValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getRepo: repo (object or \"owner/name\") is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repo = try await github.getRepo(fullName: fullName)
                collector.remember(repo)
                collector.audit(kind: "gh.getRepo", repo: fullName,
                                detail: "default branch \(repo.defaultBranch)")
                return repo.scriptValue
            }
        }
        gh.setObject(unsafeBitCast(getRepo, to: AnyObject.self),
                     forKeyedSubscript: "getRepo" as NSString)

        let searchCode: @convention(block) (JSValue?) -> JSValue = { queryValue in
            guard let query = stringArg(queryValue) else {
                return rejectedPromise("searchCode: query string is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let repos = try await github.searchCode(org: organisation, query: query)
                collector.registerCandidates(repos)
                collector.audit(kind: "gh.searchCode", repo: nil,
                                detail: "\(query) → \(repos.count) candidate repos")
                return repos.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(searchCode, to: AnyObject.self),
                     forKeyedSubscript: "searchCode" as NSString)

        let getContent: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, pathValue, refValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getContent: repo (object or \"owner/name\") is required")
            }
            guard let path = stringArg(pathValue) else {
                return rejectedPromise("getContent: path string is required")
            }
            let ref = stringArg(refValue)
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                do {
                    let content = try await github.getContent(repo: fullName, path: path, ref: ref)
                    if let content {
                        collector.recordReceipt(repo: fullName, path: path, content: content)
                    }
                    collector.audit(kind: "gh.getContent", repo: fullName,
                                    detail: path + (content == nil ? " (absent)" : " (\(content!.count) chars)"))
                    return content
                } catch {
                    // Failed fetches belong in the audit trail too.
                    collector.audit(kind: "gh.getContent", repo: fullName,
                                    detail: "\(path) failed: \(errorMessage(error))")
                    throw error
                }
            }
        }
        gh.setObject(unsafeBitCast(getContent, to: AnyObject.self),
                     forKeyedSubscript: "getContent" as NSString)

        // Batched read: one GraphQL round-trip per ~100 files instead of one
        // REST GET each, on a separate quota pool — the lever for scanning a
        // large estate. Each result is { content, error }: content is the text
        // (or null when absent/binary), error is a message when THAT repo's
        // fetch failed (null otherwise), so a recipe can job.error it rather
        // than dropping it silently.
        let getContentBatch: @convention(block) (JSValue?) -> JSValue = { pairsValue in
            guard let pairs = pairsValue, pairs.isArray else {
                return rejectedPromise("getContentBatch: an array of { repo, path } is required")
            }
            let count = Int(pairs.forProperty("length").toInt32())
            var requests: [ContentRequest] = []
            requests.reserveCapacity(count)
            for i in 0..<count {
                let element = pairs.atIndex(i)
                guard let fullName = repoName(element?.forProperty("repo")),
                      let path = stringArg(element?.forProperty("path")) else {
                    return rejectedPromise("getContentBatch: each entry needs { repo, path }")
                }
                requests.append(ContentRequest(repo: fullName, path: path,
                                               ref: stringArg(element?.forProperty("ref"))))
            }
            let batch = requests   // immutable snapshot for the concurrent closure
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let entries = try await github.getContentBatch(batch)
                var present = 0
                var errored = 0
                var aligned: [Any] = []
                aligned.reserveCapacity(entries.count)
                for (request, entry) in zip(batch, entries) {
                    switch entry {
                    case .content(let text):
                        collector.recordReceipt(repo: request.repo, path: request.path, content: text)
                        present += 1
                        aligned.append(["content": text, "error": NSNull()])
                    case .absent:
                        aligned.append(["content": NSNull(), "error": NSNull()])
                    case .error(let message):
                        errored += 1
                        aligned.append(["content": NSNull(), "error": message])
                    }
                }
                collector.audit(kind: "gh.getContentBatch", repo: nil,
                                detail: "\(batch.count) file(s) → \(present) present, \(errored) error(s)")
                return aligned
            }
        }
        gh.setObject(unsafeBitCast(getContentBatch, to: AnyObject.self),
                     forKeyedSubscript: "getContentBatch" as NSString)

        let listFiles: @convention(block) (JSValue?, JSValue?, JSValue?) -> JSValue = { repoValue, globValue, refValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("listFiles: repo (object or \"owner/name\") is required")
            }
            let glob = stringArg(globValue)
            let ref = stringArg(refValue)
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.listFiles(repo: fullName, ref: ref)
                let paths = glob.map { GlobMatcher.filter(all, glob: $0) } ?? all
                collector.audit(kind: "gh.listFiles", repo: fullName,
                                detail: "\(glob ?? "(all)") → \(paths.count) of \(all.count) files")
                return paths
            }
        }
        gh.setObject(unsafeBitCast(listFiles, to: AnyObject.self),
                     forKeyedSubscript: "listFiles" as NSString)

        let getRef: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, refValue in
            guard let fullName = repoName(repoValue), let ref = stringArg(refValue) else {
                return rejectedPromise("getRef: repo and ref are required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let sha = try await github.getRef(repo: fullName, ref: ref)
                collector.audit(kind: "gh.getRef", repo: fullName, detail: "\(ref) → \(sha ?? "absent")")
                return sha.map { ["sha": $0] }
            }
        }
        gh.setObject(unsafeBitCast(getRef, to: AnyObject.self),
                     forKeyedSubscript: "getRef" as NSString)

        let listPRs: @convention(block) (JSValue?, JSValue?) -> JSValue = { repoValue, optsValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("listPRs: repo is required")
            }
            let head = stringArg(optsValue?.objectForKeyedSubscript("head"))
            let state = stringArg(optsValue?.objectForKeyedSubscript("state")) ?? "open"
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let prs = try await github.listPRs(repo: fullName, head: head, state: state)
                collector.audit(kind: "gh.listPRs", repo: fullName, detail: "→ \(prs.count) PRs")
                return prs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listPRs, to: AnyObject.self),
                     forKeyedSubscript: "listPRs" as NSString)

        let searchPRs: @convention(block) (JSValue?) -> JSValue = { queryValue in
            guard let query = stringArg(queryValue) else {
                return rejectedPromise("searchPRs: query string is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let prs = try await github.searchPRs(org: organisation, query: query)
                collector.audit(kind: "gh.searchPRs", repo: nil, detail: "\(query) → \(prs.count) PRs")
                return prs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(searchPRs, to: AnyObject.self),
                     forKeyedSubscript: "searchPRs" as NSString)

        // Custom-property reads. The org bulk read is the authoritative query
        // backbone (real stored values, not a search index); reading a repo's
        // properties earns a property receipt that lets job.reportMatch accept a
        // property-based match with no file fetch.
        let listOrgProperties: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let all = try await github.listOrgProperties(org: organisation)
                collector.registerCandidates(all.map(\.repo))
                for entry in all {
                    collector.recordPropertyReceipt(repo: entry.repo.fullName)
                }
                collector.audit(kind: "gh.listOrgProperties", repo: nil,
                                detail: "→ \(all.count) repo(s) with custom properties")
                return all.map { entry -> [String: Any] in
                    ["repo": entry.repo.scriptValue,
                     "properties": entry.properties.mapValues { $0.scriptValue }]
                }
            }
        }
        gh.setObject(unsafeBitCast(listOrgProperties, to: AnyObject.self),
                     forKeyedSubscript: "listOrgProperties" as NSString)

        let getProperties: @convention(block) (JSValue?) -> JSValue = { repoValue in
            guard let fullName = repoName(repoValue) else {
                return rejectedPromise("getProperties: repo (object or \"owner/name\") is required")
            }
            return hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let props = try await github.getProperties(repo: fullName)
                collector.recordPropertyReceipt(repo: fullName)
                collector.audit(kind: "gh.getProperties", repo: fullName,
                                detail: "→ \(props.count) propert\(props.count == 1 ? "y" : "ies")")
                return props.mapValues { $0.scriptValue }
            }
        }
        gh.setObject(unsafeBitCast(getProperties, to: AnyObject.self),
                     forKeyedSubscript: "getProperties" as NSString)

        let listPropertyDefs: @convention(block) () -> JSValue = {
            hostPromise(limiter: limiter, cancel: cancel, vmQueue: vmQueue) {
                let defs = try await github.listPropertyDefs(org: organisation)
                collector.audit(kind: "gh.listPropertyDefs", repo: nil,
                                detail: "→ \(defs.count) definition(s)")
                return defs.map(\.scriptValue)
            }
        }
        gh.setObject(unsafeBitCast(listPropertyDefs, to: AnyObject.self),
                     forKeyedSubscript: "listPropertyDefs" as NSString)

        // ReportGitHub is read-only: the gh handle exposes only reads. No write
        // methods are ever installed on the object.
        context.setObject(gh, forKeyedSubscript: "gh" as NSString)
    }

    // MARK: - job

    private static func installJob(in context: JSContext, params: [String: String],
                                   collector: JobCollector) {
        guard let job = JSValue(newObjectIn: context) else { return }

        let reportMatch: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, evidenceValue in
            guard let ctx = JSContext.current() else { return }
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else {
                ctx.exception = JSValue(newErrorFromMessage: "reportMatch: repo is required", in: ctx)
                return
            }
            guard let evidenceValue, evidenceValue.isObject,
                  let path = stringArg(evidenceValue.objectForKeyedSubscript("path")),
                  let excerpt = stringArg(evidenceValue.objectForKeyedSubscript("excerpt")) else {
                ctx.exception = JSValue(newErrorFromMessage:
                    "reportMatch: evidence { path, excerpt } is required", in: ctx)
                return
            }
            // Authoritative-read rule: a match must be backed by either a
            // fetched file (gh.getContent) or a custom-property read
            // (gh.getProperties / gh.listOrgProperties). Both are real reads, not
            // a stale search index — a search hit alone is never proof.
            guard collector.hasReceipt(repo: ref.fullName, path: path)
                    || collector.hasPropertyReceipt(repo: ref.fullName) else {
                ctx.exception = JSValue(newErrorFromMessage:
                    "reportMatch: no authoritative read for \(ref.fullName) \(path) — call gh.getContent (files) or gh.getProperties/gh.listOrgProperties (custom properties) first; search results are candidates, not proof",
                    in: ctx)
                return
            }
            let explanation = stringArg(evidenceValue.objectForKeyedSubscript("explanation"))
            // Optional structured extraction for the Report step. Rides the same
            // receipt as the excerpt (already verified above), so a field value
            // can only exist for a file actually fetched this run. Values must
            // be scalars or arrays of scalars — nested objects are refused so
            // the report's comparison matrix stays a clean union of columns.
            var fields: [String: JSONValue]?
            if let fieldsValue = evidenceValue.objectForKeyedSubscript("fields"),
               !fieldsValue.isUndefined, !fieldsValue.isNull {
                do {
                    let parsed = try parseFields(fieldsValue)
                    if !parsed.isEmpty { fields = parsed }
                } catch let error as HostError {
                    ctx.exception = JSValue(newErrorFromMessage: "reportMatch: \(error.message)", in: ctx)
                    return
                } catch {
                    ctx.exception = JSValue(newErrorFromMessage: "reportMatch: invalid evidence.fields", in: ctx)
                    return
                }
            }
            var evidence = Evidence(path: path, excerpt: excerpt, explanation: explanation, fields: fields)
            // The receipt rule guarantees the file content is cached; locate
            // the match against the real bytes so the review pane can show it
            // in situ and highlight exactly the matched lines — the UI never
            // re-guesses the match from the excerpt.
            if let content = collector.fetchedContent(repo: ref.fullName, path: path) {
                if let loc = locateMatch(around: excerpt, in: content) {
                    evidence.context = loc.text
                    evidence.contextStartLine = loc.startLine
                    evidence.matchLines = loc.matchLines
                    evidence.noSpecificLine = loc.noSpecificLine
                } else {
                    // Excerpt isn't present verbatim (e.g. the script normalised
                    // whitespace): show it as-is rather than nothing, and flag
                    // that there's no located line to highlight.
                    evidence.context = excerpt
                    evidence.contextStartLine = 1
                    evidence.noSpecificLine = true
                }
            }
            collector.upsert(repo: ref, status: .verifiedMatch, reason: explanation, evidence: evidence)
            let auditDetail = fields.map { "\(path) [fields: \($0.keys.sorted().joined(separator: ", "))]" } ?? path
            collector.audit(kind: "job.reportMatch", repo: ref.fullName, detail: auditDetail)
        }
        job.setObject(unsafeBitCast(reportMatch, to: AnyObject.self),
                      forKeyedSubscript: "reportMatch" as NSString)

        let skip: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, reasonValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            let reason = describe(reasonValue) ?? "skipped"
            collector.upsert(repo: ref, status: .skipped, reason: reason)
        }
        job.setObject(unsafeBitCast(skip, to: AnyObject.self), forKeyedSubscript: "skip" as NSString)

        let fail: @convention(block) (JSValue?, JSValue?) -> Void = { repoValue, messageValue in
            guard let repoValue, let ref = resolveRepo(repoValue, collector: collector) else { return }
            let message = describe(messageValue) ?? "error"
            collector.upsert(repo: ref, status: .failed, reason: message)
            collector.audit(kind: "job.error", repo: ref.fullName, detail: message)
        }
        job.setObject(unsafeBitCast(fail, to: AnyObject.self), forKeyedSubscript: "error" as NSString)

        let progress: @convention(block) (JSValue?) -> Void = { messageValue in
            collector.progress(describe(messageValue) ?? "")
        }
        job.setObject(unsafeBitCast(progress, to: AnyObject.self),
                      forKeyedSubscript: "progress" as NSString)

        let log: @convention(block) (JSValue?) -> Void = { messageValue in
            collector.log(describe(messageValue) ?? "")
        }
        job.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)

        let writeState: @convention(block) (JSValue?, JSValue?) -> Void = { keyValue, value in
            guard let key = stringArg(keyValue) else { return }
            collector.writeState(key: key, value: value?.toObject() ?? NSNull())
        }
        job.setObject(unsafeBitCast(writeState, to: AnyObject.self),
                      forKeyedSubscript: "writeState" as NSString)

        let readState: @convention(block) (JSValue?) -> JSValue = { keyValue in
            let ctx = JSContext.current()!
            guard let key = stringArg(keyValue), let value = collector.readState(key: key) else {
                return JSValue(nullIn: ctx)
            }
            return JSValue(object: value, in: ctx)
        }
        job.setObject(unsafeBitCast(readState, to: AnyObject.self),
                      forKeyedSubscript: "readState" as NSString)

        job.setObject(params, forKeyedSubscript: "params" as NSString)

        context.setObject(job, forKeyedSubscript: "job" as NSString)
    }

    // MARK: - parse

    private static func installParse(in context: JSContext) {
        guard let parse = JSValue(newObjectIn: context) else { return }

        let yaml: @convention(block) (JSValue?) -> JSValue = { textValue in
            let ctx = JSContext.current()!
            guard let text = stringArg(textValue) else {
                ctx.exception = JSValue(newErrorFromMessage: "parse.yaml: text string is required", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            do {
                let object = try Yams.load(yaml: text)
                return JSValue(object: jsonSafe(object ?? NSNull()), in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: "YAML parse error: \(error)", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        parse.setObject(unsafeBitCast(yaml, to: AnyObject.self), forKeyedSubscript: "yaml" as NSString)

        let json: @convention(block) (JSValue?) -> JSValue = { textValue in
            let ctx = JSContext.current()!
            guard let text = stringArg(textValue), let data = text.data(using: .utf8) else {
                ctx.exception = JSValue(newErrorFromMessage: "parse.json: text string is required", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
            do {
                let object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                return JSValue(object: object, in: ctx)
            } catch {
                ctx.exception = JSValue(newErrorFromMessage: "JSON parse error: \(error.localizedDescription)", in: ctx)
                return JSValue(undefinedIn: ctx)
            }
        }
        parse.setObject(unsafeBitCast(json, to: AnyObject.self), forKeyedSubscript: "json" as NSString)

        let toml: @convention(block) (JSValue?) -> JSValue = { _ in
            let ctx = JSContext.current()!
            ctx.exception = JSValue(newErrorFromMessage:
                "parse.toml: TOML parsing is not yet supported by the host", in: ctx)
            return JSValue(undefinedIn: ctx)
        }
        parse.setObject(unsafeBitCast(toml, to: AnyObject.self), forKeyedSubscript: "toml" as NSString)

        context.setObject(parse, forKeyedSubscript: "parse" as NSString)
    }

    private static func installConsole(in context: JSContext, collector: JobCollector) {
        guard let console = JSValue(newObjectIn: context) else { return }
        let log: @convention(block) () -> Void = {
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            collector.log(args.map { $0.toString() ?? "" }.joined(separator: " "))
        }
        console.setObject(unsafeBitCast(log, to: AnyObject.self), forKeyedSubscript: "log" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    // MARK: - Helpers

    /// Where a reported match sits inside the fetched file content, resolved
    /// against the real bytes so the review pane never re-guesses it. Returns
    /// the context window to show, its 1-based start line, the absolute line
    /// numbers to highlight, and whether the match has no single line to point
    /// at (a whole-file excerpt). Located by the excerpt's first non-empty
    /// line; nil when the excerpt is blank or can't be found, in which case the
    /// caller falls back to showing the excerpt itself.
    static func locateMatch(around excerpt: String, in content: String,
                            radius: Int = 3)
        -> (text: String, startLine: Int, matchLines: [Int], noSpecificLine: Bool)? {
        let fileLines = content.components(separatedBy: "\n")
        let trimmedFile = fileLines.map { $0.trimmingCharacters(in: .whitespaces) }
        let nonEmptyFileCount = trimmedFile.filter { !$0.isEmpty }.count
        let excerptLines = excerpt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let firstNeedle = excerptLines.first else { return nil }

        // A whole-file excerpt points at no single line: highlight nothing and
        // let the caller caption it, rather than lighting up the whole window.
        if nonEmptyFileCount > 0, excerptLines.count >= nonEmptyFileCount {
            let end = min(fileLines.count, radius * 2 + 1)
            return (fileLines[0..<end].joined(separator: "\n"), 1, [], true)
        }

        guard let anchor = trimmedFile.firstIndex(where: { $0.contains(firstNeedle) })
        else { return nil }

        // The same window the review pane has always shown: a few lines either
        // side of the match, with the excerpt's own span capped so it can't
        // widen the window without bound.
        let excerptSpan = min(excerptLines.count, 8)
        let lo = max(0, anchor - radius)
        let hi = min(fileLines.count, anchor + excerptSpan + radius)
        let excerptSet = Set(excerptLines)
        var matched = (lo..<hi)
            .filter { !trimmedFile[$0].isEmpty && excerptSet.contains(trimmedFile[$0]) }
            .map { $0 + 1 }
        // A sub-line fragment matches no whole line; highlight the located line.
        if matched.isEmpty { matched = [anchor + 1] }
        return (fileLines[lo..<hi].joined(separator: "\n"), lo + 1, matched, false)
    }

    /// Wraps async Swift host work in a JS Promise.
    ///
    /// Threading contract: the detached task performs only Swift async work
    /// (network/fixture I/O). Settling the promise — which synchronously runs
    /// the script's continuation and drains JSC microtasks — is dispatched
    /// onto the run's dedicated serial vmQueue. JS never executes on the Swift
    /// cooperative pool (running it there starves the pool and deadlocks once
    /// enough host calls are in flight), and single-queue execution keeps the
    /// VM single-threaded.
    private static func hostPromise(limiter: AsyncSemaphore, cancel: CancelBox,
                                    vmQueue: DispatchQueue,
                                    work: @escaping @Sendable () async throws -> Any?) -> JSValue {
        let ctx = JSContext.current()!
        return JSValue(newPromiseIn: ctx) { resolve, reject in
            guard let resolve, let reject else { return }
            Task.detached {
                await limiter.wait()
                let settle: (JSValue, Any) -> Void = { fn, argument in
                    vmQueue.async { fn.call(withArguments: [argument]) }
                }
                do {
                    if cancel.isCancelled { throw HostError.cancelled }
                    let value = try await work()
                    await limiter.signal()
                    settle(resolve, value ?? NSNull())
                } catch {
                    await limiter.signal()
                    let message = errorMessage(error)
                    vmQueue.async {
                        if let context = reject.context,
                           let errorValue = JSValue(newErrorFromMessage: message, in: context) {
                            reject.call(withArguments: [errorValue])
                        } else {
                            reject.call(withArguments: [message])
                        }
                    }
                }
            }
        }
    }

    private static func rejectedPromise(_ message: String) -> JSValue {
        let ctx = JSContext.current()!
        return JSValue(newPromiseIn: ctx) { _, reject in
            reject?.call(withArguments: [JSValue(newErrorFromMessage: message, in: ctx) ?? message])
        }
    }

    static func errorMessage(_ error: Error) -> String {
        if let host = error as? HostError { return host.message }
        if error is CancellationError { return HostError.cancelled.message }
        if let gh = error as? GitHubClientError { return gh.errorDescription ?? String(describing: gh) }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// Soft ceiling on one match's structured fields, in bytes of JSON. Extends
    /// the "excerpts are a handful of lines, never whole files" rule to the
    /// structured layer: extract the comparison-relevant values, not the doc.
    static let maxFieldsBytes = 8 * 1024

    /// Convert and validate a `reportMatch` `fields` object into typed values.
    /// Reads JSValues directly (so booleans aren't confused with numbers) and
    /// refuses nested objects and oversized payloads.
    static func parseFields(_ fieldsValue: JSValue) throws -> [String: JSONValue] {
        guard fieldsValue.isObject, !fieldsValue.isArray,
              let keyed = fieldsValue.toDictionary() else {
            throw HostError.invalidArgument(
                "evidence.fields must be an object of scalar (or array-of-scalar) values")
        }
        var out: [String: JSONValue] = [:]
        for case let key as String in keyed.keys.sorted(by: { String(describing: $0) < String(describing: $1) }) {
            guard let element = fieldsValue.objectForKeyedSubscript(key) else { continue }
            out[key] = try jsonValue(element, key: key, depth: 0)
        }
        // Size guard against whole-document dumps.
        if let data = try? JSONEncoder().encode(out), data.count > maxFieldsBytes {
            throw HostError.invalidArgument(
                "evidence.fields is too large (\(data.count) bytes > \(maxFieldsBytes)) — extract the comparison-relevant values, not the whole document")
        }
        return out
    }

    private static func jsonValue(_ value: JSValue, key: String, depth: Int) throws -> JSONValue {
        if value.isNull || value.isUndefined { return .null }
        if value.isBoolean { return .bool(value.toBool()) }
        if value.isNumber { return .number(value.toDouble()) }
        if value.isString { return .string(value.toString() ?? "") }
        if value.isArray {
            guard depth == 0 else {
                throw HostError.invalidArgument("evidence.fields.\(key): arrays of arrays are not allowed")
            }
            let count = Int(value.objectForKeyedSubscript("length")?.toInt32() ?? 0)
            var items: [JSONValue] = []
            items.reserveCapacity(count)
            for index in 0..<count {
                guard let element = value.atIndex(index) else { continue }
                items.append(try jsonValue(element, key: key, depth: depth + 1))
            }
            return .array(items)
        }
        throw HostError.invalidArgument(
            "evidence.fields.\(key) is a nested object — flatten it to scalar values with dotted-path keys")
    }

    static func stringArg(_ value: JSValue?) -> String? {
        guard let value, value.isString else { return nil }
        return value.toString()
    }

    static func describe(_ value: JSValue?) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        return value.toString()
    }

    /// Accepts either "owner/name" or a Repo object from a prior gh call.
    static func repoName(_ value: JSValue?) -> String? {
        guard let value else { return nil }
        if value.isString {
            let s = value.toString() ?? ""
            return s.isEmpty ? nil : s
        }
        if value.isObject, let nameValue = value.objectForKeyedSubscript("fullName"),
           nameValue.isString {
            let s = nameValue.toString() ?? ""
            return s.isEmpty ? nil : s
        }
        return nil
    }

    static func resolveRepo(_ value: JSValue, collector: JobCollector) -> RepoRef? {
        guard let fullName = repoName(value) else { return nil }
        if value.isObject {
            var ref = collector.repo(named: fullName)
            if let branch = stringArg(value.objectForKeyedSubscript("defaultBranch")) {
                ref.defaultBranch = branch
            }
            if let archived = value.objectForKeyedSubscript("archived"), archived.isBoolean {
                ref.archived = archived.toBool()
            }
            return ref
        }
        return collector.repo(named: fullName)
    }

    /// Yams can produce dictionaries with non-string keys; make everything
    /// JS-bridgeable before handing it to JSValue(object:in:).
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [AnyHashable: Any]:
            var out = [String: Any]()
            for (key, inner) in dict { out[String(describing: key.base)] = jsonSafe(inner) }
            return out
        case let array as [Any]:
            return array.map(jsonSafe)
        case is NSNull, is String, is Int, is Double, is Bool, is NSNumber:
            return value
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        default:
            return String(describing: value)
        }
    }
}
