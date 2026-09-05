import UIKit
import SwiftUI

// MARK: - Data model

struct TextSnippetGroup: Codable {
    var id: String
    var name: String
    var texts: [String]

    init(name: String, texts: [String] = []) {
        self.id   = UUID().uuidString
        self.name = name
        self.texts = texts
    }
}

// MARK: - Store

final class TextSnippetStore {
    static let shared = TextSnippetStore()
    private init() { load() }

    var groups: [TextSnippetGroup] = []

    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gPhotoTextSnippets.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([TextSnippetGroup].self, from: data)
        else { loadDefaults(); return }
        groups = decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        try? data.write(to: fileURL)
    }

    private func loadDefaults() {
        groups = [
            TextSnippetGroup(name: "Emoji", texts: [
                "😀 😂 😍 🥰 😎 🤩",
                "👍 👏 🙏 ❤️ 🔥 💯",
                "🎉 🎂 🎊 🥳 🎁 🎈",
                "😢 😭 😤 🤔 🤯 😅",
                "✅ ❌ ⚠️ 💡 📌 🔑"
            ]),
            TextSnippetGroup(name: "Facebook", texts: [
                "Gratulerer med dagen! 🎂🎉",
                "Godt nytt år! 🎆🥂",
                "Lykke til! 🤞",
                "Takk for deling! 👏",
                "God helg! 😊",
                "Tenker på deg! ❤️",
                "Flott bilde! 📸",
                "Nydelig! 😍"
            ]),
            TextSnippetGroup(name: "Thai", texts: [
                "ก ข ค ง จ ช ซ ฌ ญ",
                "ฎ ฏ ฐ ฑ ฒ ณ ด ต ถ ท ธ น",
                "บ ป ผ ฝ พ ฟ ภ ม ย ร ล ว",
                "ศ ษ ส ห ฬ อ ฮ",
                "สวัสดีครับ",
                "สวัสดีค่ะ",
                "ขอบคุณครับ",
                "ขอบคุณค่ะ"
            ])
        ]
        save()
    }
}

// MARK: - Picker (popover)

final class TextSnippetPickerVC: UIViewController,
                                  UITableViewDataSource, UITableViewDelegate,
                                  UIPopoverPresentationControllerDelegate {

    var onSelect: ((String) -> Void)?
    private let initialPreviewText: String
    private let initialInsertionRange: NSRange

    private let store = TextSnippetStore.shared
    private var selectedGroup = 0
    private let groupScroll = UIScrollView()
    private var groupStack  = UIStackView()
    private let tableView   = UITableView(frame: .zero, style: .plain)
    private var characterPickerWindow: UIWindow?

    init(initialPreviewText: String = "", initialInsertionRange: NSRange = .init(location: 0, length: 0)) {
        self.initialPreviewText = initialPreviewText
        self.initialInsertionRange = initialInsertionRange
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .popover
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        #if targetEnvironment(macCatalyst)
        preferredContentSize = CGSize(width: 960, height: 1140)
        #else
        preferredContentSize = CGSize(width: 320, height: 380)
        #endif
        buildLayout()
    }

    private func buildLayout() {
        // Group strip
        groupScroll.showsHorizontalScrollIndicator = false
        groupScroll.alwaysBounceHorizontal = true
        groupScroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(groupScroll)

        buildGroupStack()

        // Manage button
        let manageBtn = UIButton(type: .system)
        manageBtn.setImage(UIImage(systemName: "slider.horizontal.3"), for: .normal)
        manageBtn.addTarget(self, action: #selector(manageTapped), for: .touchUpInside)
        manageBtn.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(manageBtn)

        // Separator
        let sep = UIView()
        sep.backgroundColor = UIColor.separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sep)

        // Table
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "t")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 54
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            groupScroll.topAnchor.constraint(equalTo: view.topAnchor),
            groupScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            groupScroll.heightAnchor.constraint(equalToConstant: 44),
            groupScroll.trailingAnchor.constraint(equalTo: manageBtn.leadingAnchor, constant: -4),

            manageBtn.centerYAnchor.constraint(equalTo: groupScroll.centerYAnchor),
            manageBtn.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            manageBtn.widthAnchor.constraint(equalToConstant: 36),

            sep.topAnchor.constraint(equalTo: groupScroll.bottomAnchor),
            sep.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sep.heightAnchor.constraint(equalToConstant: 0.5),

            tableView.topAnchor.constraint(equalTo: sep.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildGroupStack() {
        groupStack.removeFromSuperview()
        groupStack = UIStackView()
        groupStack.axis    = .horizontal
        groupStack.spacing = 8
        groupStack.translatesAutoresizingMaskIntoConstraints = false
        groupScroll.addSubview(groupStack)

        NSLayoutConstraint.activate([
            groupStack.leadingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.leadingAnchor, constant: 10),
            groupStack.trailingAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.trailingAnchor, constant: -10),
            groupStack.topAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.topAnchor),
            groupStack.bottomAnchor.constraint(equalTo: groupScroll.contentLayoutGuide.bottomAnchor),
            groupStack.heightAnchor.constraint(equalTo: groupScroll.frameLayoutGuide.heightAnchor),
        ])

        for (i, group) in store.groups.enumerated() {
            var cfg = UIButton.Configuration.filled()
            cfg.title              = group.name
            cfg.baseForegroundColor = i == selectedGroup ? .black : .label
            cfg.baseBackgroundColor = i == selectedGroup ? .systemYellow : .systemFill
            cfg.cornerStyle        = .capsule
            cfg.contentInsets      = NSDirectionalEdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14)
            let btn = UIButton(configuration: cfg)
            btn.tag = i
            btn.addTarget(self, action: #selector(groupTapped(_:)), for: .touchUpInside)
            groupStack.addArrangedSubview(btn)
        }
    }

    @objc private func groupTapped(_ sender: UIButton) {
        selectedGroup = sender.tag
        buildGroupStack()
        tableView.reloadData()
    }

    @objc private func manageTapped() {
        let vc  = TextSnippetManagerVC()
        vc.onDismiss = { [weak self] in
            guard let self else { return }
            self.selectedGroup = min(self.selectedGroup, max(0, self.store.groups.count - 1))
            self.buildGroupStack()
            self.tableView.reloadData()
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard !store.groups.isEmpty else { return 0 }
        return store.groups[selectedGroup].texts.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "t", for: indexPath)
        var cfg = cell.defaultContentConfiguration()
        cfg.text = store.groups[selectedGroup].texts[indexPath.row]
        cfg.textProperties.numberOfLines = 2
        cell.contentConfiguration = cfg
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < store.groups[selectedGroup].texts.count else { return }
        let snippet = store.groups[selectedGroup].texts[indexPath.row]
        DispatchQueue.main.async { [weak self] in
            self?.presentCharacterPicker(for: snippet)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }

    private func presentCharacterPicker(for snippet: String) {
        let characters = snippet
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var hostController: UIHostingController<SnippetCharacterGridView>?
        let content = SnippetCharacterGridView(
            sourceText: initialPreviewText,
            initialInsertionRange: initialInsertionRange,
            characters: characters
        ) { [weak self] character in
            self?.onSelect?(character)
        }
        hostController = UIHostingController(rootView: content)
        hostController?.view.backgroundColor = UIColor.systemBackground
        hostController?.preferredContentSize = CGSize(width: 720, height: 420)

        #if targetEnvironment(macCatalyst)
        guard let scene = view.window?.windowScene ?? UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            if let hostController {
                present(hostController, animated: true)
            }
            return
        }
        let size = hostController?.preferredContentSize ?? CGSize(width: 720, height: 420)
        let window = UIWindow(windowScene: scene)
        if let hostWindow = view.window {
            window.frame = CGRect(x: hostWindow.frame.midX - size.width / 2,
                                  y: hostWindow.frame.midY - size.height / 2,
                                  width: size.width,
                                  height: size.height)
        } else {
            window.frame = CGRect(x: 100, y: 100, width: size.width, height: size.height)
        }
        window.windowLevel = .alert + 1
        window.isOpaque = true
        window.backgroundColor = UIColor.systemBackground
        if let hostController {
            window.rootViewController = hostController
        }
        characterPickerWindow = window
        window.makeKeyAndVisible()
        #else
        if let hostController {
            present(hostController, animated: true)
        }
        #endif
    }
}

// MARK: - Manager

final class TextSnippetManagerVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    var onDismiss: (() -> Void)?
    private let store     = TextSnippetStore.shared
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tekstbibliotek"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add,
                                                            target: self, action: #selector(addGroupTapped))
        navigationItem.leftBarButtonItem  = UIBarButtonItem(barButtonSystemItem: .close,
                                                            target: self, action: #selector(closeTapped))
        tableView.dataSource = self
        tableView.delegate   = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "m")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [weak self] in self?.onDismiss?() }
    }

    @objc private func addGroupTapped() {
        let alert = UIAlertController(title: "Ny gruppe", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Gruppenavn" }
        alert.addAction(UIAlertAction(title: "Legg til", style: .default) { [weak self] _ in
            guard let self,
                  let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            self.store.groups.append(TextSnippetGroup(name: name))
            self.store.save()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: Sections = groups

    func numberOfSections(in tableView: UITableView) -> Int { store.groups.count }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        let label  = UILabel()
        label.text      = store.groups[section].name
        label.font      = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false

        let editBtn = iconBtn("pencil", color: .systemBlue, tag: section, action: #selector(renameTapped(_:)))
        let delBtn  = iconBtn("trash",  color: .systemRed,  tag: section, action: #selector(deleteGroupTapped(_:)))

        [label, editBtn, delBtn].forEach { header.addSubview($0) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 16),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            delBtn.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -8),
            delBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            delBtn.widthAnchor.constraint(equalToConstant: 36),
            editBtn.trailingAnchor.constraint(equalTo: delBtn.leadingAnchor),
            editBtn.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            editBtn.widthAnchor.constraint(equalToConstant: 36),
        ])
        return header
    }

    private func iconBtn(_ symbol: String, color: UIColor, tag: Int, action: Selector) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setImage(UIImage(systemName: symbol), for: .normal)
        btn.tintColor = color
        btn.tag = tag
        btn.addTarget(self, action: action, for: .touchUpInside)
        btn.translatesAutoresizingMaskIntoConstraints = false
        return btn
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { 36 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        store.groups[section].texts.count + 1   // +1 = "Legg til tekst"-rad
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell  = tableView.dequeueReusableCell(withIdentifier: "m", for: indexPath)
        let group = store.groups[indexPath.section]
        var cfg   = cell.defaultContentConfiguration()
        if indexPath.row < group.texts.count {
            cfg.text = group.texts[indexPath.row]
            cell.selectionStyle = .none
        } else {
            cfg.text = "Legg til tekst..."
            cfg.textProperties.color = .systemBlue
            cfg.image = UIImage(systemName: "plus.circle.fill")
            cfg.imageProperties.tintColor = .systemBlue
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = cfg
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let group = store.groups[indexPath.section]
        if indexPath.row == group.texts.count {
            addText(to: indexPath.section)
        } else {
            editText(in: indexPath.section, row: indexPath.row)
        }
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.row < store.groups[indexPath.section].texts.count
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        store.groups[indexPath.section].texts.remove(at: indexPath.row)
        store.save()
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // MARK: Actions

    @objc private func renameTapped(_ sender: UIButton) {
        let section = sender.tag
        let alert   = UIAlertController(title: "Endre navn", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] tf in tf.text = self?.store.groups[section].name }
        alert.addAction(UIAlertAction(title: "Lagre", style: .default) { [weak self] _ in
            guard let self,
                  let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            self.store.groups[section].name = name
            self.store.save()
            self.tableView.reloadSections(IndexSet(integer: section), with: .none)
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func deleteGroupTapped(_ sender: UIButton) {
        let section = sender.tag
        let name    = store.groups[section].name
        let alert   = UIAlertController(title: "Slett \"\(name)\"?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Slett", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.store.groups.remove(at: section)
            self.store.save()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    private func addText(to section: Int) {
        presentTextEditor(title: "Legg til tekst", initialText: "") { [weak self] text in
            guard let self else { return }
            self.store.groups[section].texts.append(text)
            self.store.save()
            let row = IndexPath(row: self.store.groups[section].texts.count - 1, section: section)
            self.tableView.insertRows(at: [row], with: .automatic)
        }
    }

    private func editText(in section: Int, row: Int) {
        guard section < store.groups.count, row < store.groups[section].texts.count else { return }
        let current = store.groups[section].texts[row]
        presentTextEditor(title: "Endre tekst", initialText: current) { [weak self] updated in
            guard let self else { return }
            self.store.groups[section].texts[row] = updated
            self.store.save()
            self.tableView.reloadRows(at: [IndexPath(row: row, section: section)], with: .automatic)
        }
    }

    private func presentTextEditor(title: String, initialText: String, onSave: @escaping (String) -> Void) {
        let vc = TextSnippetEditorVC(titleText: title, initialText: initialText, onSave: onSave)
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }
}

final class TextSnippetEditorVC: UIViewController {

    private let titleText: String
    private let initialText: String
    private let onSave: (String) -> Void
    private let textView = UITextView()

    init(titleText: String, initialText: String, onSave: @escaping (String) -> Void) {
        self.titleText = titleText
        self.initialText = initialText
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = titleText
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 17)
        textView.text = initialText
        textView.layer.cornerRadius = 12
        textView.backgroundColor = .secondarySystemBackground
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        #if targetEnvironment(macCatalyst)
        preferredContentSize = CGSize(width: 700, height: 420)
        #else
        preferredContentSize = CGSize(width: 540, height: 360)
        #endif
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func saveTapped() {
        let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSave(text)
        dismiss(animated: true)
    }
}
