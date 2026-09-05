import UIKit
import SwiftUI

struct SnippetCharacterGridView: View {
    let sourceText: String
    let characters: [String]
    let onSelect: (String) -> Void
    @State private var previewText: String
    @State private var insertionRange: NSRange

    init(sourceText: String, initialInsertionRange: NSRange, characters: [String], onSelect: @escaping (String) -> Void) {
        self.sourceText = sourceText
        self.characters = characters
        self.onSelect = onSelect
        _previewText = State(initialValue: sourceText)
        _insertionRange = State(initialValue: initialInsertionRange)
    }

    private let columns = [
        GridItem(.adaptive(minimum: 54, maximum: 84), spacing: 10, alignment: .center)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Velg tegn")
                .font(.title2.weight(.semibold))

            Text(previewText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Button("Sett inn alle") {
                insertAllCharacters()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                    ForEach(Array(characters.enumerated()), id: \.offset) { _, character in
                        Button {
                            previewText = Self.insert(character, into: previewText, range: insertionRange)
                            insertionRange.location += character.utf16.count
                            insertionRange.length = 0
                            onSelect(character)
                        } label: {
                            Text(character)
                                .font(.system(size: 28))
                                .frame(minWidth: 54, minHeight: 54)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.blue.opacity(0.14))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.blue.opacity(0.35), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 360)
        .background(Color(uiColor: .systemBackground))
    }

    private func insertAllCharacters() {
        let text = characters.joined()
        guard !text.isEmpty else { return }
        previewText = Self.insert(text, into: previewText, range: insertionRange)
        insertionRange.location += text.utf16.count
        insertionRange.length = 0
        onSelect(text)
    }

    private static func insert(_ text: String, into source: String, range: NSRange) -> String {
        let mutable = NSMutableString(string: source)
        mutable.replaceCharacters(in: range, with: text)
        return mutable as String
    }
}
