// DeepSeekSpend — macOS 菜单栏实时消费显示器
// 编译: swiftc -O -target arm64-apple-macosx13.0 main.swift -o DeepSeekSpend \
//        -framework AppKit -framework SwiftUI -framework ServiceManagement

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 快照数据模型（与 collector.mjs 输出的 snapshot.json 对应）

struct Snapshot: Decodable {
    var generatedAt: Double
    var hourStart: Double
    var overall: Overall
    var hourly: [HourBucket]
    var tasks: [MergedTask]
    var projects: [ProjectRow]
    var balance: Balance?
    var balanceError: String?
    var workbuddy: WorkBuddyOverview?
    var workbuddyError: String?
    var errors: [String]

    struct Overall: Decodable {
        var hour: Double
        var today: Double
        var total: Double
    }
    struct HourBucket: Decodable {
        var start: Double
        var cost: Double
    }
    struct Tokens: Decodable {
        var input: Int
        var output: Int
        var cacheRead: Int
    }
    /// 按顶层会话归并后的任务（含其派生的全部子代理）
    struct MergedTask: Decodable {
        var key: String
        var name: String
        var project: String?
        var cwd: String?
        var running: Bool
        var hour: Double
        var today: Double
        var total: Double
        var sessionCount: Int
        var subCount: Int?
        var model: String?
        var tokens: Tokens
        var lastEventAt: Double?
    }
    struct ProjectRow: Decodable {
        var cwd: String?
        var name: String
        var hour: Double
        var today: Double
        var total: Double
        var running: Bool
        var sessionCount: Int
        var lastEventAt: Double?
        var tasks: [MergedTask]

        var id: String { cwd ?? name }
    }
    struct Balance: Decodable {
        var currency: String
        var totalBalance: String?
        var grantedBalance: String?
        var toppedUpBalance: String?
        var fetchedAt: Double?
    }
    /// WorkBuddy 绑定的 DeepSeek 消费总览（单位：元）
    struct WorkBuddyOverview: Decodable {
        var hour: Double
        var today: Double
        var total: Double
        var lastEventAt: Double?
        var calls: Int?
    }
}

// MARK: - 状态模型

final class SpendingModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var loadError: String?
    @Published var collectorRunning = false
    @Published var launchAtLogin = false

    var statusItem: NSStatusItem?
    private var timer: Timer?
    private var collector: Process?
    private let posix = Locale(identifier: "en_US_POSIX")
    var quitting = false

    // 路径
    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DeepSeekSpend")
    var configPath: URL { supportDir.appendingPathComponent("config.json") }
    var snapshotPath: URL { supportDir.appendingPathComponent("snapshot.json") }
    var triggerPath: URL { supportDir.appendingPathComponent("refresh.trigger") }

    var config: [String: Any] = [:]
    var hasRunning: Bool { snapshot?.tasks.contains(where: { $0.running }) ?? false }
    var hasError: Bool { snapshot?.errors.isEmpty == false || snapshot?.balanceError != nil }

    func start() {
        if CommandLine.arguments.contains("--demo") {
            loadDemoSnapshot()
            refreshLaunchAtLoginStatus()
            return
        }
        prepareSupportFiles()
        loadConfig()
        refreshLaunchAtLoginStatus()
        startCollector()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.readSnapshot()
        }
        timer?.tolerance = 1.0
        readSnapshot()
    }

    private func loadDemoSnapshot() {
        guard let url = Bundle.main.url(forResource: "demo-snapshot", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              var snap = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            loadError = "匿名演示数据缺失"
            return
        }
        let hour = Date().timeIntervalSince1970 * 1000
        let hourStart = floor(hour / 3_600_000) * 3_600_000
        snap.generatedAt = hour
        snap.hourStart = hourStart
        for index in snap.hourly.indices {
            snap.hourly[index].start += hourStart
        }
        snapshot = snap
        loadError = nil
        updateStatusTitle()
    }

    /// 首次运行时把打包进 Resources 的 collector 和 config 复制到 Application Support。
    /// collector 始终跟随 App 内版本；配置保留用户的路径和轮询设置，
    /// 但价格表跟随已核对的应用版本，避免旧版错误单价继续生效。
    func prepareSupportFiles() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let resources = Bundle.main.resourceURL else { return }
        let bundledCollector = resources.appendingPathComponent("collector.mjs")
        let bundledConfig = resources.appendingPathComponent("config.json")
        let targetCollector = supportDir.appendingPathComponent("collector.mjs")
        if FileManager.default.fileExists(atPath: bundledCollector.path) {
            let same = (try? Data(contentsOf: bundledCollector)) == (try? Data(contentsOf: targetCollector))
            if !same {
                try? FileManager.default.removeItem(at: targetCollector)
                try? FileManager.default.copyItem(at: bundledCollector, to: targetCollector)
            }
        }
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try? FileManager.default.copyItem(at: bundledConfig, to: configPath)
        } else if let bundledData = try? Data(contentsOf: bundledConfig),
                  let currentData = try? Data(contentsOf: configPath),
                  let bundled = try? JSONSerialization.jsonObject(with: bundledData) as? [String: Any],
                  var current = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any] {
            current["prices"] = bundled["prices"]
            current["pricingSource"] = bundled["pricingSource"]
            current["pricingVerifiedAt"] = bundled["pricingVerifiedAt"]
            current.removeValue(forKey: "peakEpochIso")
            current.removeValue(forKey: "peakHoursBeijing")
            if let merged = try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]) {
                try? merged.write(to: configPath, options: .atomic)
            }
        }
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loadError = "无法读取配置文件"
            return
        }
        config = obj
        loadError = nil
    }

    func resolveNode() -> String? {
        // 1. Release 内置运行时，避免依赖用户机器上的 Node 路径与版本。
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node").path,
           nodeSupportsZstd(bundled) {
            return bundled
        }
        // 2. 兼容旧版配置中的 node 路径。
        if let baked = config["nodePath"] as? String, !baked.isEmpty,
           nodeSupportsZstd(baked) {
            return baked
        }
        // 3. 常见安装位置 + DSH 自带运行时。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dshRuntimeNode = home
            .appendingPathComponent("Documents/DeepSeek-Harness/.runtime/node/bin/node").path
        let candidates = [
            dshRuntimeNode,
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where nodeSupportsZstd(c) {
            return c
        }
        // 4. 兜底：走 shell 的 PATH。
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v node"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let out, p.terminationStatus == 0, nodeSupportsZstd(out) { return out }
        } catch {}
        return nil
    }

    private func nodeSupportsZstd(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-e", "require('node:zlib').zstdDecompressSync"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    func startCollector() {
        collector?.terminate()
        guard let node = resolveNode() else {
            loadError = "未找到 Node.js（需要 v22.15+ 以解压 zstd 日志）"
            return
        }
        let collectorPath = supportDir.appendingPathComponent("collector.mjs")
        guard FileManager.default.fileExists(atPath: collectorPath.path) else {
            loadError = "采集器脚本缺失"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [
            collectorPath.path, "--config", configPath.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.terminationHandler = { [weak self] proc in
            // 采集器意外退出时自动重启（App 退出除外）
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                self.collectorRunning = false
                if proc.terminationStatus != 0 && self.collector === proc {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startCollector() }
                }
            }
        }
        do {
            try p.run()
            collector = p
            collectorRunning = true
            loadError = nil
        } catch {
            loadError = "启动采集器失败: \(error.localizedDescription)"
        }
    }

    func readSnapshot() {
        guard let data = try? Data(contentsOf: snapshotPath) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            DispatchQueue.main.async {
                self.snapshot = snap
                self.updateStatusTitle()
            }
        } catch {
            DispatchQueue.main.async { self.loadError = "快照解析失败: \(error.localizedDescription)" }
        }
    }

    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let cost = snapshot?.overall.hour ?? 0
        let text = money(cost)
        // 纯文本标题避免 macOS 沿用旧状态栏图标的隐藏布局。
        let plain = "● \(text)"
        button.title = plain
        button.toolTip = "DeepSeek 消费｜本自然小时 \(text)（\(hasError ? "异常" : (hasRunning ? "任务运行中" : "空闲"))）"
    }

    func forceRefresh() {
        try? "refresh".write(to: triggerPath, atomically: true, encoding: .utf8)
        // 顺手立刻再读一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.readSnapshot() }
    }

    func openHarness() {
        let base = config["apiBase"] as? String ?? "http://127.0.0.1:3080"
        NSWorkspace.shared.open(URL(string: base)!)
    }

    func openDeepSeekPlatform() {
        NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
    }

    func openProject(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            loadError = "开机自启设置失败: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func money(_ v: Double) -> String {
        if v > 0 && v < 0.01 {
            return String(format: "¥%.4f", locale: posix, v)
        }
        return String(format: "¥%.2f", locale: posix, v)
    }

    func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - 弹窗视图

struct MenuView: View {
    @ObservedObject var model: SpendingModel
    private let width: CGFloat = 348
    private let colW: CGFloat = 76
    private let chevW: CGFloat = 12
    private let folderW: CGFloat = 14
    @State private var expandedProjects: Set<String> = []

    // 项目列表排序（Excel 式：点表头切换列，再点切换方向）
    enum SortColumn { case hour, total }
    @State private var sortColumn: SortColumn = .total
    @State private var sortAscending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.vertical, 8)
            if let snap = model.snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        bigNumber(snap)
                        chart(snap)
                        combinedList(snap)
                        workbuddySection(snap)
                        if let err = model.loadError {
                            Text(err).font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    .padding(.bottom, 8)
                }
            } else {
                Text(model.loadError ?? "等待第一份数据…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 60)
                    .frame(maxWidth: .infinity)
            }
            Divider().padding(.vertical, 8)
            footer
        }
        .padding(14)
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.snapshot?.generatedAt) { _ in
            // 有任务在跑的项目自动展开，其余保持收起（列表更短）
            guard let snap = model.snapshot else { return }
            for p in snap.projects where p.running {
                expandedProjects.insert(p.id)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek Harness")
                    .font(.system(size: 15, weight: .semibold))
                Text(hourRangeText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let bal = balanceText() {
                Button(action: { model.openDeepSeekPlatform() }) {
                    Text(bal)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .quaternaryLabelColor)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("点击跳转 DeepSeek 平台（查看用量 / 充值）")
            }
        }
    }

    private func hourRangeText() -> String {
        guard let snap = model.snapshot else { return "自然小时窗口" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let start = Date(timeIntervalSince1970: snap.hourStart / 1000)
        let end = start.addingTimeInterval(3600)
        return "本自然小时 \(f.string(from: start)) – \(f.string(from: end))"
    }

    private func balanceText() -> String? {
        guard let bal = model.snapshot?.balance, let total = Double(bal.totalBalance ?? "") else { return nil }
        return "余额 \(model.money(total))"
    }

    // MARK: 大数字

    private func bigNumber(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.money(snap.overall.hour))
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.accentColor)
            Text("全部任务本小时消费")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                statCell(label: "今日", value: snap.overall.today)
                statCell(label: "累计", value: snap.overall.total)
            }
        }
    }

    private func statCell(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(model.money(value)).font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: 近 24 小时柱状图（点击柱子显示该小时的消费金额）

    @State private var selectedSlot: Double?

    private func chart(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("近 24 个自然小时").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let slot = selectedSlot,
                   let cost = snap.hourly.first(where: { $0.start == slot })?.cost {
                    Text("\(slotLabel(slot)) 消费 \(model.money(cost))")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                } else if let maxCost = snap.hourly.map(\.cost).max(), maxCost > 0 {
                    Text("点击柱子查看金额").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { i in
                    barColumn(i, snap: snap)
                }
            }
            .frame(height: 44)
        }
    }

    private func barColumn(_ i: Int, snap: Snapshot) -> some View {
        let currentStart = snap.hourStart
        let slotStart = currentStart - Double(23 - i) * 3600 * 1000
        let cost = snap.hourly.first(where: { $0.start == slotStart })?.cost ?? 0
        let maxCost = max(snap.hourly.map(\.cost).max() ?? 0, 0.0001)
        let ratio = cost > 0 ? max(CGFloat(cost / maxCost), 0.06) : 0.015
        let isSelected = selectedSlot == slotStart
        return Button(action: {
            selectedSlot = isSelected ? nil : slotStart
        }) {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isSelected ? Color.accentColor
                          : (i == 23 ? Color.accentColor.opacity(0.75) : Color(nsColor: .separatorColor)))
                    .frame(height: 44 * ratio)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(slotLabel(slotStart))：\(model.money(cost))（点击可固定显示）")
    }

    private func slotLabel(_ start: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:00"
        let d = Date(timeIntervalSince1970: start / 1000)
        let end = d.addingTimeInterval(3600)
        return "\(f.string(from: d))–\(f.string(from: end))"
    }

    // MARK: 合并列表：项目行同时显示「实时 + 累计」，点击展开任务明细，点表头排序

    private func combinedList(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            // 列头（与下方行右对齐的列宽保持一致；实时/累计可点击排序）
            HStack(spacing: 0) {
                Color.clear.frame(width: chevW + 6)
                Text("项目")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                sortHeaderButton(label: "实时", col: .hour)
                sortHeaderButton(label: "累计", col: .total)
                Color.clear.frame(width: folderW + 6)
            }
            Divider().padding(.vertical, 2)
            // DeepSeek 消费合计行：固定在顶部，与项目行并列，不展开、不参与排序
            deepseekTotalRow(snap)
            Divider().padding(.vertical, 3)
            if snap.projects.isEmpty {
                Text("暂无项目数据").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(sortedProjects(snap.projects), id: \.id) { proj in
                    VStack(alignment: .leading, spacing: 2) {
                        projectRowView(proj)
                        if expandedProjects.contains(proj.id) {
                            ForEach(sortedTasks(proj.tasks), id: \.key) { task in
                                taskRowView(task)
                            }
                            .padding(.leading, chevW + 10)
                        }
                    }
                }
            }
        }
    }

    // MARK: 排序

    /// DeepSeek 消费合计行：全部项目汇总，与项目行并列（同一列宽对齐），不列细分任务
    private func deepseekTotalRow(_ snap: Snapshot) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: chevW + 6)
            HStack(spacing: 6) {
                Image(systemName: "yensign.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                Text("DeepSeek 消费")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            Text(model.money(snap.overall.hour))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: colW, alignment: .trailing)
            Text(model.money(snap.overall.total))
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(Color.accentColor)
                .frame(width: colW, alignment: .trailing)
            Color.clear.frame(width: folderW + 6)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help("全部项目合计：实时 = 本自然小时所有任务的消费，累计 = 历史总消费")
    }

    private func toggleSort(_ col: SortColumn) {
        if sortColumn == col {
            sortAscending.toggle()
        } else {
            sortColumn = col
            sortAscending = false // 换列后默认从大到小
        }
    }

    private func sortHeaderButton(label: String, col: SortColumn) -> some View {
        let active = sortColumn == col
        let upActive = active && sortAscending
        let downActive = active && !sortAscending
        return Button(action: { toggleSort(col) }) {
            HStack(spacing: 3) {
                VStack(spacing: -3) {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(upActive ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6, weight: .bold))
                        .foregroundStyle(downActive ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                }
                Text(label)
                    .foregroundStyle(active ? Color.primary : Color.secondary)
            }
            .font(.caption.weight(.semibold))
            .frame(width: colW, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(active
              ? (sortAscending ? "按\(label)从小到大排序（点击切换为从大到小）" : "按\(label)从大到小排序（点击切换为从小到大）")
              : "点击按\(label)排序")
    }

    private func sortedProjects(_ projs: [Snapshot.ProjectRow]) -> [Snapshot.ProjectRow] {
        projs.sorted { a, b in
            let va = sortColumn == .hour ? a.hour : a.total
            let vb = sortColumn == .hour ? b.hour : b.total
            return sortAscending ? va < vb : va > vb
        }
    }

    private func sortedTasks(_ tasks: [Snapshot.MergedTask]) -> [Snapshot.MergedTask] {
        tasks.sorted { a, b in
            let va = sortColumn == .hour ? a.hour : a.total
            let vb = sortColumn == .hour ? b.hour : b.total
            return sortAscending ? va < vb : va > vb
        }
    }

    private func projectRowView(_ proj: Snapshot.ProjectRow) -> some View {
        let isExpanded = expandedProjects.contains(proj.id)
        return HStack(spacing: 0) {
            Button(action: { toggleExpand(proj.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: chevW)
                    Circle().fill(proj.running ? Color.green : Color.clear)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().stroke(proj.running ? Color.green : Color(nsColor: .separatorColor), lineWidth: 1))
                    Text(proj.name)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(proj.sessionCount) 个会话 · 今日 \(model.money(proj.today))")
            Spacer(minLength: 8)
            Text(model.money(proj.hour))
                .font(.callout.monospacedDigit())
                .frame(width: colW, alignment: .trailing)
            Text(model.money(proj.total))
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: colW, alignment: .trailing)
            Button(action: { model.openProject(proj.cwd) }) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(width: folderW)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .help("在 Finder 中打开项目文件夹")
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func taskRowView(_ task: Snapshot.MergedTask) -> some View {
        HStack(spacing: 0) {
            Circle().fill(task.running ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(task.running ? Color.green : Color.clear, lineWidth: 1))
            Text(task.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            Spacer(minLength: 8)
            Text(model.money(task.hour))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: colW, alignment: .trailing)
            Text(model.money(task.total))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: colW, alignment: .trailing)
            Color.clear.frame(width: folderW + 6)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help(taskHelp(task))
    }

    private func taskHelp(_ task: Snapshot.MergedTask) -> String {
        let subs = task.subCount ?? 0
        var parts = [subs > 0 ? "\(task.sessionCount) 个会话（含 \(subs) 个子代理）" : "\(task.sessionCount) 个会话"]
        if let m = task.model { parts.append(m) }
        parts.append("输入 \(model.compactTokens(task.tokens.input + task.tokens.cacheRead))")
        parts.append("输出 \(model.compactTokens(task.tokens.output))")
        parts.append("今日 \(model.money(task.today))")
        return parts.joined(separator: " · ")
    }

    private func toggleExpand(_ id: String) {
        if expandedProjects.contains(id) {
            expandedProjects.remove(id)
        } else {
            expandedProjects.insert(id)
        }
    }

    // MARK: WorkBuddy 总览（绑定的 DeepSeek 用量金额，只做总览不列明细）

    private func workbuddySection(_ snap: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 2)
            HStack {
                HStack(spacing: 5) {
                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("WorkBuddy · DeepSeek 用量")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if let wb = snap.workbuddy, wb.lastEventAt != nil {
                    Text("本地 trace 统计 · 单位 ¥")
                        .font(.caption2)
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor))
                }
            }
            if let wb = snap.workbuddy {
                HStack(spacing: 18) {
                    wbStatCell(label: "本小时", value: wb.hour)
                    wbStatCell(label: "今日", value: wb.today)
                    wbStatCell(label: "累计", value: wb.total)
                    if let calls = wb.calls {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("调用").font(.caption2).foregroundColor(.secondary)
                            Text("\(calls) 次")
                                .font(.callout.weight(.semibold).monospacedDigit())
                        }
                    }
                }
            } else {
                Text(snap.workbuddyError ?? "未检测到 WorkBuddy 的 DeepSeek 用量数据")
                    .font(.caption)
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
        }
    }

    private func wbStatCell(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            Text(model.money(value))
                .font(.callout.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: { model.forceRefresh() }) {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            Button(action: { model.openHarness() }) {
                Label("打开 Harness", systemImage: "globe")
            }
            Spacer()
            Toggle("开机自启", isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("开启后，登录 Mac 时自动启动本应用")
            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label("退出", systemImage: "power")
            }
        }
        .font(.caption)
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = SpendingModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var demoWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        model.statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuView(model: model).environment(\.font, .system(size: 12))
        )
        popover.contentSize = NSSize(width: 376, height: 560)

        model.updateStatusTitle()
        model.start()
        if CommandLine.arguments.contains("--show-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showDemoWindow()
            }
        }
    }

    private func showDemoWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 376, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek 消费"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentViewController = NSHostingController(
            rootView: MenuView(model: model)
                .environment(\.font, .system(size: 12))
                .frame(width: 376, height: 560)
        )
        window.center()
        let controller = NSWindowController(window: window)
        demoWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quitting = true
        // 采集器子进程会在父进程退出后自行结束
    }
}

// MARK: - 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--show-window") ? .regular : .accessory)
app.run()
