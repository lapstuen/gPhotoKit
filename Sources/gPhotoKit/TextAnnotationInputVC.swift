import UIKit

class TextAnnotationInputVC: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let fonts: [(display: String, name: String)]
    private let onConfirm: (String, String, CGFloat, UIColor?) -> Void
    private let onDelete: (() -> Void)?
    var onClose: (() -> Void)?

    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let snippetBtn = UIButton(type: .system)
    private let advancedStack = UIStackView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let slider = UISlider()
    private let sizeLabel = UILabel()
    private let backgroundColorWell = UIColorWell()
    private let removeBackgroundBtn = UIButton(type: .system)
    private var selectedRow = 0
    private var currentSize: CGFloat

    init(fonts: [(display: String, name: String)],
         initialText: String,
         initialFontName: String,
         initialFontSize: CGFloat,
         initialBackgroundColor: UIColor? = nil,
         onDelete: (() -> Void)? = nil,
         onClose: (() -> Void)? = nil,
         onConfirm: @escaping (String, String, CGFloat, UIColor?) -> Void) {
        self.fonts = fonts
        self.onConfirm = onConfirm
        self.onDelete = onDelete
        self.onClose = onClose
        self.currentSize = initialFontSize
        super.init(nibName: nil, bundle: nil)
        self.selectedRow = fonts.firstIndex(where: { $0.name == initialFontName }) ?? 0
        textView.text = initialText
        self.backgroundColorWell.selectedColor = initialBackgroundColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Midlertidig blå bakgrunn — visuell markør for å bekrefte at denne bygde versjonen kjører.
        view.backgroundColor = .systemBlue
        buildLayout()
        tableView.selectRow(at: IndexPath(row: selectedRow, section: 0), animated: false, scrollPosition: .middle)
        updatePreferredContentSize()
    }

    private func buildLayout() {
        let titleLabel = UILabel()
        titleLabel.text = "Legg til tekst"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 10
        textView.font = .systemFont(ofSize: 16)
        textView.autocapitalizationType = .sentences
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        textView.delegate = self

        placeholderLabel.text = "Skriv tekst her..."
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = .systemFont(ofSize: 16)
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholderLabel)
        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 14),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 11),
        ])
        placeholderLabel.isHidden = !textView.text.isEmpty

        var snipCfg = UIButton.Configuration.filled()
        snipCfg.image = UIImage(systemName: "text.book.closed",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        snipCfg.baseBackgroundColor = .systemIndigo
        snipCfg.baseForegroundColor = .white
        snipCfg.cornerStyle = .medium
        snipCfg.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        snippetBtn.configuration = snipCfg
        snippetBtn.addTarget(self, action: #selector(snippetsTapped), for: .touchUpInside)
        snippetBtn.translatesAutoresizingMaskIntoConstraints = false
        snippetBtn.widthAnchor.constraint(equalToConstant: 40).isActive = true
        snippetBtn.heightAnchor.constraint(equalToConstant: 40).isActive = true

        let inputRow = UIStackView(arrangedSubviews: [textView, snippetBtn])
        inputRow.axis = .horizontal
        inputRow.alignment = .top
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsSelection = true
        tableView.layer.cornerRadius = 10
        tableView.clipsToBounds = true
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.heightAnchor.constraint(equalToConstant: 190).isActive = true

        let fontLabel = UILabel()
        fontLabel.text = "Font"
        fontLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        fontLabel.textColor = .secondaryLabel
        fontLabel.translatesAutoresizingMaskIntoConstraints = false

        let sizeSectionLabel = UILabel()
        sizeSectionLabel.text = "Størrelse"
        sizeSectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        sizeSectionLabel.textColor = .secondaryLabel
        sizeSectionLabel.translatesAutoresizingMaskIntoConstraints = false

        sizeLabel.text = "\(Int(currentSize))"
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        sizeLabel.textAlignment = .right
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let sizeHeaderStack = UIStackView(arrangedSubviews: [sizeSectionLabel, sizeLabel])
        sizeHeaderStack.axis = .horizontal
        sizeHeaderStack.distribution = .fill
        sizeHeaderStack.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = 8
        slider.maximumValue = 1000
        slider.value = Float(currentSize)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false

        let bgLabel = UILabel()
        bgLabel.text = "Bakgrunnsfarge"
        bgLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        bgLabel.textColor = .secondaryLabel
        backgroundColorWell.supportsAlpha = true
        removeBackgroundBtn.setTitle("Fjern bakgrunn", for: .normal)
        removeBackgroundBtn.titleLabel?.font = .systemFont(ofSize: 14)
        removeBackgroundBtn.addTarget(self, action: #selector(removeBackgroundTapped), for: .touchUpInside)
        let bgRowStack = UIStackView(arrangedSubviews: [bgLabel, backgroundColorWell, removeBackgroundBtn])
        bgRowStack.axis = .horizontal
        bgRowStack.spacing = 12
        bgRowStack.alignment = .center
        bgRowStack.translatesAutoresizingMaskIntoConstraints = false

        advancedStack.axis = .vertical
        advancedStack.spacing = 8
        advancedStack.translatesAutoresizingMaskIntoConstraints = false
        advancedStack.addArrangedSubview(fontLabel)
        advancedStack.addArrangedSubview(tableView)
        advancedStack.addArrangedSubview(sizeHeaderStack)
        advancedStack.addArrangedSubview(slider)
        advancedStack.addArrangedSubview(bgRowStack)

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Avbryt", for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 17)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let addBtn = UIButton(type: .system)
        addBtn.setTitle("Lagre", for: .normal)
        addBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        addBtn.backgroundColor = .systemBlue
        addBtn.setTitleColor(.white, for: .normal)
        addBtn.layer.cornerRadius = 10
        addBtn.addTarget(self, action: #selector(addTapped), for: .touchUpInside)

        let btnStack = UIStackView(arrangedSubviews: [cancelBtn, addBtn])
        btnStack.axis = .horizontal
        btnStack.spacing = 12
        btnStack.distribution = .fillEqually
        btnStack.translatesAutoresizingMaskIntoConstraints = false
        btnStack.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let deleteBtn: UIButton?
        if onDelete != nil {
            let btn = UIButton(type: .system)
            btn.setTitle("Slett tekst", for: .normal)
            btn.setTitleColor(.systemRed, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 17)
            btn.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
            btn.translatesAutoresizingMaskIntoConstraints = false
            btn.heightAnchor.constraint(equalToConstant: 44).isActive = true
            deleteBtn = btn
        } else {
            deleteBtn = nil
        }

        let contentStack = UIStackView()
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(inputRow)
        contentStack.addArrangedSubview(advancedStack)
        contentStack.addArrangedSubview(btnStack)
        if let deleteBtn {
            contentStack.addArrangedSubview(deleteBtn)
        }

        let m: CGFloat = 20
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: m),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -m),
            contentStack.bottomAnchor.constraint(lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor, constant: -m),
        ])
    }

    private func updatePreferredContentSize() {
        #if targetEnvironment(macCatalyst)
        preferredContentSize = CGSize(width: 760, height: 840)
        #else
        preferredContentSize = CGSize(width: 560, height: 760)
        #endif
    }

    @objc private func snippetsTapped(_ sender: UIButton) {
        let vc = TextSnippetPickerVC(
            initialPreviewText: textView.text ?? "",
            initialInsertionRange: currentInsertionRange()
        )
        vc.onSelect = { [weak self] text in
            self?.insertSnippet(text)
        }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = sender
            pop.sourceRect = sender.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    @objc private func sliderChanged() {
        currentSize = CGFloat(slider.value)
        sizeLabel.text = "\(Int(currentSize))"
    }

    private func insertSnippet(_ snippet: String) {
        let currentText = textView.text ?? ""
        if let range = textView.selectedTextRange {
            textView.replace(range, withText: snippet)
        } else {
            let separator: String = currentText.isEmpty ? "" : (currentText.hasSuffix(" ") || currentText.hasSuffix("\n") ? "" : " ")
            textView.text = currentText + separator + snippet
        }
        placeholderLabel.isHidden = !textView.text.isEmpty
    }

    private func currentInsertionRange() -> NSRange {
        guard let selectedRange = textView.selectedTextRange else {
            let textLength = textView.text?.utf16.count ?? 0
            return NSRange(location: textLength, length: 0)
        }
        let start = textView.offset(from: textView.beginningOfDocument, to: selectedRange.start)
        let end = textView.offset(from: textView.beginningOfDocument, to: selectedRange.end)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func finishEditor(action: (() -> Void)? = nil) {
        if let onClose {
            action?()
            onClose()
        } else {
            dismiss(animated: true) { action?() }
        }
    }

    @objc private func cancelTapped() {
        finishEditor()
    }

    @objc private func deleteTapped() {
        finishEditor { [weak self] in self?.onDelete?() }
    }

    @objc private func removeBackgroundTapped() {
        backgroundColorWell.selectedColor = nil
    }

    @objc private func addTapped() {
        let raw = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            textView.layer.borderColor = UIColor.systemRed.cgColor
            textView.layer.borderWidth = 1.5
            textView.layer.cornerRadius = 10
            return
        }
        let fontName = fonts[selectedRow].name
        let fontSize = currentSize
        let bgColor = backgroundColorWell.selectedColor
        finishEditor { [weak self] in
            self?.onConfirm(raw, fontName, fontSize, bgColor)
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fonts.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "f")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "f")
        let f = fonts[indexPath.row]
        cell.textLabel?.text = f.display
        cell.textLabel?.font = resolveFont(name: f.name, size: 16)
        if f.display.hasPrefix("Thai:") {
            cell.detailTextLabel?.text = "สวัสดีครับ  ก ข ค ง จ ช ซ"
            cell.detailTextLabel?.font = resolveFont(name: f.name, size: 13)
        } else {
            cell.detailTextLabel?.text = nil
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedRow = indexPath.row
    }
}

extension TextAnnotationInputVC: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
}
