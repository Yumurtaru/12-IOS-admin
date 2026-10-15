import SwiftUI

/// Неразобранные жалобы на объявления (сначала самые старые, как на сервере).
/// Действия: «Закрыть» жалобу; «Заблокировать объявление» прямо отсюда.
struct AdsReportsScreen: View {
    @ObservedObject var model: PagedListModel
    @ObservedObject var stats: ObjectLoader
    let ads: PagedListModel

    @State private var blockTarget: AdsReportBox?
    @State private var blockInfo: String?
    @State private var info: String?

    var body: some View {
        AdminListScreen("Жалобы на объявления", model: model, searchPrompt: nil,
                        emptyText: "Жалоб нет",
                        header: AnyView(AdsStatsHeader(stats: stats)),
                        row: { item in row(item) })
            .sheet(item: $blockTarget, onDismiss: showBlockInfo) { t in blockSheet(t.json) }
            .alert(info ?? "", isPresented: infoShown) {
                Button("OK", role: .cancel) {}
            }
    }

    private var infoShown: Binding<Bool> {
        Binding(get: { info != nil }, set: { if !$0 { info = nil } })
    }

    private func row(_ item: JSON) -> some View {
        AdsReportRow(report: item,
                     onClose: { try await close(item) },
                     onBlock: { blockTarget = AdsReportBox(json: item) })
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    swipeClose(item)
                } label: { Label("Закрыть", systemImage: "checkmark") }
                .tint(Brand.green)
            }
    }

    private func swipeClose(_ item: JSON) {
        Task { @MainActor in
            do {
                try await close(item)
            } catch {
                if !APIError.isCancellation(error) {
                    Haptics.error()
                    info = APIError.describe(error)
                }
            }
        }
    }

    private func close(_ item: JSON) async throws {
        guard let id = item.id else { return }
        try await API.shared.post("/api/admin/ads/reports/\(id)/close")
        Haptics.success()
        model.remove(id: id)
        await stats.load()
        Task { await Notifier.shared.refresh(force: true) }
    }

    private func blockSheet(_ item: JSON) -> some View {
        let adId = item["ad_id"].intValue
        let title = item["ad_title"].stringValue
        let msg = "«" + title + "». " + AdsFormat.blockMessage + " Жалоба останется — закройте её отдельно."
        return ModerationReasonSheet(title: "Заблокировать объявление", message: msg,
                                     reasons: AdsFormat.blockReasons, placeholder: "Причина (увидит автор)",
                                     submitTitle: "Заблокировать", allowEmpty: true) { reason in
            let text = try await AdsFormat.block(id: adId, reason: reason)
            blockInfo = text
            let rid = item.id ?? 0
            model.update(id: rid) { row in
                row = AdsFormat.patched(row, ["ad_status": .string("blocked")])
            }
            await stats.load()
            await ads.refresh()
        }
    }

    private func showBlockInfo() {
        if let t = blockInfo {
            blockInfo = nil
            info = t
        }
    }
}

/// JSON жалобы в обёртке Identifiable — для `.sheet(item:)`.
struct AdsReportBox: Identifiable {
    let json: JSON
    var id: String { json.stableID }
}

/// Строка жалобы на объявление с кнопками.
struct AdsReportRow: View {
    let report: JSON
    let onClose: () async throws -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(report["ad_title"].nonEmptyString ?? "(объявление удалено)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Text(Fmt.date(report["created_at"]))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            Text(adLine)
                .font(.caption)
                .foregroundColor(Brand.muted)
            HStack(spacing: 6) {
                StatusBadge(AdsFormat.reportReason(report["reason"].string), color: Brand.amber)
                Text("от " + (report["user_name"].nonEmptyString ?? "гость"))
                    .font(.caption)
                    .foregroundColor(Brand.muted)
            }
            if let c = report["comment"].nonEmptyString {
                Text(c)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
            buttons
        }
        .padding(.vertical, 2)
    }

    private var adLine: String {
        let st = report["ad_status"].nonEmptyString.map { " · " + AdsFormat.statusLabel($0) } ?? ""
        return "Объявление #" + report["ad_id"].stringValue + st
    }

    private var buttons: some View {
        HStack(spacing: 16) {
            ActionButton("Закрыть жалобу", systemImage: "checkmark", style: .plain) {
                try await onClose()
            }
            if report["ad_status"].string != "blocked" && !report["ad_status"].stringValue.isEmpty {
                Button(role: .destructive, action: onBlock) {
                    Label("Заблокировать", systemImage: "hand.raised")
                }
                .buttonStyle(.borderless)
            }
            Spacer()
        }
        .font(.subheadline)
        .padding(.top, 2)
    }
}
