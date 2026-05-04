import Foundation

/// One missing-environment finding to report.
struct Finding {
    let scene: SceneInfo
    let requirement: EnvRequirement
    /// The view chain from a scene root down to the view that declared the
    /// requirement. Useful in the report so the developer can see which
    /// descendant is at fault.
    let path: [String]
}

/// Joins `Catalogue` and `SceneCollector` output to produce findings.
///
/// For every scene: walk every reachable view in the transitive composition
/// graph, collect their `@Environment(...)` requirements, and flag any type
/// that no resolvable `.environment(...)` argument provides.
struct Analyzer {
    let catalogue: Catalogue
    let scenes: [SceneInfo]

    func findings() -> [Finding] {
        var out: [Finding] = []
        for scene in scenes {
            let reachable = transitiveViews(from: scene.rootViews)
            for view in reachable.keys.sorted() {
                guard let info = catalogue.views[view] else {
                    continue
                }
                for req in info.requirements {
                    if scene.provided.contains(req.kind) {
                        continue
                    }
                    out.append(
                        Finding(
                            scene: scene,
                            requirement: req,
                            path: reachable[view] ?? [view]
                        )
                    )
                }
            }
        }
        return out
    }

    /// BFS from each root, returning a map from reachable view name → the
    /// shortest path that reached it. The path lets the report show how the
    /// requirement gets pulled in.
    private func transitiveViews(from roots: [String]) -> [String: [String]] {
        var visited: [String: [String]] = [:]
        var queue: [(String, [String])] = roots.map { ($0, [$0]) }
        while !queue.isEmpty {
            let (current, path) = queue.removeFirst()
            if visited[current] != nil {
                continue
            }
            visited[current] = path
            guard let info = catalogue.views[current] else {
                continue
            }
            for child in info.children {
                if visited[child] == nil {
                    queue.append((child, path + [child]))
                }
            }
        }
        return visited
    }
}
