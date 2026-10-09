import Foundation

// `SiteSettings` 的归一化、去重、合并与导航 host 上限淘汰。
// 与 `SiteStore.swift` 拆开是为了控制单文件长度（lint file_length 600）。

public extension SiteSettings {
    /// - Parameter protectedHosts: 正在探测 / 正在验证中的 host，淘汰时必须跳过。
    ///   只在持久化写入时传入（引擎上报），用户直接编辑设置时不传。
    mutating func normalize(protectedHosts: Set<String> = []) {
        navigationURLs = Self.normalizedNavigationEntries(navigationURLs)
        hosts = Self.mergedHostEntries(hosts)
        hosts = enforcedNavigationLimit(
            hosts,
            limit: navigationHostLimit,
            currentHostID: currentHostID,
            protectedHosts: protectedHosts
        )

        if !navigationURLs.contains(where: { $0.id == currentNavigationID }) {
            currentNavigationID = navigationURLs.first?.id
        }
        if !hosts.contains(where: { $0.id == currentHostID }) {
            currentHostID = hosts.first?.id
        }
        if let currentHostID {
            let currentHostIsUsable = hosts.contains {
                $0.id == currentHostID && $0.coolingUntil == nil
            }
            if !currentHostIsUsable {
                self.currentHostID = hosts.first { !$0.isCooling() }?.id ?? currentHostID
            }
        }
        ensureStandbyHost()
    }

    private mutating func ensureStandbyHost() {
        let hasUsableStandby = hosts.contains {
            $0.isStandby
                && $0.id != currentHostID
                && $0.hostStatus == .unguarded
                && !$0.isCooling()
        }
        guard !hasUsableStandby else { return }
        for index in hosts.indices {
            hosts[index].isStandby = false
        }
        if let index = hosts.firstIndex(where: {
            $0.id != currentHostID
                && $0.hostStatus == .unguarded
                && !$0.isCooling()
        }) {
            hosts[index].isStandby = true
        }
    }

    mutating func recordHost(
        _ rawHost: String,
        source: SiteEntrySource = .navigation,
        now: Date = Date()
    ) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let key = Self.canonicalHostKey(host)
        if let index = hosts.firstIndex(where: { Self.canonicalHostKey($0.value) == key }) {
            hosts[index].sources.insert(source)
            hosts[index].lastSucceededAt = now
            hosts[index].hostStatus = .unguarded
            hosts[index].coolingUntil = nil
            currentHostID = hosts[index].id
        } else {
            var entry = SiteEntry(value: host, sources: [source])
            entry.lastSucceededAt = now
            entry.hostStatus = .unguarded
            hosts.append(entry)
            currentHostID = entry.id
        }
        normalize()
    }

    mutating func updateHostState(
        value: String,
        status: HostStatus,
        coolingUntil: Date?,
        now: Date = Date()
    ) {
        let key = Self.canonicalHostKey(value)
        guard let index = hosts.firstIndex(where: { Self.canonicalHostKey($0.value) == key }) else {
            return
        }
        hosts[index].hostStatus = status
        hosts[index].coolingUntil = coolingUntil
        hosts[index].lastProbedAt = now
        if status == .unguarded {
            hosts[index].lastSucceededAt = now
        }
    }

    mutating func recordNavigationFailure(
        id: UUID,
        now: Date = Date()
    ) {
        guard let index = navigationURLs.firstIndex(where: { $0.id == id }) else { return }
        navigationURLs[index].consecutiveFailures += 1
        let failures = navigationURLs[index].consecutiveFailures
        let cooldown = TimeInterval(max(hostCooldownSeconds, 60))
        if failures == 1 {
            navigationURLs[index].navigationCoolingUntil = now.addingTimeInterval(cooldown)
            navigationURLs[index].navigationStatus = .cooling
        } else {
            let multiplier = failures == 2 ? 1.0 : 2.0
            navigationURLs[index].frozenUntil = now.addingTimeInterval(cooldown * multiplier)
            navigationURLs[index].navigationStatus = .frozen
        }
    }

    mutating func resetNavigationFailure(id: UUID) {
        guard let index = navigationURLs.firstIndex(where: { $0.id == id }) else { return }
        navigationURLs[index].consecutiveFailures = 0
        navigationURLs[index].navigationCoolingUntil = nil
        navigationURLs[index].frozenUntil = nil
        navigationURLs[index].navigationStatus = .active
    }

    mutating func setNavigationDisabled(id: UUID, disabled: Bool) {
        guard let index = navigationURLs.firstIndex(where: { $0.id == id }) else { return }
        navigationURLs[index].isDisabled = disabled
        navigationURLs[index].navigationStatus = disabled ? .disabled : .active
        if !disabled {
            navigationURLs[index].frozenUntil = nil
            navigationURLs[index].navigationCoolingUntil = nil
        }
    }

    static func canonicalHostKey(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") {
            value.removeLast()
        }
        guard !value.isEmpty else { return "" }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased()
        else {
            return value.lowercased()
        }
        let scheme = (components.scheme ?? "https").lowercased()
        // 去默认端口：`https://x:443` 与 `https://x` 必须视为同一个入口。
        let defaultPort = scheme == "https" ? 443 : 80
        guard let port = components.port, port != defaultPort else {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func normalizedNavigationEntries(_ entries: [SiteEntry]) -> [SiteEntry] {
        var seen = Set<String>()
        return entries.compactMap { entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard seen.insert(key).inserted else { return nil }
            var normalized = entry
            normalized.value = value
            normalized.sources = [.user]
            return normalized
        }
    }

    private static func mergedHostEntries(_ entries: [SiteEntry]) -> [SiteEntry] {
        var order: [String] = []
        var merged: [String: SiteEntry] = [:]
        for entry in entries {
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let key = canonicalHostKey(value)
            if var existing = merged[key] {
                existing.sources.formUnion(entry.sources)
                existing.originNavigationIDs.formUnion(entry.originNavigationIDs)
                existing.hostStatus = preferredStatus(existing.hostStatus, entry.hostStatus)
                existing.isStandby = existing.isStandby || entry.isStandby
                existing.lastProbedAt = maxDate(existing.lastProbedAt, entry.lastProbedAt)
                existing.lastVerifiedAt = maxDate(existing.lastVerifiedAt, entry.lastVerifiedAt)
                existing.lastSucceededAt = maxDate(existing.lastSucceededAt, entry.lastSucceededAt)
                existing.coolingUntil = maxDate(existing.coolingUntil, entry.coolingUntil)
                merged[key] = existing
            } else {
                var normalized = entry
                normalized.value = value
                merged[key] = normalized
                order.append(key)
            }
        }
        return order.compactMap { merged[$0] }
    }

    private static func preferredStatus(_ lhs: HostStatus, _ rhs: HostStatus) -> HostStatus {
        let rank: [HostStatus: Int] = [
            .unknown: 0,
            .unavailable: 1,
            .guarded: 2,
            .unguarded: 3,
        ]
        return (rank[lhs] ?? 0) >= (rank[rhs] ?? 0) ? lhs : rhs
    }

    private static func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func environmentNavigationURLs() -> [String] {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["SITE_NAVIGATION_URLS"] {
            if !env.isEmpty {
                return env.components(separatedBy: ",").filter { !$0.isEmpty }
            }
        }
        #endif
        return []
    }
}

/// 导航 host 上限淘汰（R8）。
///
/// 永不淘汰：active（currentHostID）、standby、正在探测 / 正在验证中（protectedHosts）。
/// 其余按优先级淘汰：冷却最久 → unavailable → 最久未成功（LRU）→ 从未成功过。
/// 放在类型外是刻意的：`SiteSettings` 扩展体已接近 lint 的类型体长度上限。
private func enforcedNavigationLimit(
    _ hosts: [SiteEntry],
    limit: Int,
    currentHostID: UUID?,
    protectedHosts: Set<String> = []
) -> [SiteEntry] {
    let clampedLimit = max(1, limit)
    let navigationOnly = hosts.filter { $0.isNavigationHost && !$0.isUserHost }
    guard navigationOnly.count > clampedLimit else { return hosts }

    let protectedKeys = Set(protectedHosts.map { SiteSettings.canonicalHostKey($0) })
    let removable = navigationOnly
        .filter {
            $0.id != currentHostID
                && !$0.isStandby
                && !protectedKeys.contains(SiteSettings.canonicalHostKey($0.value))
        }
        .sorted { lhs, rhs in
            evictionRank(lhs) < evictionRank(rhs)
        }
    var remaining = hosts
    var needRemove = navigationOnly.count - clampedLimit
    for entry in removable where needRemove > 0 {
        remaining.removeAll { $0.id == entry.id }
        needRemove -= 1
    }
    return remaining
}

private func evictionRank(_ entry: SiteEntry) -> (Int, Date, Date) {
    if entry.isCooling() {
        return (-1, entry.lastSucceededAt ?? .distantPast, entry.lastProbedAt ?? .distantPast)
    }
    let statusRank = switch entry.hostStatus {
    case .unavailable: 0
    case .guarded: 1
    case .unknown: 2
    case .unguarded: 3
    }
    return (
        statusRank,
        entry.lastSucceededAt ?? .distantPast,
        entry.lastProbedAt ?? .distantPast
    )
}
