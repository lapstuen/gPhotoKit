import SwiftUI
import UIKit

struct ObjectLibraryPickerView: View {
    let onSelect: (UIImage) -> Void
    let onDismiss: () -> Void

    @State private var items: [(name: String, url: URL)] = []
    @State private var categories: [String] = []
    @State private var allCategories: [String] = []
    @State private var selectedFilter: LibraryCategoryFilter = .all
    @State private var pendingMoveURL: URL?
    @State private var newCategoryName = ""
    @State private var showNewCategoryAlert = false

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 8)]

    private enum LibraryCategoryFilter: Equatable {
        case all
        case uncategorized
        case category(String)

        var title: String {
            switch self {
            case .all: return "Alle"
            case .uncategorized: return ObjectLibrary.uncategorizedCategory
            case .category(let name): return name
            }
        }

        var libraryCategory: String? {
            switch self {
            case .all:
                return nil
            case .uncategorized:
                return ObjectLibrary.uncategorizedCategory
            case .category(let name):
                return name
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 60))
                            .foregroundStyle(.secondary)
                        Text(emptyTitle)
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text(emptyMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(items, id: \.url) { item in
                                ObjectCell(
                                    name: item.name,
                                    url: item.url,
                                    categories: allCategories,
                                    onTap: {
                                        if item.url.pathExtension.lowercased() == "svg" {
                                            guard let svgText = try? String(contentsOf: item.url, encoding: .utf8) else { return }
                                            SVGRasterizer.render(svgText: svgText) { img in
                                                guard let img else { return }
                                                DispatchQueue.main.async { onSelect(img) }
                                            }
                                        } else if let data = try? Data(contentsOf: item.url),
                                           let img = UIImage(data: data) {
                                            onSelect(img)
                                        }
                                    },
                                    onDelete: {
                                        ObjectLibrary.delete(url: item.url)
                                        refreshItems()
                                    },
                                    onTrim: { completion in
                                        trimItem(item.url, completion: completion)
                                    },
                                    onMove: { category in
                                        ObjectLibrary.move(url: item.url, to: category)
                                        refreshItems()
                                    },
                                    onNewCategoryMove: {
                                        pendingMoveURL = item.url
                                        newCategoryName = ""
                                        showNewCategoryAlert = true
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Objektbibliotek")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Alle") {
                            selectedFilter = .all
                            refreshItems()
                        }
                        Button(ObjectLibrary.uncategorizedCategory) {
                            selectedFilter = .uncategorized
                            refreshItems()
                        }
                        if !categories.isEmpty {
                            Divider()
                        }
                        ForEach(categories, id: \.self) { category in
                            Button(category) {
                                selectedFilter = .category(category)
                                refreshItems()
                            }
                        }
                    } label: {
                        Label(selectedFilter.title, systemImage: "folder")
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Lukk") { onDismiss() }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onAppear { refreshItems() }
        .alert("Ny katalog", isPresented: $showNewCategoryAlert) {
            TextField("Navn", text: $newCategoryName)
            Button("Opprett og flytt") {
                guard let url = pendingMoveURL,
                      !newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                ObjectLibrary.move(url: url, to: newCategoryName)
                refreshItems()
            }
            Button("Avbryt", role: .cancel) {}
        }
    }

    private var emptyTitle: String {
        switch selectedFilter {
        case .all:
            return "Ingen objekter lagret"
        default:
            return "Ingen objekter i \(selectedFilter.title)"
        }
    }

    private var emptyMessage: String {
        switch selectedFilter {
        case .all:
            return "Lagre PNG-bilder til biblioteket fra hovedvisningen."
        default:
            return "Denne katalogen er tom."
        }
    }

    private func refreshItems() {
        let all = ObjectLibrary.categories()
        allCategories = all
        categories = all.filter { $0 != ObjectLibrary.uncategorizedCategory }
        items = ObjectLibrary.all(in: selectedFilter.libraryCategory)
    }

    /// Beskjærer et objekt direkte i biblioteket (fjerner tomrom/gjennomsiktig
    /// kant rundt motivet) og lagrer resultatet tilbake på samme fil, slik at
    /// objektet ligger ferdig trimmet neste gang det settes inn i et bilde.
    private func trimItem(_ url: URL, completion: @escaping (UIImage) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let data = try? Data(contentsOf: url), let img = UIImage(data: data),
                  let trimmed = ObjectLibrary.trimToContent(img) else { return }
            ObjectLibrary.overwrite(url: url, with: trimmed)
            DispatchQueue.main.async { completion(trimmed) }
        }
    }
}

private struct ObjectCell: View {
    let name: String
    let url: URL
    let categories: [String]
    let onTap: () -> Void
    let onDelete: () -> Void
    let onTrim: (@escaping (UIImage) -> Void) -> Void
    let onMove: (String?) -> Void
    let onNewCategoryMove: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    CheckerboardView()
                    if let img = thumbnail {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.4)))

                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
        }
        .contextMenu {
            Button {
                onTrim { trimmed in thumbnail = trimmed }
            } label: {
                Label("Beskjær", systemImage: "crop")
            }
            Menu {
                ForEach(categories, id: \.self) { category in
                    Button(category) {
                        onMove(category == ObjectLibrary.uncategorizedCategory ? nil : category)
                    }
                }
                Divider()
                Button("Ny katalog...") { onNewCategoryMove() }
            } label: {
                Label("Flytt til katalog", systemImage: "folder")
            }
            Button(role: .destructive) { onDelete() } label: {
                Label("Slett", systemImage: "trash")
            }
        }
        .onAppear {
            if url.pathExtension.lowercased() == "svg" {
                // WKWebView (i SVGRasterizer) må opprettes på hovedtråden.
                guard let svgText = try? String(contentsOf: url, encoding: .utf8) else { return }
                SVGRasterizer.render(svgText: svgText) { img in
                    guard let img else { return }
                    self.thumbnail = img
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = try? Data(contentsOf: url),
                      let img = UIImage(data: data) else { return }
                DispatchQueue.main.async { self.thumbnail = img }
            }
        }
    }
}

private struct CheckerboardView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(patternImage: checkerImage())
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    private func checkerImage() -> UIImage {
        let size: CGFloat = 8
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size * 2, height: size * 2))
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size * 2, height: size * 2))
            UIColor(white: 0.78, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
            ctx.fill(CGRect(x: size, y: size, width: size, height: size))
        }
    }
}
