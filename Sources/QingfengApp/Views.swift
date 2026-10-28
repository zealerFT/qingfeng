import SwiftUI
import AppKit
import QingfengCore

struct RootView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                Group {
                    switch model.page {
                    case .overview: overview
                    case .history: history
                    default: itemList
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                footer
            }
        }
        .frame(minWidth: 1080, minHeight: 730)
        .background(Theme.background).foregroundStyle(Theme.ink)
        .tint(Theme.accent).preferredColorScheme(.light)
        .sheet(isPresented: $model.showConfirmation) { confirmation }
        .sheet(isPresented: $model.showIssues) { issueSheet }
        .sheet(isPresented: $model.showSettings) { settings }
        .alert("清风", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("知道了") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onChange(of: model.page) { _, _ in model.search = "" }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let url = Bundle.main.url(forResource: "Icon", withExtension: "png"), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().frame(width: 45, height: 45)
                } else {
                    Image(systemName: "wind").font(.system(size: 27, weight: .medium)).foregroundStyle(Theme.accent).frame(width: 45, height: 45)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("清风").font(.system(size: 24, weight: .semibold))
                    Text("轻一点，自在一点").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
            }.padding(.horizontal, 23).padding(.top, 44).padding(.bottom, 38)
            Text("我的 MAC").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Theme.muted)
                .padding(.horizontal, 27).padding(.bottom, 13)
            ForEach(Page.allCases) { page in
                Button { model.page = page } label: {
                    HStack(spacing: 12) {
                        Image(systemName: page.symbol).font(.system(size: 16)).frame(width: 20)
                        Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular))
                        Spacer()
                        if page == .clean && !model.selected.isEmpty {
                            Text("\(model.selected.count)").font(.system(size: 10, weight: .semibold)).padding(4).background(.white, in: Capsule())
                        }
                    }.padding(.horizontal, 15).padding(.vertical, 13)
                        .foregroundStyle(model.page == page ? Theme.accent : Theme.muted)
                        .background(model.page == page ? Theme.pale : .clear, in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).padding(.horizontal, 14).padding(.bottom, 5)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("本机处理，安心整理", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
                Text("扫描结果留在这台 Mac\n每一次清理，由你决定")
                    .font(.system(size: 11)).lineSpacing(5).foregroundStyle(Theme.muted)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding(16)
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                Text("Apple Silicon · 原生应用")
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 207).background(Theme.sidebar)
    }

    private var header: some View {
        HStack {
            Text("工作空间").foregroundStyle(Theme.muted)
            Text("/").foregroundStyle(Theme.line)
            Text("此 Mac").fontWeight(.medium)
            Spacer()
            Circle().fill(Theme.accent).frame(width: 5, height: 5)
            Text("离线运行").foregroundStyle(Theme.muted)
            Button { model.openSettings() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).help("扫描设置").disabled(model.busy).padding(.leading, 12)
            Button { model.exportReport() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(.plain).help("导出本地扫描报告").disabled(model.report == nil || model.busy).padding(.leading, 12)
        }.font(.system(size: 11)).padding(.horizontal, 34).padding(.top, 35).padding(.bottom, 23)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("给 Mac，一点呼吸的空间。").font(.system(size: 29, weight: .semibold))
                        Text("看清每一份占用，再决定如何整理。").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    scanButton
                }
                storageCard
                HStack(alignment: .firstTextBaseline) {
                    Text("从这里开始整理").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(model.report == nil ? "扫描后显示实际占用" : "按占用大小排序 · 默认不勾选")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 12) {
                    ForEach([ScanCategory.cache, .developer, .logs, .installers], id: \.self) { category in categoryCard(category) }
                }
                HStack(spacing: 16) {
                    Image(systemName: "leaf").font(.system(size: 23)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("重要的东西，好好留下。").font(.system(size: 13, weight: .semibold))
                        Text("模型、容器、备份和 IDE 本地历史仅展示占用。照片库与系统文件不进入清理范围。")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(4)
                    }
                    Spacer()
                    Button("查看重要数据") { model.page = .protected }.buttonStyle(QuietButton())
                }.padding(20).background(Theme.pale.opacity(0.48), in: RoundedRectangle(cornerRadius: 15))
            }.padding(.horizontal, 34).padding(.bottom, 26)
        }
    }

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("磁盘空间", systemImage: "internaldrive").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Macintosh HD").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Theme.background, in: Capsule())
            }
            HStack(spacing: 33) {
                ZStack {
                    Circle().stroke(Theme.pale, lineWidth: 17)
                    Circle().trim(from: 0, to: model.usedFraction).stroke(Theme.accent, style: StrokeStyle(lineWidth: 17, lineCap: .round)).rotationEffect(.degrees(-90))
                    VStack(spacing: 7) {
                        Text("可用空间").font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Text(displayBytes(model.available)).font(.system(size: 28, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                        Text("共 \(displayBytes(model.total))").font(.system(size: 10)).foregroundStyle(Theme.muted)
                    }.padding(20)
                }.frame(width: 163, height: 163).padding(8)
                VStack(alignment: .leading, spacing: 15) {
                    HStack(spacing: 18) {
                        legend("已用", value: displayBytes(max(0, model.total - model.available)), color: Theme.accent)
                        legend("可用", value: displayBytes(model.available), color: Theme.pale)
                    }
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("待你确认的清理项目").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            Text(model.report == nil ? "等待扫描" : displayBytes(model.cleanableBytes))
                                .font(.system(size: 31, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        if model.report != nil {
                            Button { model.page = .clean; model.filter = nil } label: {
                                HStack(spacing: 6) { Text("查看 \(model.cleanable.count) 项"); Image(systemName: "arrow.right") }
                            }.buttonStyle(QuietButton())
                        }
                    }
                    Text("按实际分配空间估算；移入废纸篓后仍占空间。")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity)
            }
        }.padding(24).panel()
    }

    private func legend(_ label: String, value: String, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(Theme.muted)
            Text(value).fontWeight(.medium)
        }.font(.system(size: 11))
    }

    private func categoryCard(_ category: ScanCategory) -> some View {
        let bytes = model.cleanable.filter { $0.category == category }.reduce(Int64(0)) { $0 + $1.bytes }
        return Button { model.page = .clean; model.filter = category } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack { Image(systemName: category.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(Theme.muted) }
                Text(category.title).font(.system(size: 12, weight: .medium))
                Text(model.report == nil ? "—" : displayBytes(bytes)).font(.system(size: 21, weight: .semibold, design: .rounded))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(17).panel()
        }.buttonStyle(.plain)
    }

    private var scanButton: some View {
        Group {
            if model.busy {
                Button(model.cancelling ? "正在停止…" : "停止") { model.cancel() }.buttonStyle(QuietButton()).disabled(model.cancelling)
            } else {
                Button { model.scan() } label: { Label(model.report == nil ? "开始扫描" : "重新扫描", systemImage: "arrow.clockwise") }.buttonStyle(PrimaryButton())
            }
        }
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.page.rawValue).font(.system(size: 28, weight: .semibold))
                    Text(listSubtitle).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.page == .large {
                    Button("选择文件夹") { model.openFolderPicker() }.buttonStyle(QuietButton()).disabled(model.busy)
                }
                scanButton
            }
            if model.page == .clean {
                HStack(spacing: 7) {
                    filterButton(nil)
                    ForEach([ScanCategory.cache, .developer, .logs, .installers], id: \.self) { filterButton($0) }
                    Spacer()
                }
            }
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("搜索名称或路径", text: $model.search).textFieldStyle(.plain)
                }.font(.system(size: 12)).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 9)).frame(maxWidth: 300)
                Spacer()
                Text("\(model.visibleItems.count) 项").font(.system(size: 11)).foregroundStyle(Theme.muted)
                if model.page == .clean {
                    Button("勾选较旧项目") { model.selectOlder() }.buttonStyle(QuietButton()).disabled(model.busy || model.report == nil)
                        .help("勾选至少 7 天未更新且相关应用未运行的可清理项；请逐项复核")
                    Button("取消勾选") { model.selected.removeAll() }.buttonStyle(.plain).font(.system(size: 11)).disabled(model.busy)
                }
            }
            if model.visibleItems.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: model.report == nil ? "sparkle.magnifyingglass" : "checkmark.circle").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
                    Text(model.report == nil ? "先扫描，再开始整理" : "当前范围没有匹配项目").font(.system(size: 16, weight: .medium))
                    Text(model.report == nil ? "扫描只读取文件属性，不会删除内容。" : "可重新扫描，或调整搜索条件。")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleItems) { item in
                            itemRow(item)
                            Divider().overlay(Theme.line.opacity(0.3)).padding(.leading, 52)
                        }
                    }.padding(.vertical, 4)
                }.panel()
            }
        }.padding(.horizontal, 34).padding(.bottom, 20)
    }

    private var listSubtitle: String {
        switch model.page {
        case .large: return "展示最大的 200 个本地文件（≥ 200 MB）；默认扫描下载、桌面、文稿和影片。"
        case .protected: return "这些内容可能承载重要资产，只统计占用，交由对应应用管理。"
        default: return "缓存会重新生成；先退出相关应用和构建任务，再勾选需要整理的项目。"
        }
    }

    private func filterButton(_ category: ScanCategory?) -> some View {
        Button { model.filter = category } label: {
            Text(category?.title ?? "全部").font(.system(size: 11, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(model.filter == category ? .white : Theme.muted)
                .background(model.filter == category ? Theme.accent : Theme.line.opacity(0.35), in: Capsule())
        }.buttonStyle(.plain)
    }

    private func itemRow(_ item: ScanItem) -> some View {
        HStack(spacing: 13) {
            if model.page == .clean {
                Button { model.toggle(item) } label: {
                    Image(systemName: !item.eligible ? "lock" : model.selected.contains(item.id) ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17)).foregroundStyle(item.eligible ? Theme.accent : Theme.muted.opacity(0.5))
                }.buttonStyle(.plain).disabled(!item.eligible || model.busy).frame(width: 21)
                    .accessibilityLabel("选择 \(item.title)").accessibilityValue(model.selected.contains(item.id) ? "已选择" : "未选择")
            } else {
                Image(systemName: item.category.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 23)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(shortPath(item.path)).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle).help(item.path)
                Text(item.note).font(.system(size: 10)).foregroundStyle(item.eligible ? Theme.muted : Theme.amber).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 5) {
                Text((item.measurement.complete ? "" : "≥ ") + displayBytes(item.bytes)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(item.measurement.files.formatted() + " 个文件").font(.system(size: 9)).foregroundStyle(Theme.muted)
            }.frame(minWidth: 88)
            Button { model.reveal(item.url) } label: { Image(systemName: "folder").font(.system(size: 14)) }
                .buttonStyle(.plain).foregroundStyle(Theme.muted).help("在 Finder 中显示").padding(.leading, 9)
        }.padding(.horizontal, 17).padding(.vertical, 15)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let report = model.report, !report.issues.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                    Text(report.issueSummary).lineLimit(1).help(report.issueSummary)
                    Spacer()
                    Button("查看详情") { model.showIssues = true }.buttonStyle(.plain).underline()
                }.font(.system(size: 10)).foregroundStyle(Theme.amber).padding(.horizontal, 34).padding(.vertical, 9).background(Color.orange.opacity(0.07))
            }
            HStack(spacing: 12) {
                if model.busy { ProgressView().controlSize(.small).scaleEffect(0.8) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.status).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                    Text(model.selected.isEmpty ? "不自动删除 · 不上传文件 · 不清空废纸篓" : "已勾选 \(model.selected.count) 项 · \(displayBytes(model.selectedBytes))")
                        .font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer()
                if model.page == .clean {
                    Button { model.prepareCleanup() } label: { Label("复核并清理", systemImage: "trash") }
                        .buttonStyle(PrimaryButton()).disabled(model.selected.isEmpty || model.busy).opacity(model.selected.isEmpty || model.busy ? 0.45 : 1)
                } else {
                    Button { model.openTrash() } label: { Label("打开废纸篓", systemImage: "trash") }.buttonStyle(QuietButton())
                }
            }.padding(.horizontal, 34).padding(.vertical, 17).background(.white.opacity(0.7))
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("每一步，都有记录。").font(.system(size: 28, weight: .semibold))
            Text("清理内容可在 Finder 的废纸篓中检查或还原。清空废纸篓后才释放空间。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
            if model.history.isEmpty {
                VStack(spacing: 13) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accent)
                    Text("还没有清理记录").font(.system(size: 16, weight: .medium))
                    Text("扫描不会移动或删除任何文件。").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: entry.success ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(entry.success ? Theme.accent : Theme.amber)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(URL(fileURLWithPath: entry.source).lastPathComponent).font(.system(size: 12, weight: .semibold))
                                    Text(shortPath(entry.source)).font(.system(size: 10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                                    Text(entry.message).font(.system(size: 11)).foregroundStyle(entry.success ? Theme.muted : Theme.amber)
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if entry.success { Text(displayBytes(entry.bytes)).font(.system(size: 12, weight: .medium)) }
                                if let destination = entry.destination {
                                    Button("查看") { model.reveal(URL(fileURLWithPath: destination)) }.buttonStyle(QuietButton())
                                }
                            }.padding(18)
                            Divider()
                        }
                    }
                }.panel()
            }
        }.padding(.horizontal, 34).padding(.bottom, 22)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 19) {
            Label("确认这次整理", systemImage: "trash").font(.system(size: 23, weight: .semibold))
            Text("将 \(model.selected.count) 项（约 \(displayBytes(model.selectedBytes))）移入废纸篓。")
                .font(.system(size: 14, weight: .medium))
            Text("缓存可能需要重新下载或重建。应用会先复核文件；仍在使用、内容变化或无权限的项目会跳过。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.selectedItems) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(item.title).fontWeight(.medium); Spacer(); Text(displayBytes(item.bytes)) }.font(.system(size: 12))
                            Text(shortPath(item.path)).font(.system(size: 10)).foregroundStyle(Theme.muted).textSelection(.enabled)
                        }
                    }
                }.padding(16)
            }.frame(height: 220).background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
            Toggle("我已检查所选项目，并退出相关应用和构建任务", isOn: $model.acknowledged).font(.system(size: 12))
            Text("移入废纸篓不会立即释放磁盘空间。请确认不再需要后，在 Finder 中清空废纸篓。")
                .font(.system(size: 11)).foregroundStyle(Theme.amber).lineSpacing(4)
            HStack {
                Spacer()
                Button("返回检查") { model.showConfirmation = false }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("移入废纸篓") { model.performCleanup() }.buttonStyle(PrimaryButton()).disabled(!model.acknowledged).opacity(model.acknowledged ? 1 : 0.45)
            }
        }.padding(30).frame(width: 570).background(.white).foregroundStyle(Theme.ink)
    }

    private var issueSheet: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("扫描情况").font(.system(size: 22, weight: .semibold))
            Text("以下情况仅影响对应项目，其他完整扫描的项目仍可复核清理。文件变化和扫描上限与完全磁盘访问权限无关，请按每项原因处理。当前单目录上限：\(model.directoryLimit.formatted()) 项。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
            if model.report?.hasPermissionIssues == true {
                Text("部分路径确实被拒绝访问。若尚未授权，可在系统设置中为清风开启完全磁盘访问权限；若已经授权，请核对运行的应用位置及文件自身的访问限制。")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber).lineSpacing(4)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(model.report?.issues ?? []) { issue in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(issue.category.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.amber)
                            Text(shortPath(issue.path)).font(.system(size: 11, weight: .medium)).textSelection(.enabled)
                            Text(issue.message).font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 270)
            HStack {
                if model.report?.hasPermissionIssues == true {
                    Button("打开系统权限设置") { model.openPermissions() }.buttonStyle(QuietButton())
                }
                Spacer()
                Button("完成") { model.showIssues = false }.buttonStyle(PrimaryButton()).keyboardShortcut(.cancelAction)
            }
        }.padding(30).frame(width: 590).background(.white)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 19) {
            Label("扫描设置", systemImage: "gearshape").font(.system(size: 23, weight: .semibold))
            Text("你可以控制单个目录允许扫描的项目数量。默认是 300,000 项；例如 Google 缓存超过默认值时，可改为 400,000 项后重新扫描。")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(5)
            VStack(alignment: .leading, spacing: 11) {
                Text("单目录扫描上限").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("300000", text: $model.limitText)
                        .textFieldStyle(.roundedBorder).font(.system(size: 15, design: .monospaced))
                        .frame(width: 190).onSubmit { model.applySettings() }
                    Text("项").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Text("可设置范围：\(ScanLimit.minimumDirectory.formatted())–\(ScanLimit.maximumDirectory.formatted()) 项。只接受整数，可输入 400000 或 400,000。")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(17).background(Theme.background, in: RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 8) {
                Text("快速选择").font(.system(size: 11)).foregroundStyle(Theme.muted)
                ForEach([100_000, 300_000, 400_000, 600_000, 1_000_000], id: \.self) { value in
                    Button(value.formatted()) { model.limitText = value.formatted() }.buttonStyle(QuietButton())
                }
            }
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                Text("提高上限可能显著增加扫描时间和内存占用。它只改变扫描数量上限，不会授予完全磁盘访问权限，也不会放宽符号链接、系统目录、模型和容器等安全规则。")
                    .font(.system(size: 11)).foregroundStyle(Theme.amber).lineSpacing(4)
            }.padding(13).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("恢复默认") { model.resetSettingsDraft() }.buttonStyle(QuietButton())
                Spacer()
                Button("取消") { model.showSettings = false }.buttonStyle(QuietButton()).keyboardShortcut(.cancelAction)
                Button("保存并重新扫描") { model.applySettings() }.buttonStyle(PrimaryButton())
            }
        }.padding(30).frame(width: 640).background(.white).foregroundStyle(Theme.ink)
    }

    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return SafetyPolicy.isWithin(path, home) ? "~" + path.dropFirst(home.count) : path
    }
}
