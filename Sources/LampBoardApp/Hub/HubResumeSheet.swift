import LampBoardCore
import SwiftUI

/// «Resume a past conversation…»: the project's past conversations, and the ones
/// a process holds now, which open where they run (D163).
///
/// The list is as tall as its rows, up to `ResumeList.shownRows`, and scrolls in
/// that height past them: the sheet grows and shrinks with it. Left to itself it
/// had no height a sheet could take, and showed half of its first row (14 October
/// 2026). `↑` `↓` move the selection, `⏎` takes it up, `Esc` cancels; a click on
/// a row takes that one up.
struct HubResumeSheet: View {
    let entry: ProjectList.Entry
    let load: () async -> [PastConversations.Item]
    /// The row's name of a conversation running now, when there is a row.
    let name: (String) -> String?
    let pick: (PastConversations.Item) -> Void
    let cancel: () -> Void
    @State private var items: [PastConversations.Item]?
    @State private var selected: Int?
    @State private var hovered: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Resume in \(entry.name)\(entry.host.map { " on \($0)" } ?? "")").font(.system(size: 15, weight: .bold))
            Text("A past conversation goes on in tmux, in its own terminal in the Hub. One running now opens where it runs: taking it up a second time would fork it.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let items, items.isEmpty {
                Text("No conversation to take up here.").foregroundStyle(.secondary)
            } else if let items {
                list(items, rows: ResumeList.rows(items, project: entry.name, host: entry.host, name: name, now: Date()))
            } else {
                ProgressView().controlSize(.small)
            }
            buttons
        }
        .padding(18)
        .frame(width: 520)
        // The height the content asks for, so the sheet follows the list.
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let loaded = await load()
            items = loaded
            selected = ResumeList.firstSelection(count: loaded.count)
        }
    }

    private func list(_ items: [PastConversations.Item], rows: [ResumeList.Row]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        Button { pick(items[index]) } label: { label(row, selected: index == selected) }
                            .buttonStyle(.plain)
                            .onHover { inside in
                                if inside { hovered = row.id } else if hovered == row.id { hovered = nil }
                            }
                            .help(row.title)
                            .id(row.id)
                            .accessibilityIdentifier("hub.resume.\(row.id)")
                            .accessibilityLabel("\(row.title), \(row.detail), \(row.age)")
                            .accessibilityAddTraits(index == selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, ResumeList.inset)
            }
            .scrollDisabled(!ResumeList.scrolls(rows: rows.count))
            .frame(height: ResumeList.height(rows: rows.count))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .onChange(of: selected) { _, now in
                // The row chosen with the keyboard is kept in sight.
                guard let now, rows.indices.contains(now) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(rows[now].id) }
            }
        }
    }

    /// Two lines whole — the title, then the project and the id's start — and the
    /// age at the end. Selected, it is tinted and outlined; under the pointer, shaded.
    private func label(_ row: ResumeList.Row, selected: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                    .lineLimit(1).truncationMode(.tail)
                Text(row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(row.age).font(.system(size: 11, weight: row.isLive ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(row.isLive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: ResumeList.rowHeight - 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovered == row.id ? 0.07 : 0)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(selected ? 0.6 : 0)))
        .padding(.vertical, 1)
        .padding(.horizontal, ResumeList.inset)
        .contentShape(Rectangle())
    }

    private var buttons: some View {
        let chosen = selected.flatMap { index in items.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
        return HStack {
            if let items, !items.isEmpty {
                Text("↑ ↓ to choose · ⏎ to take it up").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
            arrows
            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
            Button(chosen?.isLive == true ? "Open" : "Resume") { if let chosen { pick(chosen) } }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
                .accessibilityIdentifier("hub.resume.go")
        }
    }

    /// `↑` and `↓` as shortcuts of two buttons nobody sees: they reach the sheet
    /// whatever holds the focus, as `⏎` and `Esc` do, with nothing to focus first.
    private var arrows: some View {
        ZStack {
            Button("") { step(-1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { step(1) }.keyboardShortcut(.downArrow, modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .focusable(false)
        .accessibilityHidden(true)
    }

    private func step(_ by: Int) {
        selected = ResumeList.move(selected, by: by, count: items?.count ?? 0)
    }
}
