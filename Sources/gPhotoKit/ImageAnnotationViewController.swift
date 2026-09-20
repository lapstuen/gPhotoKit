import UIKit
import SwiftUI
import Vision
import PencilKit
import UniformTypeIdentifiers

open class ImageAnnotationViewController: UIViewController, PKCanvasViewDelegate {

    public var sourceImage: UIImage!
    public var onSave: ((UIImage) -> Void)?
    public var onCancel: (() -> Void)?
    public var initialProjectURL: URL?
    private var currentProjectURL: URL?

    private let imageView      = UIImageView()
    private let canvasView     = AnnotationCanvasView()
    private let pencilCanvasView = PKCanvasView()
    private var pencilToolPicker: PKToolPicker?
    private var currentToolBtn   = UIButton()
    private var currentToolLabel = UILabel()
    private var currentToolIndex = 0
    private var fontSeparator: UIView?
    private var colorDotBtn        = UIButton()
    private var fontDecBtn         = UIButton()
    private var fontIncBtn         = UIButton()
    private var dupBtn             = UIButton()
    private var layerUpBtn         = UIButton()
    private var layerDownBtn       = UIButton()
    private var selectionSeparator: UIView?
    private var libraryBtn         = UIButton()
    /// Anker for popovere/action-sheets fra "..."-menyen (avbryt/angre/tøm/
    /// blankt lerret/lagre og åpne prosjekt/bibliotek) — selve menyen
    /// erstatter det som før var separate synlige knapper for hver av disse.
    private var moreActionsBtn     = UIButton()
    private var canDismiss    = false
    private var lastTextValues: (text: String, fontSize: CGFloat, fontName: String) = ("", 32, "bold")
    private var floatingTextEditorWindow: UIWindow?
#if !targetEnvironment(macCatalyst)
    private var canvasEditMenuInteraction: UIEditMenuInteraction?
    private var canvasLongPressRecognizer: UILongPressGestureRecognizer?
    private var pendingCanvasMenuLocation: CGPoint = .zero
    private var pendingCanvasMenuItemIndex: Int?
#endif

    private var supportsPencilKitDrawing: Bool {
        traitCollection.userInterfaceIdiom == .pad || traitCollection.userInterfaceIdiom == .phone
    }

    private var pencilDrawingPolicy: PKCanvasViewDrawingPolicy {
        traitCollection.userInterfaceIdiom == .phone ? .anyInput : .pencilOnly
    }

    private let colorPalette: [(String, UIColor)] = [
        ("🔴  Rød",     .systemRed),
        ("🟠  Oransje", .systemOrange),
        ("🟡  Gul",     .systemYellow),
        ("🟢  Grønn",   .systemGreen),
        ("🔵  Blå",     .systemBlue),
        ("⚪  Hvit",    .white),
        ("⚫  Sort",    .black)
    ]

    open override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape,
                         modifierFlags: [],
                         action: #selector(escapeTapped),
                         discoverabilityTitle: "Velg-verktøy"),
            UIKeyCommand(input: "\u{8}",
                         modifierFlags: [],
                         action: #selector(deleteKeyTapped),
                         discoverabilityTitle: "Slett valgt"),
        ]
    }

    @objc private func escapeTapped() {
        selectTool(at: 0)
        updateDrawingInputState()
    }

    @objc private func deleteKeyTapped() {
        clearTapped()
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        buildLayout()
    }

    open override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        canDismiss = true
        #if targetEnvironment(macCatalyst)
        // SwiftUI-siden (ContentView.swift) setter .frame(minWidth: 400, minHeight: 300)
        // på innholdet, men det ekte macOS-vinduet har ingen tilsvarende
        // begrensning i seg selv. Uten dette kan brukeren dra vinduet mindre
        // enn innholdet — som da bare blir beskåret nederst (verktøylinjen
        // forsvinner) i stedet for å skalere med. Låser derfor det ekte
        // vinduet til samme minstemål. NB: må holdes i sync med tallene i
        // ContentView.swift.
        view.window?.windowScene?.sizeRestrictions?.minimumSize = CGSize(width: 400, height: 300)
        #endif
        print("🟣 DEBUG viewDidAppear: initialProjectURL = \(String(describing: initialProjectURL))")
        if let url = initialProjectURL {
            initialProjectURL = nil
            print("🟣 DEBUG viewDidAppear: kaller loadProject(\(url.lastPathComponent))")
            loadProject(from: url)
        } else {
            checkImageResolution()
        }
        updateDrawingInputState()
    }

    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        pencilCanvasView.contentSize = canvasView.bounds.size
    }

    private func checkImageResolution() {
        guard let img = sourceImage else { return }
        let w = Int(img.size.width), h = Int(img.size.height)
        guard min(w, h) < 600 else { return }
        let a = UIAlertController(
            title: "⚠️ Lav oppløsning",
            message: "Bildet er \(w)×\(h) px. Annotasjoner kan bli uskarpe etter lagring.",
            preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }

    private func buildLayout() {
        let titleH: CGFloat = 40
        let toolbarH: CGFloat = 64

        // Title bar — kun tittelen. Prosjektknappene (blankt lerret/lagre/
        // åpne/bibliotek) og avbryt/angre/tøm bor nå alle i "..."-menyen i
        // verktøylinjen under, slik at vi slipper en egen rad for dem.
        let titleBar = UIView()
        titleBar.backgroundColor = UIColor(white: 0.1, alpha: 1)
        titleBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleBar)

        let titleLabel = UILabel()
        titleLabel.text = "Rediger bilde"
        titleLabel.textColor = .white
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: titleH),
            titleLabel.centerXAnchor.constraint(equalTo: titleBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
        ])

        // Verktøylinje (scrollbar, alt på én rad): "..."-meny (avbryt/angre/
        // tøm/blankt lerret/lagre og åpne prosjekt/bibliotek), verktøyvelger,
        // innstillinger/farge/skrift/dupliser/lag/lim inn, lagre — slått
        // sammen fra fire stablede rader til én enkelt rad.
        let toolbar = UIView()
        #if targetEnvironment(macCatalyst)
        toolbar.backgroundColor = UIColor(white: 0.13, alpha: 1)
        #else
        toolbar.backgroundColor = .clear
        #endif
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        #if targetEnvironment(macCatalyst)
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH)
        ])
        #else
        NSLayoutConstraint.activate([
            toolbar.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: titleBar.trailingAnchor),
            toolbar.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 4),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarH)
        ])
        #endif

        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: toolbar.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
        ])

        let toolStack = UIStackView()
        toolStack.axis = .horizontal
        toolStack.spacing = 2
        toolStack.alignment = .center
        toolStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(toolStack)

        let centerToolX = toolStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor)
        centerToolX.priority = .defaultLow
        NSLayoutConstraint.activate([
            toolStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            toolStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            toolStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            toolStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            toolStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            scrollView.contentLayoutGuide.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            centerToolX,
        ])

        // Verktøyvalg: én helt vanlig knapp som viser gjeldende verktøy —
        // trykk åpner et actionSheet (samme byggekloss som resten av appen
        // bruker), i stedet for UIButton.menu/showsMenuAsPrimaryAction som
        // legger på en pil-indikator vi ikke fikk fjernet pålitelig.
        currentToolBtn = makeIconBtn(symbol: toolSymbols[0], color: .white, tag: 0)
        currentToolBtn.addTarget(self, action: #selector(toolPickerButtonTapped), for: .touchUpInside)
        currentToolBtn.addInteraction(UIContextMenuInteraction(delegate: self))
        var activeCfg = currentToolBtn.configuration ?? UIButton.Configuration.plain()
        var activeBg  = UIBackgroundConfiguration.clear()
        activeBg.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        activeBg.cornerRadius = 10
        activeCfg.background = activeBg
        currentToolBtn.configuration = activeCfg
        toolStack.addArrangedSubview(currentToolBtn)

        toolStack.addArrangedSubview(makeSep())

        let settingsBtn = makeIconBtn(symbol: "slider.horizontal.3", color: .white, tag: 500)
        settingsBtn.addTarget(self, action: #selector(settingsTapped(_:)), for: .touchUpInside)
        toolStack.addArrangedSubview(settingsBtn)

        colorDotBtn = makeIconBtn(symbol: "circle.fill", color: canvasView.currentColor, tag: 300)
        colorDotBtn.addTarget(self, action: #selector(colorPickerTapped), for: .touchUpInside)
        toolStack.addArrangedSubview(colorDotBtn)

        let fSep = makeSep()
        fSep.isHidden = true
        fontSeparator = fSep
        toolStack.addArrangedSubview(fSep)

        fontDecBtn = makeIconBtn(symbol: "textformat.size.smaller", color: .systemYellow, tag: 400)
        fontDecBtn.addTarget(self, action: #selector(fontDecTapped), for: .touchUpInside)
        fontDecBtn.isHidden = true
        toolStack.addArrangedSubview(fontDecBtn)

        fontIncBtn = makeIconBtn(symbol: "textformat.size.larger", color: .systemYellow, tag: 401)
        fontIncBtn.addTarget(self, action: #selector(fontIncTapped), for: .touchUpInside)
        fontIncBtn.isHidden = true
        toolStack.addArrangedSubview(fontIncBtn)

        let selSep = makeSep()
        selSep.isHidden = true
        selectionSeparator = selSep
        toolStack.addArrangedSubview(selSep)

        dupBtn = makeIconBtn(symbol: "plus.square.on.square", color: .systemCyan, tag: 600)
        dupBtn.addTarget(self, action: #selector(dupTapped), for: .touchUpInside)
        dupBtn.isHidden = true
        #if targetEnvironment(macCatalyst)
        toolStack.addArrangedSubview(dupBtn)
        #endif

        layerDownBtn = makeIconBtn(symbol: "arrow.down.square", color: .systemOrange, tag: 601)
        layerDownBtn.addTarget(self, action: #selector(layerDownTapped), for: .touchUpInside)
        layerDownBtn.isHidden = true
        toolStack.addArrangedSubview(layerDownBtn)

        layerUpBtn = makeIconBtn(symbol: "arrow.up.square", color: .systemOrange, tag: 602)
        layerUpBtn.addTarget(self, action: #selector(layerUpTapped), for: .touchUpInside)
        layerUpBtn.isHidden = true
        toolStack.addArrangedSubview(layerUpBtn)

        libraryBtn = makeIconBtn(symbol: "books.vertical", color: .white, tag: 700)
        libraryBtn.addTarget(self, action: #selector(objectLibraryTapped), for: .touchUpInside)
        toolStack.addArrangedSubview(libraryBtn)

        toolStack.addArrangedSubview(makeSep())

        moreActionsBtn = makeIconBtn(symbol: "ellipsis.circle", color: .white, tag: 900)
        moreActionsBtn.addTarget(self, action: #selector(moreActionsButtonTapped), for: .touchUpInside)
        toolStack.addArrangedSubview(moreActionsBtn)

        let saveIconBtn = UIButton(type: .custom)
        var saveCfg = UIButton.Configuration.filled()
        saveCfg.image = UIImage(systemName: "checkmark",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))?
            .withTintColor(.black, renderingMode: .alwaysOriginal)
        saveCfg.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 18, bottom: 9, trailing: 18)
        saveCfg.baseBackgroundColor = .systemYellow
        saveCfg.background.cornerRadius = 10
        saveIconBtn.configuration = saveCfg
        saveIconBtn.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        toolStack.addArrangedSubview(saveIconBtn)

        imageView.image = sourceImage
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .black
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        #if targetEnvironment(macCatalyst)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: titleBar.bottomAnchor),
            imageView.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        ])
        #else
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #endif

        canvasView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvasView)

        NSLayoutConstraint.activate([
            canvasView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            canvasView.topAnchor.constraint(equalTo: imageView.topAnchor),
            canvasView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])

        pencilCanvasView.translatesAutoresizingMaskIntoConstraints = false
        pencilCanvasView.backgroundColor = .clear
        pencilCanvasView.isOpaque = false
        pencilCanvasView.isScrollEnabled = false
        pencilCanvasView.drawingPolicy = pencilDrawingPolicy
        pencilCanvasView.isHidden = !supportsPencilKitDrawing
        pencilCanvasView.isUserInteractionEnabled = false
        pencilCanvasView.delegate = self
        view.addSubview(pencilCanvasView)

        NSLayoutConstraint.activate([
            pencilCanvasView.leadingAnchor.constraint(equalTo: imageView.leadingAnchor),
            pencilCanvasView.trailingAnchor.constraint(equalTo: imageView.trailingAnchor),
            pencilCanvasView.topAnchor.constraint(equalTo: imageView.topAnchor),
            pencilCanvasView.bottomAnchor.constraint(equalTo: imageView.bottomAnchor)
        ])

        canvasView.addInteraction(UIDropInteraction(delegate: self))
        canvasView.usesPencilKitForFreehand = supportsPencilKitDrawing

        canvasView.onTextTap = { [weak self] point in
            self?.showTextInputVC(at: point)
        }

        canvasView.onSelectionChanged = { [weak self] indices in
            guard let self else { return }
            // Denne (eldre) editoren tilbyr ikke flervalg — `indices` har
            // derfor alltid 0 eller 1 elementer i praksis.
            let idx = indices.count == 1 ? indices.first : nil
            let hasTextSelected = idx.map { self.canvasView.items[$0].tool == .text } ?? false
            let hasSelection = !indices.isEmpty
            self.fontDecBtn.isHidden = !hasTextSelected
            self.fontIncBtn.isHidden = !hasTextSelected
            self.fontSeparator?.isHidden = !hasTextSelected
            self.dupBtn.isHidden = !hasSelection
            self.layerDownBtn.isHidden = !hasSelection
            self.layerUpBtn.isHidden = !hasSelection
            self.selectionSeparator?.isHidden = !hasSelection
        }

        canvasView.onEditTextItem = { [weak self] idx in
            self?.showTextEditVC(for: idx)
        }

        canvasView.onContextMenu = { [weak self] idx in
            guard let self, idx < self.canvasView.items.count else { return nil }
            let item = self.canvasView.items[idx]
            var actions: [UIMenuElement] = [
                UIAction(title: "", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    self?.canvasView.duplicateSelected()
                },
                UIAction(title: "", image: UIImage(systemName: "trash"),
                         attributes: .destructive) { [weak self] _ in
                    self?.canvasView.deleteSelected()
                },
            ]
            if item.tool == .circle || item.tool == .rectangle || item.tool == .polygon || item.tool == .number || item.tool == .highlighter {
                let opacityAction = UIAction(title: "",
                                             image: Self.opacityGradientImage(color: item.color)) { [weak self] _ in
                    self?.showOpacitySlider(for: idx)
                }
                actions.insert(opacityAction, at: 0)
            }
            if item.tool == .rectangle {
                let cornerAction = UIAction(title: "",
                                            image: UIImage(systemName: "rectangle.roundedtop")) { [weak self] _ in
                    self?.showCornerRadiusSlider(for: idx)
                }
                actions.insert(cornerAction, at: 0)
            }
            if item.tool == .polygon {
                let sidesAction = UIAction(title: "", image: UIImage(systemName: "number")) { [weak self] _ in
                    self?.showPolygonSidesSlider(for: idx)
                }
                actions.insert(sidesAction, at: 0)
                let starAction = UIAction(title: "", image: UIImage(systemName: item.isStar ? "star.fill" : "star")) { [weak self] _ in
                    self?.toggleStar(for: idx)
                }
                actions.insert(starAction, at: 0)
            }
            if item.tool == .image {
                let bgAction = UIAction(title: "",
                                        image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                    self?.removeBackground(itemIndex: idx)
                }
                actions.insert(bgAction, at: 0)
                let trimAction = UIAction(title: "",
                                          image: UIImage(systemName: "crop")) { [weak self] _ in
                    self?.trimToContent(itemIndex: idx)
                }
                actions.insert(trimAction, at: 1)
                let saveLibAction = UIAction(title: "",
                                             image: UIImage(systemName: "archivebox.fill")) { [weak self] _ in
                    self?.saveItemToLibrary(itemIndex: idx)
                }
                actions.insert(saveLibAction, at: 2)
            }
            if item.tool == .text {
                let editAction = UIAction(title: "",
                                          image: UIImage(systemName: "pencil")) { [weak self] _ in
                    self?.showTextEditVC(for: idx)
                }
                actions.insert(editAction, at: 0)
            }
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
                if #available(iOS 16.0, *) {
                    return UIMenu(title: "", options: [], preferredElementSize: .small, children: actions)
                }
                return UIMenu(title: "", children: actions)
            }
        }

        #if targetEnvironment(macCatalyst)
        canvasView.onContextMenuMac = { [weak self] idx, location in
            guard let self else { return false }
            self.showMacContextMenu(for: idx, at: location)
            return true
        }
        #endif

#if !targetEnvironment(macCatalyst)
        if #available(iOS 16.0, *) {
            let interaction = UIEditMenuInteraction(delegate: self)
            canvasView.addInteraction(interaction)
            canvasEditMenuInteraction = interaction

            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(canvasLongPressed(_:)))
            longPress.minimumPressDuration = 0.9
            longPress.allowableMovement = 12
            longPress.cancelsTouchesInView = false
            canvasView.addGestureRecognizer(longPress)
            canvasLongPressRecognizer = longPress
        }
#endif

        selectTool(at: 1)
    }

    private func canvasMenuElements(for itemIndex: Int) -> [UIMenuElement]? {
        guard itemIndex < canvasView.items.count else { return nil }
        let item = canvasView.items[itemIndex]
        var actions: [UIMenuElement] = [
            UIAction(title: "", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.canvasView.duplicateSelected()
            },
            UIAction(title: "", image: UIImage(systemName: "trash"),
                     attributes: .destructive) { [weak self] _ in
                self?.canvasView.deleteSelected()
            },
        ]
        if item.tool == .circle || item.tool == .rectangle || item.tool == .polygon || item.tool == .number || item.tool == .highlighter {
            let opacityAction = UIAction(title: "",
                                         image: Self.opacityGradientImage(color: item.color)) { [weak self] _ in
                self?.showOpacitySlider(for: itemIndex)
            }
            actions.insert(opacityAction, at: 0)
        }
        if item.tool == .rectangle {
            let cornerAction = UIAction(title: "",
                                        image: UIImage(systemName: "rectangle.roundedtop")) { [weak self] _ in
                self?.showCornerRadiusSlider(for: itemIndex)
            }
            actions.insert(cornerAction, at: 0)
        }
        if item.tool == .polygon {
            let sidesAction = UIAction(title: "", image: UIImage(systemName: "number")) { [weak self] _ in
                self?.showPolygonSidesSlider(for: itemIndex)
            }
            actions.insert(sidesAction, at: 0)
            let starAction = UIAction(title: "", image: UIImage(systemName: item.isStar ? "star.fill" : "star")) { [weak self] _ in
                self?.toggleStar(for: itemIndex)
            }
            actions.insert(starAction, at: 0)
        }
        if item.tool == .image {
            let bgAction = UIAction(title: "",
                                    image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                self?.removeBackground(itemIndex: itemIndex)
            }
            actions.insert(bgAction, at: 0)
            let trimAction = UIAction(title: "",
                                      image: UIImage(systemName: "crop")) { [weak self] _ in
                self?.trimToContent(itemIndex: itemIndex)
            }
            actions.insert(trimAction, at: 1)
            let saveLibAction = UIAction(title: "",
                                         image: UIImage(systemName: "archivebox.fill")) { [weak self] _ in
                self?.saveItemToLibrary(itemIndex: itemIndex)
            }
            actions.insert(saveLibAction, at: 2)
        }
        if item.tool == .text {
            let editAction = UIAction(title: "",
                                      image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.showTextEditVC(for: itemIndex)
            }
            actions.insert(editAction, at: 0)
        }
        return actions
    }

#if !targetEnvironment(macCatalyst)
    @objc private func canvasLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        guard !canvasView.isTextResizeInteractionActive else { return }
        guard let idx = canvasView.itemIndex(at: recognizer.location(in: canvasView)) else { return }
        canvasView.selectItem(at: idx)
        pendingCanvasMenuItemIndex = idx
        pendingCanvasMenuLocation = recognizer.location(in: canvasView)
        if #available(iOS 16.0, *) {
            canvasEditMenuInteraction?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: pendingCanvasMenuLocation))
        }
    }
#endif

    #if targetEnvironment(macCatalyst)
    private func showMacContextMenu(for idx: Int, at location: CGPoint) {
        guard idx < canvasView.items.count else { return }
        let item = canvasView.items[idx]

        var actions: [MacContextMenuVC.Action] = []

        if item.tool == .circle || item.tool == .rectangle || item.tool == .polygon || item.tool == .number || item.tool == .highlighter {
            actions.append(.init(symbol: "paintbucket", destructive: false) { [weak self] in
                self?.showOpacitySlider(for: idx)
            })
        }
        if item.tool == .rectangle {
            actions.append(.init(symbol: "rectangle.roundedtop", destructive: false) { [weak self] in
                self?.showCornerRadiusSlider(for: idx)
            })
        }
        if item.tool == .polygon {
            actions.append(.init(symbol: "number", destructive: false) { [weak self] in
                self?.showPolygonSidesSlider(for: idx)
            })
            actions.append(.init(symbol: item.isStar ? "star.fill" : "star", destructive: false) { [weak self] in
                self?.toggleStar(for: idx)
            })
        }
        if item.tool == .text {
            actions.append(.init(symbol: "pencil", destructive: false) { [weak self] in
                self?.showTextEditVC(for: idx)
            })
        }
        if item.tool == .image {
            actions.append(.init(symbol: "wand.and.stars", destructive: false) { [weak self] in
                self?.removeBackground(itemIndex: idx)
            })
            actions.append(.init(symbol: "crop", destructive: false) { [weak self] in
                self?.trimToContent(itemIndex: idx)
            })
            actions.append(.init(symbol: "archivebox.fill", destructive: false) { [weak self] in
                self?.saveItemToLibrary(itemIndex: idx)
            })
        }
        actions += [
            .init(symbol: "plus.square.on.square", destructive: false) { [weak self] in
                self?.canvasView.duplicateSelected()
            },
            .init(symbol: "arrow.up.square", destructive: false) { [weak self] in
                self?.canvasView.moveSelectedToFront()
            },
            .init(symbol: "arrow.down.square", destructive: false) { [weak self] in
                self?.canvasView.moveSelectedToBack()
            },
            .init(symbol: "trash", destructive: true) { [weak self] in
                self?.canvasView.deleteSelected()
            },
        ]

        let vc = MacContextMenuVC(actions: actions)
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = canvasView
            pop.sourceRect = CGRect(x: location.x, y: location.y, width: 0, height: 0)
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: false)
    }
    #endif

    private static func opacityGradientImage(color: UIColor) -> UIImage {
        let size = CGSize(width: 28, height: 28)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let solid = color.cgColor
            let clear = color.withAlphaComponent(0).cgColor
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [solid, clear] as CFArray,
                locations: [0, 1]
            ) else { return }
            let path = UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 26, height: 26))
            c.addPath(path.cgPath)
            c.clip()
            c.drawLinearGradient(gradient,
                                 start: CGPoint(x: 0, y: 14),
                                 end: CGPoint(x: 28, y: 14),
                                 options: [])
        }.withRenderingMode(.alwaysOriginal)
    }

    private func makeIconBtn(symbol: String, color: UIColor, tag: Int) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: symbol,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        let btn = UIButton(configuration: cfg)
        btn.tag = tag
        btn.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return btn
    }

    private func makeSep() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor.white.withAlphaComponent(0.2)
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return v
    }

    private let toolMap: [AnnotationTool] = [.select, .freehand, .highlighter, .line, .arrow, .circle, .rectangle, .number, .text, .polygon]
    private let toolSymbols = ["cursorarrow", "pencil", "highlighter", "pencil.and.scribble", "arrow.up.right", "circle",
                               "rectangle", "number.circle.fill", "textformat", "pentagon"]
    private let toolNames   = ["Velg", "Frihånd", "Markering", "Linje", "Pil", "Sirkel",
                               "Rektangel", "Nummer", "Tekst", "Polygon"]

    private let availableFonts: [(display: String, name: String)] = [
        ("System Fet",              "bold"),
        ("System Normal",           "system"),
        ("Thai: Noto Sans",         "NotoSansThai-Regular"),
        ("Thai: Noto Sans Fet",     "NotoSansThai-Bold"),
        ("Thai: Sarabun",           "Sarabun-Regular"),
        ("Thai: Sarabun Fet",       "Sarabun-Bold"),
        ("Thai: Kanit",             "Kanit-Regular"),
        ("Thai: Kanit Fet",         "Kanit-Bold"),
        ("Thai: Prompt",            "Prompt-Regular"),
        ("Thai: Thonburi",          "Thonburi"),
        ("Thai: Thonburi Fet",      "Thonburi-Bold"),
        ("Thai: Ayuthaya",          "Ayuthaya"),
        ("Thai: Krungthep",         "Krungthep"),
        ("Thai: Sathu",             "Sathu"),
        ("Thai: Silom",             "Silom"),
        ("Georgia",                 "Georgia"),
        ("Georgia Fet",             "Georgia-Bold"),
        ("Times New Roman",         "TimesNewRomanPSMT"),
        ("Courier",                 "Courier"),
        ("Courier Fet",             "Courier-Bold"),
        ("American Typewriter",     "AmericanTypewriter"),
        ("Palatino",                "Palatino-Roman"),
        ("Palatino Fet",            "Palatino-Bold"),
        ("Noteworthy",              "Noteworthy-Light"),
        ("Marker Felt",             "MarkerFelt-Thin"),
    ]

    private func showTextInputVC(at point: CGPoint) {
        let saved = lastTextValues
        let vc = TextAnnotationInputVC(
            fonts: availableFonts,
            initialText: saved.text,
            initialFontName: saved.fontName,
            initialFontSize: saved.fontSize,
            initialBackgroundColor: self.canvasView.currentTextBackgroundColor
        ) { [weak self] text, fontName, fontSize, backgroundColor in
            guard let self else { return }
            self.lastTextValues = (text, fontSize, fontName)
            self.canvasView.currentTextBackgroundColor = backgroundColor
            let font = resolveFont(name: fontName, size: fontSize)
            let attrs = wrappedTextAttributes(font: font, color: self.canvasView.currentColor)
            let measuredWidth = wrappedTextBounds(text: text, maxWidth: self.canvasView.bounds.width, attributes: attrs).width
            let defaultWidth = max(28, min(measuredWidth + 24, min(self.canvasView.bounds.width * 0.35, 240)))
            let item = AnnotationItem(
                tool: .text,
                color: self.canvasView.currentColor,
                lineWidth: self.canvasView.currentLineWidth,
                points: [point],
                text: text,
                fontSize: fontSize,
                fontName: fontName,
                textWidth: defaultWidth,
                opacity: self.canvasView.currentFillOpacity,
                backgroundColor: backgroundColor)
            self.canvasView.items.append(item)
            self.canvasView.selectItem(at: self.canvasView.items.count - 1)
        }
        presentTextEditor(vc)
    }

    /// Viser verktøyvalget som et vanlig actionSheet i stedet for
    /// UIButton.menu — helt vanlig knapp, ingen automatisk pil-indikator å
    /// hanskes med.
    @objc private func toolPickerButtonTapped() {
        #if targetEnvironment(macCatalyst)
        // UIAlertController(.actionSheet) rendres som en HORISONTAL rad på
        // Mac Catalyst når den presenteres som popover — bruk custom vertikal
        // liste i stedet, samme mønster som MacContextMenuVC.
        let actions: [MacActionListVC.Action] = toolMap.indices.map { index in
            .init(symbol: toolSymbols[index], title: toolNames[index], destructive: false) { [weak self] in
                self?.selectTool(at: index)
            }
        }
        let vc = MacActionListVC(actions: actions, cancelTitle: "Lukk")
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = currentToolBtn
            pop.sourceRect = currentToolBtn.bounds
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: false)
        #else
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for index in toolMap.indices {
            sheet.addAction(UIAlertAction(title: toolNames[index], style: .default) { [weak self] _ in
                self?.selectTool(at: index)
            })
        }
        sheet.addAction(UIAlertAction(title: "Lukk", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = currentToolBtn
            pop.sourceRect = currentToolBtn.bounds
        }
        present(sheet, animated: true)
        #endif
    }

    /// Samler avbryt/angre/tøm og prosjektknappene (blankt lerret/lagre og
    /// åpne prosjekt/bibliotek) i ett actionSheet bak "..."-knappen.
    @objc private func moreActionsButtonTapped() {
        #if targetEnvironment(macCatalyst)
        // Samme fix som toolPickerButtonTapped — se kommentar der.
        let actions: [MacActionListVC.Action] = [
            .init(symbol: "xmark", title: "Avbryt redigering", destructive: false) { [weak self] in
                self?.cancelTapped()
            },
            .init(symbol: "arrow.uturn.backward", title: "Angre", destructive: false) { [weak self] in
                self?.undoTapped()
            },
            .init(symbol: "trash", title: "Tøm", destructive: true) { [weak self] in
                self?.clearTapped()
            },
            .init(symbol: "square.dashed", title: "Blankt lerret", destructive: false) { [weak self] in
                self?.blankCanvasTapped()
            },
            .init(symbol: "square.and.arrow.down", title: "Lagre prosjekt", destructive: false) { [weak self] in
                self?.saveProjectTapped()
            },
            .init(symbol: "folder", title: "Åpne prosjekt", destructive: false) { [weak self] in
                self?.loadProjectTapped()
            },
            .init(symbol: "crop", title: "Beskjær", destructive: false) { [weak self] in
                self?.cropTapped()
            },
            .init(symbol: "wand.and.stars", title: "Fjern bakgrunn", destructive: false) { [weak self] in
                self?.removeBackgroundTapped()
            },
        ]
        let vc = MacActionListVC(actions: actions, cancelTitle: "Lukk")
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = moreActionsBtn
            pop.sourceRect = moreActionsBtn.bounds
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: false)
        #else
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Avbryt redigering", style: .default) { [weak self] _ in
            self?.cancelTapped()
        })
        sheet.addAction(UIAlertAction(title: "Angre", style: .default) { [weak self] _ in
            self?.undoTapped()
        })
        sheet.addAction(UIAlertAction(title: "Dupliser", style: .default) { [weak self] _ in
            self?.canvasView.duplicateSelected()
        })
        sheet.addAction(UIAlertAction(title: "Tøm", style: .destructive) { [weak self] _ in
            self?.clearTapped()
        })
        sheet.addAction(UIAlertAction(title: "Blankt lerret", style: .default) { [weak self] _ in
            self?.blankCanvasTapped()
        })
        sheet.addAction(UIAlertAction(title: "Lagre prosjekt", style: .default) { [weak self] _ in
            self?.saveProjectTapped()
        })
        sheet.addAction(UIAlertAction(title: "Åpne prosjekt", style: .default) { [weak self] _ in
            self?.loadProjectTapped()
        })
        sheet.addAction(UIAlertAction(title: "Beskjær", style: .default) { [weak self] _ in
            self?.cropTapped()
        })
        sheet.addAction(UIAlertAction(title: "Fjern bakgrunn", style: .default) { [weak self] _ in
            self?.removeBackgroundTapped()
        })
        sheet.addAction(UIAlertAction(title: "Lukk", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = moreActionsBtn
            pop.sourceRect = moreActionsBtn.bounds
        }
        present(sheet, animated: true)
        #endif
    }

    private func selectTool(at index: Int) {
        canvasView.deselect()
        currentToolIndex = index
        canvasView.currentTool = toolMap[index]
        if toolMap[index] == .highlighter {
            canvasView.currentColor      = .systemYellow
            canvasView.currentLineWidth  = 30
            canvasView.currentFillOpacity = 0.5
            colorDotBtn.configuration?.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium))?
                .withTintColor(.systemYellow, renderingMode: .alwaysOriginal)
        }
        updateDrawingInputState()

        var cfg = currentToolBtn.configuration ?? UIButton.Configuration.plain()
        cfg.image = UIImage(systemName: toolSymbols[index],
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .medium))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        var bg = UIBackgroundConfiguration.clear()
        bg.backgroundColor = UIColor.white.withAlphaComponent(0.18)
        bg.cornerRadius = 10
        cfg.background = bg
        currentToolBtn.configuration = cfg
    }

    private func updateDrawingInputState() {
        let usePencilKit = supportsPencilKitDrawing && toolMap[currentToolIndex].isFreehandLike
        let hasPencilDrawing = !pencilCanvasView.drawing.strokes.isEmpty
        canvasView.isUserInteractionEnabled = !usePencilKit
        pencilCanvasView.isHidden = !(usePencilKit || hasPencilDrawing)
        pencilCanvasView.isUserInteractionEnabled = usePencilKit

        guard usePencilKit else {
            if supportsPencilKitDrawing {
                pencilCanvasView.resignFirstResponder()
                pencilToolPicker?.setVisible(false, forFirstResponder: pencilCanvasView)
            }
            return
        }

        let currentTool = toolMap[currentToolIndex]
        let inkType: PKInkingTool.InkType = currentTool == .highlighter ? .marker : .pen
        let toolColor = currentTool == .highlighter
            ? canvasView.currentColor.withAlphaComponent(canvasView.currentFillOpacity)
            : canvasView.currentColor
        pencilCanvasView.tool = PKInkingTool(inkType, color: toolColor, width: canvasView.currentLineWidth)
        pencilCanvasView.drawingPolicy = pencilDrawingPolicy

        guard let window = view.window else { return }
        if pencilToolPicker == nil {
            pencilToolPicker = PKToolPicker.shared(for: window)
            pencilToolPicker?.addObserver(pencilCanvasView)
        }
        pencilCanvasView.becomeFirstResponder()
        pencilToolPicker?.setVisible(true, forFirstResponder: pencilCanvasView)
    }

    @objc private func settingsTapped(_ sender: UIButton) {
        let effectiveTool: AnnotationTool
        if let idx = canvasView.selectedItemIndex, idx < canvasView.items.count {
            effectiveTool = canvasView.items[idx].tool
        } else {
            effectiveTool = canvasView.currentTool
        }
        if effectiveTool == .text, let idx = canvasView.selectedItemIndex, idx < canvasView.items.count {
            let item = canvasView.items[idx]
            let vc = TextStylePickerVC(
                fonts: availableFonts,
                initialFontName: item.fontName,
                initialFontSize: item.fontSize,
                initialBackgroundColor: item.backgroundColor
            ) { [weak self] fontName, fontSize, backgroundColor in
                guard let self, idx < self.canvasView.items.count else { return }
                self.canvasView.items[idx].fontName = fontName
                self.canvasView.items[idx].fontSize = fontSize
                self.canvasView.items[idx].backgroundColor = backgroundColor
                self.canvasView.setNeedsDisplay()
            }
            vc.modalPresentationStyle = .popover
            if let pop = vc.popoverPresentationController {
                pop.sourceView = sender
                pop.sourceRect = sender.bounds
                pop.permittedArrowDirections = [.up, .down]
                pop.delegate = vc
            }
            present(vc, animated: true)
            return
        }

        // Merkepenn/sirkel/rektangel trenger begge kontrollene (bredde OG
        // fyllingsgrad), i motsetning til de andre verktøyene som bare trenger
        // én av dem — la brukeren velge hvilken.
        if effectiveTool == .highlighter || effectiveTool == .circle || effectiveTool == .rectangle {
            #if targetEnvironment(macCatalyst)
            // Samme fix som toolPickerButtonTapped — se kommentar der:
            // UIAlertController(.actionSheet) rendres horisontalt på Mac Catalyst.
            let actions: [MacActionListVC.Action] = [
                .init(symbol: "line.3.horizontal", title: "Strektykkelse", destructive: false) { [weak self] in
                    self?.presentLineWidthPopover(from: sender)
                },
                .init(symbol: "circle.lefthalf.filled", title: "Gjennomsiktighet", destructive: false) { [weak self] in
                    self?.presentOpacityPopover(from: sender)
                },
            ]
            let vc = MacActionListVC(actions: actions, cancelTitle: "Lukk")
            vc.modalPresentationStyle = .popover
            if let pop = vc.popoverPresentationController {
                pop.sourceView = sender
                pop.sourceRect = sender.bounds
                pop.permittedArrowDirections = .any
                pop.delegate = vc
            }
            present(vc, animated: false)
            #else
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Strektykkelse", style: .default) { [weak self] _ in
                self?.presentLineWidthPopover(from: sender)
            })
            sheet.addAction(UIAlertAction(title: "Gjennomsiktighet", style: .default) { [weak self] _ in
                self?.presentOpacityPopover(from: sender)
            })
            sheet.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = sender
                pop.sourceRect = sender.bounds
            }
            present(sheet, animated: true)
            #endif
            return
        }

        // Polygon trenger tre kontroller (strektykkelse, fyllingsgrad, pluss
        // antall hjørner og stjerne-av/på) — samme valgsheet-mønster som
        // Merkepenn/sirkel/rektangel over, bare med to ekstra valg.
        if effectiveTool == .polygon {
            #if targetEnvironment(macCatalyst)
            let actions: [MacActionListVC.Action] = [
                .init(symbol: "line.3.horizontal", title: "Strektykkelse", destructive: false) { [weak self] in
                    self?.presentLineWidthPopover(from: sender)
                },
                .init(symbol: "circle.lefthalf.filled", title: "Gjennomsiktighet", destructive: false) { [weak self] in
                    self?.presentOpacityPopover(from: sender)
                },
                .init(symbol: "number", title: "Antall hjørner", destructive: false) { [weak self] in
                    self?.presentPolygonSidesPopover(from: sender)
                },
                .init(symbol: "star", title: "Stjerne", destructive: false) { [weak self] in
                    self?.togglePolygonStar()
                },
            ]
            let vc = MacActionListVC(actions: actions, cancelTitle: "Lukk")
            vc.modalPresentationStyle = .popover
            if let pop = vc.popoverPresentationController {
                pop.sourceView = sender
                pop.sourceRect = sender.bounds
                pop.permittedArrowDirections = .any
                pop.delegate = vc
            }
            present(vc, animated: false)
            #else
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: "Strektykkelse", style: .default) { [weak self] _ in
                self?.presentLineWidthPopover(from: sender)
            })
            sheet.addAction(UIAlertAction(title: "Gjennomsiktighet", style: .default) { [weak self] _ in
                self?.presentOpacityPopover(from: sender)
            })
            sheet.addAction(UIAlertAction(title: "Antall hjørner", style: .default) { [weak self] _ in
                self?.presentPolygonSidesPopover(from: sender)
            })
            sheet.addAction(UIAlertAction(title: "Stjerne", style: .default) { [weak self] _ in
                self?.togglePolygonStar()
            })
            sheet.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
            if let pop = sheet.popoverPresentationController {
                pop.sourceView = sender
                pop.sourceRect = sender.bounds
            }
            present(sheet, animated: true)
            #endif
            return
        }

        let isOpacity = effectiveTool == .number
        if isOpacity {
            presentOpacityPopover(from: sender)
        } else {
            presentLineWidthPopover(from: sender)
        }
    }

    private func presentOpacityPopover(from sender: UIView) {
        let vc = SliderPickerPopoverVC(
            title: "Gjennomsiktighet",
            min: 0.05, max: 1.0,
            value: Float(canvasView.currentFillOpacity),
            format: { "\(Int($0 * 100))%" }
        )
        vc.onChange = { [weak self] v in
            guard let self else { return }
            self.canvasView.currentFillOpacity = v
            if let idx = self.canvasView.selectedItemIndex {
                self.canvasView.items[idx].opacity = v
                self.canvasView.setNeedsDisplay()
            }
            self.updateDrawingInputState()
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

    private func presentLineWidthPopover(from sender: UIView) {
        let vc = SliderPickerPopoverVC(
            title: "Strektykkelse",
            min: 1, max: 50,
            value: Float(canvasView.currentLineWidth),
            format: { "\(Int($0))" }
        )
        vc.onChange = { [weak self] v in
            guard let self else { return }
            self.canvasView.currentLineWidth = v
            if let idx = self.canvasView.selectedItemIndex {
                self.canvasView.items[idx].lineWidth = v
                self.canvasView.setNeedsDisplay()
            }
            self.updateDrawingInputState()
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

    private func presentPolygonSidesPopover(from sender: UIView) {
        let currentSides: Int
        if let idx = canvasView.selectedItemIndex, idx < canvasView.items.count {
            currentSides = canvasView.items[idx].sides
        } else {
            currentSides = canvasView.currentPolygonSides
        }
        let vc = SliderPickerPopoverVC(
            title: "Antall hjørner",
            min: 3, max: 12,
            value: Float(currentSides),
            format: { "\(Int($0))" }
        )
        vc.onChange = { [weak self] v in
            guard let self else { return }
            let sides = Int(v)
            self.canvasView.currentPolygonSides = sides
            if let idx = self.canvasView.selectedItemIndex, idx < self.canvasView.items.count {
                self.canvasView.items[idx].sides = sides
                self.canvasView.setNeedsDisplay()
            }
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

    private func togglePolygonStar() {
        if let idx = canvasView.selectedItemIndex, idx < canvasView.items.count {
            let newValue = !canvasView.items[idx].isStar
            canvasView.items[idx].isStar = newValue
            canvasView.currentPolygonIsStar = newValue
            canvasView.setNeedsDisplay()
        } else {
            canvasView.currentPolygonIsStar.toggle()
        }
    }

    private func showOpacitySlider(for idx: Int) {
        guard idx < canvasView.items.count else { return }
        let vc = SliderPickerPopoverVC(
            title: "Fyllingsgrad",
            min: 0.05, max: 1.0,
            value: Float(canvasView.items[idx].opacity),
            format: { "\(Int($0 * 100))%" }
        )
        vc.onChange = { [weak self] v in
            guard let self, idx < self.canvasView.items.count else { return }
            self.canvasView.items[idx].opacity = v
            self.canvasView.currentFillOpacity = v
            self.canvasView.setNeedsDisplay()
            self.updateDrawingInputState()
        }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = canvasView
            pop.sourceRect = CGRect(x: canvasView.bounds.midX, y: canvasView.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func showCornerRadiusSlider(for idx: Int) {
        guard idx < canvasView.items.count else { return }
        let vc = SliderPickerPopoverVC(
            title: "Avrunding",
            min: 0, max: 200,
            value: Float(canvasView.items[idx].cornerRadius),
            format: { "\(Int($0))" }
        )
        vc.onChange = { [weak self] v in
            guard let self, idx < self.canvasView.items.count else { return }
            self.canvasView.items[idx].cornerRadius = CGFloat(v)
            self.canvasView.setNeedsDisplay()
        }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = canvasView
            pop.sourceRect = CGRect(x: canvasView.bounds.midX, y: canvasView.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func showPolygonSidesSlider(for idx: Int) {
        guard idx < canvasView.items.count else { return }
        let vc = SliderPickerPopoverVC(
            title: "Antall hjørner",
            min: 3, max: 12,
            value: Float(canvasView.items[idx].sides),
            format: { "\(Int($0))" }
        )
        vc.onChange = { [weak self] v in
            guard let self, idx < self.canvasView.items.count else { return }
            let sides = Int(v)
            self.canvasView.items[idx].sides = sides
            self.canvasView.currentPolygonSides = sides
            self.canvasView.setNeedsDisplay()
        }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = canvasView
            pop.sourceRect = CGRect(x: canvasView.bounds.midX, y: canvasView.bounds.midY, width: 0, height: 0)
            pop.permittedArrowDirections = .any
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func toggleStar(for idx: Int) {
        guard idx < canvasView.items.count else { return }
        let newValue = !canvasView.items[idx].isStar
        canvasView.items[idx].isStar = newValue
        canvasView.currentPolygonIsStar = newValue
        canvasView.setNeedsDisplay()
    }

    private func showCurrentToolSlider(isOpacity: Bool, from src: UIView?) {
        let source: UIView = src ?? view
        let vc: SliderPickerPopoverVC
        if isOpacity {
            vc = SliderPickerPopoverVC(
                title: "Gjennomsiktighet",
                min: 0.05, max: 1.0,
                value: Float(canvasView.currentFillOpacity),
                format: { "\(Int($0 * 100))%" }
            )
            vc.onChange = { [weak self] v in
                guard let self else { return }
                self.canvasView.currentFillOpacity = v
                if let idx = self.canvasView.selectedItemIndex {
                    self.canvasView.items[idx].opacity = v
                    self.canvasView.setNeedsDisplay()
                }
            }
        } else {
            vc = SliderPickerPopoverVC(
                title: "Strektykkelse",
                min: 1, max: 50,
                value: Float(canvasView.currentLineWidth),
                format: { "\(Int($0))" }
            )
            vc.onChange = { [weak self] v in
                guard let self else { return }
                self.canvasView.currentLineWidth = v
                if let idx = self.canvasView.selectedItemIndex {
                    self.canvasView.items[idx].lineWidth = v
                    self.canvasView.setNeedsDisplay()
                }
            }
        }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = source
            pop.sourceRect = source.bounds
            
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func opacityMenu() -> UIMenu {
        let levels: [(String, CGFloat)] = [
            ("◻  Svak (20%)",   0.2),
            ("▥  Lys (40%)",    0.4),
            ("▤  Normal (60%)", 0.6),
            ("▦  Sterk (80%)",  0.8),
            ("■  Solid (100%)", 1.0),
        ]
        let actions = levels.map { title, opacity in
            let active = abs(canvasView.currentFillOpacity - opacity) < 0.01
            return UIAction(title: active ? "✓  \(title)" : title) { [weak self] _ in
                self?.canvasView.currentFillOpacity = opacity
                self?.updateDrawingInputState()
            }
        }
        return UIMenu(title: "Gjennomsiktighet", children: actions)
    }

    private func lineWidthMenu() -> UIMenu {
        let widths: [(String, CGFloat)] = [
            ("▪  Tynn (4)",          4),
            ("▬  Normal (12)",      12),
            ("━  Tykk (22)",        22),
            ("█  Veldig tykk (36)", 36),
        ]
        let actions = widths.map { title, w in
            let active = abs(canvasView.currentLineWidth - w) < 0.1
            return UIAction(title: active ? "✓  \(title)" : title) { [weak self] _ in
                self?.canvasView.currentLineWidth = w
                self?.updateDrawingInputState()
            }
        }
        return UIMenu(title: "Strektykkelse", children: actions)
    }

    @objc private func colorPickerTapped() {
        let colors = colorPalette.map { $0.1 }
        let vc = ColorPickerPopoverVC(colors: colors, activeColor: canvasView.currentColor)
        vc.onSelect = { [weak self] color in self?.applyColor(color) }
        vc.onOpenFullPicker = { [weak self] in self?.openSystemColorPicker() }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = colorDotBtn
            pop.sourceRect = colorDotBtn.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func applyColor(_ color: UIColor) {
        canvasView.currentColor = color
        colorDotBtn.configuration?.image = UIImage(
            systemName: "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .medium))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        if let idx = canvasView.selectedItemIndex {
            canvasView.items[idx].color = color
            canvasView.setNeedsDisplay()
        }
        updateDrawingInputState()
    }

    private func openSystemColorPicker() {
        #if targetEnvironment(macCatalyst)
        let vc = MacColorWellVC(initialColor: canvasView.currentColor)
        vc.onColorChanged = { [weak self] color in self?.applyColor(color) }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = colorDotBtn
            pop.sourceRect = colorDotBtn.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = vc
        }
        present(vc, animated: true)
        #else
        let picker = UIColorPickerViewController()
        picker.selectedColor = canvasView.currentColor
        picker.supportsAlpha = false
        picker.delegate = self
        present(picker, animated: true)
        #endif
    }

    @objc private func undoTapped() {
        guard !canvasView.items.isEmpty else { return }
        let removed = canvasView.items.last
        canvasView.undo()
        if removed?.tool == .text, let pt = removed?.points.first {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.showTextInputVC(at: pt)
            }
        }
    }

    @objc private func clearTapped() {
        guard !canvasView.items.isEmpty || !pencilCanvasView.drawing.strokes.isEmpty else { return }
        if canvasView.selectedItemIndex != nil {
            canvasView.deleteSelected()
            return
        }
        if #available(iOS 27.0, *), supportsPencilKitDrawing, !pencilCanvasView.selection.isEmpty {
            let selectedIDs = pencilCanvasView.selection
            let remaining = pencilCanvasView.drawing.strokes.filter { !selectedIDs.contains($0.id) }
            pencilCanvasView.drawing = PKDrawing(strokes: remaining)
            pencilCanvasView.selection = []
            return
        }
        let a = UIAlertController(title: "Tøm alle tegninger?", message: nil, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Tøm", style: .destructive) { [weak self] _ in self?.canvasView.clear() })
        a.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(a, animated: true)
    }

    @objc private func dupTapped()       { canvasView.duplicateSelected() }
    @objc private func layerUpTapped()   { canvasView.moveSelectedToFront() }
    @objc private func layerDownTapped() { canvasView.moveSelectedToBack() }

    private func removeBackground(itemIndex: Int) {
        guard itemIndex < canvasView.items.count,
              let img = canvasView.items[itemIndex].overlayImage else { return }

        guard #available(iOS 17.0, *) else {
            let a = UIAlertController(title: "Krever iOS 17",
                                       message: "Fjern bakgrunn krever iOS 17 eller nyere.", preferredStyle: .alert)
            a.addAction(UIAlertAction(title: "OK", style: .default))
            present(a, animated: true)
            return
        }

        ObjectLibrary.removeBackground(from: img) { [weak self] masked in
            guard let self, itemIndex < self.canvasView.items.count else { return }
            if let masked {
                self.canvasView.items[itemIndex].overlayImage = masked
                self.canvasView.setNeedsDisplay()
            }
        }
    }

    private func saveItemToLibrary(itemIndex: Int) {
        guard itemIndex < canvasView.items.count,
              let img = canvasView.items[itemIndex].overlayImage else { return }
        // Kontekstmenyen (long-press/høyreklikk) er fortsatt i ferd med å
        // lukke seg idet denne handleren kjører — å presentere et nytt
        // UIAlertController synkront her kolliderer med den lukke-animasjonen
        // og gir en "frosset" tom spinner-boble i stedet for kategori-valget.
        // Vent til lukkingen er ferdig før vi presenterer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.presentLibraryCategoryPicker(for: img)
        }
    }

    private func saveSelectedImageToLibrary() {
        guard let idx = canvasView.selectedItemIndex,
              idx < canvasView.items.count,
              canvasView.items[idx].tool == .image,
              let image = canvasView.items[idx].overlayImage else {
            let alert = UIAlertController(
                title: "Velg et bilde",
                message: "Marker et bildeelement før du lagrer det til objektbiblioteket.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        presentLibraryCategoryPicker(for: image)
    }

    private func presentLibraryCategoryPicker(for image: UIImage) {
        let alert = UIAlertController(
            title: "Velg katalog",
            message: "Hvor skal objektet lagres?",
            preferredStyle: .alert
        )

        let categories = ObjectLibrary.categories()
        for category in categories {
            alert.addAction(UIAlertAction(title: category, style: .default) { [weak self] _ in
                self?.saveImageToLibrary(image, category: category == ObjectLibrary.uncategorizedCategory ? nil : category)
            })
        }

        alert.addAction(UIAlertAction(title: "Ny katalog...", style: .default) { [weak self] _ in
            self?.promptForNewLibraryCategory(for: image)
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    private func promptForNewLibraryCategory(for image: UIImage) {
        let alert = UIAlertController(
            title: "Ny katalog",
            message: "Skriv navnet på katalogen.",
            preferredStyle: .alert
        )
        alert.addTextField { tf in
            tf.placeholder = "F.eks. biler, mennesker, dyr"
            tf.autocapitalizationType = .words
            tf.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: "Lagre", style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return }
            self.saveImageToLibrary(image, category: text)
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    private func saveImageToLibrary(_ image: UIImage, category: String?) {
        do {
            _ = try ObjectLibrary.save(image, in: category)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let category, !category.isEmpty {
                showToast("✅ Lagret til \(category)")
            } else {
                showToast("✅ Lagret til objektbibliotek")
            }
        } catch {
            let alert = UIAlertController(
                title: "Kunne ikke lagre",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func showToast(_ message: String) {
        let lbl = UILabel()
        lbl.text = message
        lbl.textColor = .white
        lbl.font = .systemFont(ofSize: 15, weight: .semibold)
        lbl.textAlignment = .center
        let w: CGFloat = 260, h: CGFloat = 44
        let bg = UIView()
        bg.backgroundColor = UIColor(white: 0, alpha: 0.78)
        bg.layer.cornerRadius = 12
        bg.frame = CGRect(x: (view.bounds.width - w) / 2,
                          y: view.bounds.height - 160, width: w, height: h)
        lbl.frame = bg.bounds
        bg.addSubview(lbl)
        view.addSubview(bg)
        UIView.animate(withDuration: 0.3, delay: 1.4, options: []) { bg.alpha = 0 } completion: { _ in bg.removeFromSuperview() }
    }

    private func trimToContent(itemIndex: Int) {
        guard itemIndex < canvasView.items.count,
              let img = canvasView.items[itemIndex].overlayImage else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let trimmed = ObjectLibrary.trimToContent(img)
            DispatchQueue.main.async {
                guard let self, itemIndex < self.canvasView.items.count else { return }
                if let trimmed {
                    self.canvasView.items[itemIndex].overlayImage = trimmed
                    // Resize the canvas item to match new aspect ratio
                    let pts = self.canvasView.items[itemIndex].points
                    guard pts.count >= 2 else { return }
                    let originX = pts[0].x, originY = pts[0].y
                    let oldW = pts[1].x - pts[0].x
                    let scale = oldW / trimmed.size.width
                    let newH = trimmed.size.height * scale
                    self.canvasView.items[itemIndex].points = [
                        CGPoint(x: originX, y: originY),
                        CGPoint(x: originX + oldW, y: originY + newH)
                    ]
                    self.canvasView.setNeedsDisplay()
                }
            }
        }
    }

    @objc private func objectLibraryTapped() {
        let pickerView = ObjectLibraryPickerView(
            onSelect: { [weak self] image in
                guard let self else { return }
                self.dismiss(animated: true) {
                    self.insertImageIntoCanvas(image)
                }
            },
            onDismiss: { [weak self] in
                self?.dismiss(animated: true)
            }
        )
        let picker = UIHostingController(rootView: pickerView)
        picker.modalPresentationStyle = .popover
        if let pop = picker.popoverPresentationController {
            pop.sourceView = libraryBtn
            pop.sourceRect = libraryBtn.bounds
            pop.permittedArrowDirections = [.up, .down]
        }
        present(picker, animated: true)
    }


    private func insertImageIntoCanvas(_ img: UIImage) {
        let canvas = canvasView.bounds
        let maxW = canvas.width * 0.5
        let maxH = canvas.height * 0.5
        let scale = min(maxW / img.size.width, maxH / img.size.height, 1)
        let w = img.size.width * scale
        let h = img.size.height * scale
        let x = (canvas.width - w) / 2
        let y = (canvas.height - h) / 2
        var item = AnnotationItem(tool: .image, color: .clear, lineWidth: 0,
                                  points: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y + h)])
        item.overlayImage = img
        canvasView.items.append(item)
        canvasView.selectItem(at: canvasView.items.count - 1)
    }

    @objc private func fontDecTapped() { canvasView.adjustSelectedFontSize(delta: -4) }
    @objc private func fontIncTapped() { canvasView.adjustSelectedFontSize(delta: +4) }

    private func showTextEditVC(for index: Int) {
        guard index < canvasView.items.count else { return }
        let item = canvasView.items[index]
        let vc = TextAnnotationInputVC(
            fonts: availableFonts,
            initialText: item.text,
            initialFontName: item.fontName,
            initialFontSize: item.fontSize,
            initialBackgroundColor: item.backgroundColor,
            onDelete: { [weak self] in
                guard let self, index < self.canvasView.items.count else { return }
                self.canvasView.items.remove(at: index)
                self.canvasView.deselect()
            },
            onConfirm: { [weak self] text, fontName, fontSize, backgroundColor in
                guard let self, index < self.canvasView.items.count else { return }
                self.canvasView.items[index].text = text
                self.canvasView.items[index].fontName = fontName
                self.canvasView.items[index].fontSize = fontSize
                self.canvasView.items[index].backgroundColor = backgroundColor
                self.lastTextValues = (text, fontSize, fontName)
                self.canvasView.setNeedsDisplay()
            }
        )
        presentTextEditor(vc)
    }

    private func presentTextEditor(_ vc: TextAnnotationInputVC) {
        #if targetEnvironment(macCatalyst)
        guard let scene = view.window?.windowScene else {
            present(vc, animated: true)
            return
        }
        vc.preferredContentSize = CGSize(width: 760, height: 240)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = vc
        window.windowLevel = .normal
        let size = vc.preferredContentSize
        if let host = view.window {
            let bottomMargin: CGFloat = 24
            window.frame = CGRect(x: host.frame.midX - size.width / 2,
                                  y: host.frame.maxY - size.height - bottomMargin,
                                  width: size.width,
                                  height: size.height)
        } else {
            window.frame = CGRect(x: 100, y: 100, width: size.width, height: size.height)
        }
        floatingTextEditorWindow = window
        vc.onClose = { [weak self] in
            self?.floatingTextEditorWindow?.isHidden = true
            self?.floatingTextEditorWindow = nil
        }
        window.makeKeyAndVisible()
        #else
        vc.preferredContentSize = CGSize(width: 560, height: 220)
        present(vc, animated: true)
        #endif
    }

    @objc private func cancelTapped() {
        guard canDismiss else { return }
        let done = onCancel
        dismiss(animated: true) { done?() }
    }

    // MARK: - Project save / load

    private var projectsDirectory: URL {
        if let icloud = FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.no.1955.gPhoto")?
            .appendingPathComponent("Documents/gPhotoProjects", isDirectory: true) {
            try? FileManager.default.createDirectory(at: icloud, withIntermediateDirectories: true)
            return icloud
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("gPhotoProjects", isDirectory: true)
    }

    @objc private func saveProjectTapped() {
        print("🔵 DEBUG saveProjectTapped — lagrer til: \(projectsDirectory.path)")
        let sheet = UIAlertController(title: "Lagre prosjekt", message: nil, preferredStyle: .actionSheet)
        if let currentProjectURL {
            sheet.addAction(UIAlertAction(title: "Oppdater", style: .default) { [weak self] _ in
                guard let self else { return }
                self.saveProject(name: currentProjectURL.deletingPathExtension().lastPathComponent,
                                 directory: currentProjectURL.deletingLastPathComponent())
            })
        }
        sheet.addAction(UIAlertAction(title: "Lagre som...", style: .default) { [weak self] _ in
            guard let self else { return }
            self.pickSaveFolder(initialDirectory: self.currentProjectURL?.deletingLastPathComponent() ?? self.projectsDirectory)
        })
        sheet.addAction(UIAlertAction(title: "Lagre til objektbibliotek", style: .default) { [weak self] _ in
            self?.saveSelectedImageToLibrary()
        })
        sheet.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = moreActionsBtn
            pop.sourceRect = moreActionsBtn.bounds
        }
        present(sheet, animated: true)
    }

    private func pickSaveFolder(initialDirectory: URL) {
        let picker = ProjectPickerVC(rootDirectory: initialDirectory, mode: .chooseFolder)
        picker.onSelectFolder = { [weak self] url in
            self?.promptForProjectName(title: "Lagre som", initialName: self?.currentProjectURL?.deletingPathExtension().lastPathComponent, directory: url)
        }
        picker.modalPresentationStyle = UIModalPresentationStyle.popover
        if let pop = picker.popoverPresentationController {
            pop.sourceView = moreActionsBtn
            pop.sourceRect = moreActionsBtn.bounds
            pop.permittedArrowDirections = [UIPopoverArrowDirection.up, .down]
            pop.delegate = picker
        }
        present(picker, animated: true)
    }

    private func promptForProjectName(title: String, initialName: String?, directory: URL) {
        let alert = UIAlertController(title: title, message: directory.path, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "Prosjektnavn"
            tf.autocapitalizationType = .words
            tf.text = initialName
        }
        alert.addAction(UIAlertAction(title: "Lagre", style: .default) { [weak self] _ in
            guard let self,
                  let name = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty else { return }
            self.saveProject(name: name, directory: directory)
        })
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(alert, animated: true)
    }

    private func saveProject(name: String, directory: URL) {
        prepareForSave()
        let pencilData = normalizedPencilDrawingDataForSave()
        guard let data = canvasView.encodeDocument(
            backgroundImage: sourceImage,
            pencilDrawingData: pencilData,
            pencilDrawingNormalizedToImageSpace: pencilData != nil
        ) else { return }
        let safeName = name.replacingOccurrences(of: "/", with: "-")
        let dir = directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gphotoURL = dir.appendingPathComponent("\(safeName).gphoto")
        let pngURL    = dir.appendingPathComponent("\(safeName).png")
        do {
            try data.write(to: gphotoURL)
            currentProjectURL = gphotoURL

            let rendered = renderAnnotatedImage()
            let targetSize = CGSize(width: 1024, height: 1024)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
            let png1024 = UIGraphicsImageRenderer(size: targetSize, format: fmt).image { _ in
                rendered.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            guard let pngData = png1024.pngData() else {
                let ok = UIAlertController(title: "✅ Lagret .gphoto", message: "\"\(name)\" — PNG-konvertering feilet", preferredStyle: .alert)
                ok.addAction(UIAlertAction(title: "OK", style: .default))
                present(ok, animated: true)
                return
            }
            try pngData.write(to: pngURL)
            let verifyW = png1024.cgImage?.width  ?? 0
            let verifyH = png1024.cgImage?.height ?? 0
            let ok = UIAlertController(
                title: "✅ Lagret",
                message: "\"\(name)\"\n\n📦 .gphoto\n🖼 .png (\(verifyW)×\(verifyH) px)",
                preferredStyle: .alert)
            ok.addAction(UIAlertAction(title: "OK", style: .default))
            present(ok, animated: true)
        } catch {
            let err = UIAlertController(title: "Lagringsfeil", message: error.localizedDescription, preferredStyle: .alert)
            err.addAction(UIAlertAction(title: "OK", style: .default))
            present(err, animated: true)
        }
    }

    private func normalizedPencilDrawingDataForSave() -> Data? {
        guard !pencilCanvasView.drawing.strokes.isEmpty,
              let image = sourceImage,
              pencilCanvasView.bounds.width > 0,
              pencilCanvasView.bounds.height > 0 else {
            return nil
        }

        let imageSize = CGSize(width: CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale)),
                               height: CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale)))
        let fit = aspectFitRect(imageSize: imageSize, in: pencilCanvasView.bounds.size)
        guard fit.width > 0.001, fit.height > 0.001 else { return nil }

        let scaleX = imageSize.width / fit.width
        let scaleY = imageSize.height / fit.height
        let transform = CGAffineTransform(
            a: scaleX, b: 0,
            c: 0, d: scaleY,
            tx: -fit.origin.x * scaleX,
            ty: -fit.origin.y * scaleY
        )
        return pencilCanvasView.drawing.transformed(using: transform).dataRepresentation()
    }

    @objc private func loadProjectTapped() {
        print("🟢 DEBUG loadProjectTapped — leter i: \(projectsDirectory.path)")
        let vc = ProjectPickerVC(rootDirectory: projectsDirectory)
        vc.onSelect = { [weak self] url in self?.loadProject(from: url) }
        vc.onDelete = { url in try? FileManager.default.removeItem(at: url) }
        vc.modalPresentationStyle = .popover
        if let pop = vc.popoverPresentationController {
            pop.sourceView = moreActionsBtn
            pop.sourceRect = moreActionsBtn.bounds
            pop.permittedArrowDirections = [.up, .down]
            pop.delegate = vc
        }
        present(vc, animated: true)
    }

    private func loadProject(from url: URL) {
        print("🟣 DEBUG loadProject: \(url.path)")
        guard let data = try? Data(contentsOf: url) else {
            print("🟣 DEBUG loadProject: FEIL - klarte ikke lese filen")
            return
        }
        print("🟣 DEBUG loadProject: leste \(data.count) bytes")
        currentProjectURL = url
        let loaded = canvasView.loadDocument(data)
        if let bgImage = loaded.0 {
            sourceImage = bgImage
            imageView.image = bgImage
            if let drawingData = loaded.1 {
                do {
                    pencilCanvasView.drawing = try PKDrawing(data: drawingData)
                } catch {
                    pencilCanvasView.drawing = PKDrawing()
                }
            } else {
                pencilCanvasView.drawing = PKDrawing()
            }
            updateDrawingInputState()
            print("🟣 DEBUG loadProject: OK - bakgrunnsbilde lastet")
        } else {
            print("🟣 DEBUG loadProject: FEIL - loadDocument returnerte nil")
        }
    }

    @objc private func blankCanvasTapped() {
        let a = UIAlertController(title: "Blankt lerret",
                                   message: "Erstatter bildet med et hvitt 1024×1024 lerret og sletter alle tegninger.",
                                   preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Lag blankt", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let size = CGSize(width: 1024, height: 1024)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1.0
            let blank = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            self.sourceImage = blank
            self.imageView.image = blank
            self.canvasView.clear()
            self.pencilCanvasView.drawing = PKDrawing()
            self.updateDrawingInputState()
        })
        a.addAction(UIAlertAction(title: "Konverter til 1024×1024", style: .default) { [weak self] _ in
            guard let self, let source = self.sourceImage else { return }
            let targetSize = CGSize(width: 1024, height: 1024)
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
            let resized = UIGraphicsImageRenderer(size: targetSize, format: fmt).image { _ in
                source.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            self.sourceImage = resized
            self.imageView.image = resized
        })
        a.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        present(a, animated: true)
    }

    /// Flater ut nåværende bilde + tegninger til én bitmap (samme som
    /// "Lagre"-flyten bruker) og lar brukeren beskjære den. Etter beskjæring
    /// blir den beskjærte bitmapen det nye "sourceImage", og lerretet tømmes
    /// — akkurat som ved "Blankt lerret" — siden gamle tegne-koordinater ikke
    /// lenger stemmer med det nye, mindre bildet.
    @objc private func cropTapped() {
        prepareForSave()
        let flattened = renderAnnotatedImage()
        let cropVC = ImageCropViewController(image: flattened, onCancel: { [weak self] in
            self?.dismiss(animated: true)
        }, onApply: { [weak self] cropped in
            guard let self else { return }
            self.sourceImage = cropped
            self.imageView.image = cropped
            self.canvasView.clear()
            self.pencilCanvasView.drawing = PKDrawing()
            self.updateDrawingInputState()
            self.dismiss(animated: true)
        })
        present(cropVC, animated: true)
    }

    /// Vision-basert bakgrunnsfjerning (samme "Fjern bakgrunn" som lå på
    /// hovedskjermen). Virker på `sourceImage` direkte, ikke det utflatede
    /// bildet — kjører man den etter å ha tegnet noe, blir tegningene stående
    /// som før (kun selve fotoet får gjennomsiktig bakgrunn).
    @objc private func removeBackgroundTapped() {
        guard let img = sourceImage else { return }
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        spinner.startAnimating()
        view.isUserInteractionEnabled = false

        ObjectLibrary.removeBackground(from: img) { [weak self] result in
            guard let self else { return }
            spinner.removeFromSuperview()
            self.view.isUserInteractionEnabled = true
            if let result {
                self.sourceImage = result
                self.imageView.image = result
            }
        }
    }

    @objc private func saveTapped() {
        prepareForSave()
        // TEKNISK GJELD: sjekket tidligere om canvasView.items/PencilKit-strøk
        // var tomme og blokkerte lagring med "Ingen tegninger" hvis så. Det
        // fanget ikke opp endringer som Beskjær/Fjern bakgrunn (de endrer
        // sourceImage direkte, ikke canvasView.items), så lagring ble
        // feilaktig blokkert etter enhver ikke-tegne-endring. Fjernet
        // foreløpig — kan i stedet lagre et duplikat hvis brukeren ikke
        // egentlig endret noe. En mer treffsikker sjekk (sammenlign faktisk
        // bildeinnhold mot originalen) kan legges til senere om det trengs.
        let img = renderAnnotatedImage()
        let save = onSave
        let done = onCancel
        dismiss(animated: true) { save?(img); done?() }
    }

    private func prepareForSave() {
        view.endEditing(true)
        _ = canvasView.finalizeFreehandSession()
        if supportsPencilKitDrawing {
            pencilCanvasView.resignFirstResponder()
        }
    }

    public func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
        if #available(iOS 27.0, *), supportsPencilKitDrawing, !canvasView.selection.isEmpty {
            canvasView.becomeFirstResponder()
        }
    }

    private func renderAnnotatedImage() -> UIImage {
        guard let source = sourceImage else { return UIImage() }
        let imageSize = source.size   // points — used for aspect fit in canvas space
        let canvasSize = canvasView.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return source }

        // Always render at actual pixel dimensions so a 1024×1024 source stays 1024×1024
        let pixelW = CGFloat(source.cgImage?.width  ?? Int(imageSize.width  * source.scale))
        let pixelH = CGFloat(source.cgImage?.height ?? Int(imageSize.height * source.scale))
        let pixelSize = CGSize(width: pixelW, height: pixelH)

        let fit = aspectFitRect(imageSize: imageSize, in: canvasSize)
        let sx = pixelSize.width  / fit.width
        let sy = pixelSize.height / fit.height

        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1.0
        return UIGraphicsImageRenderer(size: pixelSize, format: fmt).image { ctx in
            source.draw(in: CGRect(origin: .zero, size: pixelSize))
            let c = ctx.cgContext
            c.setLineCap(.round); c.setLineJoin(.round)

            if !pencilCanvasView.drawing.strokes.isEmpty {
                let pencilImage = pencilCanvasView.drawing.image(from: pencilCanvasView.bounds, scale: source.scale)
                let pencilRect = CGRect(
                    x: -fit.origin.x * sx,
                    y: -fit.origin.y * sy,
                    width: canvasSize.width * sx,
                    height: canvasSize.height * sy
                )
                pencilImage.draw(in: pencilRect)
            }

            for item in canvasView.items {
                let pts = item.points.map {
                    CGPoint(x: ($0.x - fit.origin.x) * sx, y: ($0.y - fit.origin.y) * sy)
                }
                guard pts.count >= 2 || item.tool == .text else { continue }
                let lw = max(item.lineWidth * sx, imageSize.width / 80.0)

                switch item.tool {
                case .freehand, .paintBackground:
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    var penDown = false
                    for pt in pts {
                        if pt.x.isInfinite { penDown = false; continue }
                        if !penDown { c.move(to: pt); penDown = true } else { c.addLine(to: pt) }
                    }
                    c.strokePath()

                case .highlighter:
                    c.setLineWidth(lw); c.setLineCap(.square); c.setStrokeColor(item.color.cgColor)
                    c.saveGState()
                    c.setAlpha(item.opacity)
                    c.beginTransparencyLayer(auxiliaryInfo: nil)
                    var penDown = false
                    for pt in pts {
                        if pt.x.isInfinite { penDown = false; continue }
                        if !penDown { c.move(to: pt); penDown = true } else { c.addLine(to: pt) }
                    }
                    c.strokePath()
                    c.endTransparencyLayer()
                    c.restoreGState()

                case .circle:
                    let ecr = exportRect(pts)
                    if item.opacity > 0 {
                        c.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
                        c.fillEllipse(in: ecr)
                    }
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    c.strokeEllipse(in: ecr)

                case .line:
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    c.move(to: pts[0]); c.addLine(to: pts[1]); c.strokePath()

                case .arrow:
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    let (s, e) = (pts[0], pts[1])
                    c.move(to: s); c.addLine(to: e); c.strokePath()
                    let ang = atan2(e.y - s.y, e.x - s.x)
                    let hl = max(20, lw * 5), ha: CGFloat = .pi / 6
                    c.move(to: e); c.addLine(to: CGPoint(x: e.x - hl*cos(ang-ha), y: e.y - hl*sin(ang-ha))); c.strokePath()
                    c.move(to: e); c.addLine(to: CGPoint(x: e.x - hl*cos(ang+ha), y: e.y - hl*sin(ang+ha))); c.strokePath()

                case .rectangle:
                    let er = exportRect(pts)
                    let roundedPath: UIBezierPath? = item.cornerRadius > 0 ? UIBezierPath(roundedRect: er, cornerRadius: item.cornerRadius * sx) : nil
                    if item.opacity > 0 {
                        c.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
                        if let roundedPath { c.addPath(roundedPath.cgPath); c.fillPath() } else { c.fill(er) }
                    }
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    if let roundedPath { c.addPath(roundedPath.cgPath); c.strokePath() } else { c.stroke(er) }

                case .number:
                    let r = exportRect(pts)
                    c.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor); c.fillEllipse(in: r)
                    let side = min(r.width, r.height)
                    let fontSize = max(side * 0.55, 20)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: fontSize), .foregroundColor: UIColor.black
                    ]
                    let str = "\(item.number)" as NSString
                    let ts = str.size(withAttributes: attrs)
                    str.draw(in: CGRect(x: r.midX - ts.width/2, y: r.midY - ts.height/2,
                                        width: ts.width, height: ts.height), withAttributes: attrs)

                case .text:
                    guard !item.text.isEmpty else { continue }
                    let imagePt = CGPoint(
                        x: (item.points[0].x - fit.origin.x) * sx,
                        y: (item.points[0].y - fit.origin.y) * sy)
                    let scaledSize = max(item.fontSize * sx, 8)
                    let font = resolveFont(name: item.fontName, size: scaledSize)
                    let attrs = wrappedTextAttributes(font: font, color: item.color)
                    let boxWidth = max(80, (item.textWidth ?? (min(canvasSize.width * 0.6, 420))) * sx)
                    let textRect = wrappedTextBounds(text: item.text, maxWidth: boxWidth, attributes: attrs)
                    item.text.draw(in: CGRect(x: imagePt.x, y: imagePt.y, width: boxWidth, height: textRect.height),
                                   withAttributes: attrs)

                case .image:
                    guard let img = item.overlayImage, pts.count >= 2 else { continue }
                    img.draw(in: exportRect(pts))

                case .polygon:
                    guard pts.count >= 2 else { continue }
                    let verts = polygonVertices(in: exportRect(pts), sides: item.sides, isStar: item.isStar)
                    guard let first = verts.first else { continue }
                    let path = UIBezierPath()
                    path.move(to: first)
                    for v in verts.dropFirst() { path.addLine(to: v) }
                    path.close()
                    if item.opacity > 0 {
                        c.addPath(path.cgPath)
                        c.setFillColor(item.color.withAlphaComponent(item.opacity).cgColor)
                        c.fillPath()
                    }
                    c.addPath(path.cgPath)
                    c.setLineWidth(lw); c.setStrokeColor(item.color.cgColor)
                    c.strokePath()

                case .select:
                    break
                }
            }
        }
    }

    private func aspectFitRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        let ia = imageSize.width / imageSize.height
        let va = viewSize.width  / viewSize.height
        var r = CGRect.zero
        if ia > va {
            r.size.width  = viewSize.width
            r.size.height = viewSize.width / ia
            r.origin.y    = (viewSize.height - r.size.height) / 2
        } else {
            r.size.height = viewSize.height
            r.size.width  = viewSize.height * ia
            r.origin.x    = (viewSize.width - r.size.width) / 2
        }
        return r
    }

    private func exportRect(_ pts: [CGPoint]) -> CGRect {
        CGRect(x: min(pts[0].x, pts[1].x), y: min(pts[0].y, pts[1].y),
               width: abs(pts[1].x - pts[0].x), height: abs(pts[1].y - pts[0].y))
    }

}

// MARK: - Mac Catalyst icon-only context menu popover

#if targetEnvironment(macCatalyst)
private final class MacContextMenuVC: UIViewController, UIPopoverPresentationControllerDelegate {
    struct Action {
        let symbol: String
        let destructive: Bool
        let handler: () -> Void
    }

    private let actions: [Action]

    init(actions: [Action]) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        let size: CGFloat = 48
        let gap: CGFloat  = 6
        let pad: CGFloat  = 10
        let totalW = pad * 2 + CGFloat(actions.count) * size + CGFloat(actions.count - 1) * gap
        preferredContentSize = CGSize(width: totalW, height: pad * 2 + size)

        for (i, action) in actions.enumerated() {
            let btn = UIButton(type: .system)
            let cfg = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            btn.setImage(UIImage(systemName: action.symbol, withConfiguration: cfg), for: .normal)
            btn.tintColor = action.destructive ? .systemRed : .label
            btn.backgroundColor = action.destructive
                ? UIColor.systemRed.withAlphaComponent(0.08)
                : UIColor.secondarySystemFill
            btn.layer.cornerRadius = 10
            btn.frame = CGRect(
                x: pad + CGFloat(i) * (size + gap),
                y: pad,
                width: size, height: size
            )
            btn.tag = i
            btn.addTarget(self, action: #selector(tapped(_:)), for: .touchUpInside)
            view.addSubview(btn)
        }
    }

    @objc private func tapped(_ sender: UIButton) {
        guard sender.tag < actions.count else { return }
        let handler = actions[sender.tag].handler
        dismiss(animated: true) { handler() }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}
#endif

// MARK: - Mac Catalyst vertical action-list popover (erstatning for
// UIAlertController(.actionSheet), som Mac Catalyst rendrer horisontalt)

#if targetEnvironment(macCatalyst)
private final class MacActionListVC: UIViewController, UIPopoverPresentationControllerDelegate {
    struct Action {
        let symbol: String?
        let title: String
        let destructive: Bool
        let handler: () -> Void
    }

    private let actions: [Action]
    private let cancelTitle: String?
    private let rowHeight: CGFloat = 44
    private let width: CGFloat = 240

    init(actions: [Action], cancelTitle: String?) {
        self.actions = actions
        self.cancelTitle = cancelTitle
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        for (i, action) in actions.enumerated() {
            stack.addArrangedSubview(makeRow(title: action.title, symbol: action.symbol,
                                              destructive: action.destructive, tag: i))
        }

        var totalHeight = CGFloat(actions.count) * rowHeight
        if let cancelTitle {
            stack.addArrangedSubview(makeSeparator())
            stack.addArrangedSubview(makeRow(title: cancelTitle, symbol: nil, destructive: false,
                                              tag: actions.count, isCancel: true))
            totalHeight += 1 + rowHeight
        }
        preferredContentSize = CGSize(width: width, height: totalHeight)
    }

    /// Bruker manuell layout (UIImageView/UILabel + constraints) i stedet for
    /// UIButton.Configuration.contentInsets — på Mac Catalyst blir Configuration-
    /// insets ignorert når contentHorizontalAlignment settes manuelt, så
    /// venstre-paddingen forsvant helt. Samme grunn til at MacContextMenuVC
    /// over legger ut knappene sine med .frame i stedet for Configuration.
    ///
    /// Selve knappen må likevel lages med en tom .plain()-configuration, ikke
    /// UIButton(type: .system) — på Mac Catalyst tegner .system en native
    /// grå bezel-bakgrunn som backgroundColor ikke klarer å overstyre.
    private func makeRow(title: String, symbol: String?, destructive: Bool, tag: Int,
                          isCancel: Bool = false) -> UIButton {
        var cfg = UIButton.Configuration.plain()
        cfg.background.backgroundColor = .clear
        let btn = UIButton(configuration: cfg)
        btn.tag = tag
        btn.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
        btn.addTarget(self, action: #selector(rowTapped(_:)), for: .touchUpInside)

        let label = UILabel()
        label.text = title
        label.font = isCancel ? .boldSystemFont(ofSize: 17) : .systemFont(ofSize: 17)
        label.textColor = destructive ? .systemRed : .label
        label.isUserInteractionEnabled = false

        let content = UIStackView()
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 12
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false

        if !isCancel, let symbol {
            let imageView = UIImageView(image: UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)))
            imageView.contentMode = .scaleAspectFit
            imageView.tintColor = destructive ? .systemRed : .systemBlue
            imageView.widthAnchor.constraint(equalToConstant: 22).isActive = true
            content.addArrangedSubview(imageView)
        }
        content.addArrangedSubview(label)

        btn.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: btn.centerYAnchor),
            content.trailingAnchor.constraint(lessThanOrEqualTo: btn.trailingAnchor, constant: -16),
        ])
        if isCancel {
            content.centerXAnchor.constraint(equalTo: btn.centerXAnchor).isActive = true
        } else {
            content.leadingAnchor.constraint(equalTo: btn.leadingAnchor, constant: 20).isActive = true
        }
        return btn
    }

    private func makeSeparator() -> UIView {
        let v = UIView()
        v.backgroundColor = .separator
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    @objc private func rowTapped(_ sender: UIButton) {
        guard sender.tag < actions.count else {
            dismiss(animated: true)
            return
        }
        let handler = actions[sender.tag].handler
        dismiss(animated: true) { handler() }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}
#endif

// MARK: - Text style picker popover

private final class TextStylePickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate, UIPopoverPresentationControllerDelegate {
    private let fonts: [(display: String, name: String)]
    private let initialFontName: String
    private let initialFontSize: CGFloat
    private let onApply: (String, CGFloat, UIColor?) -> Void

    private let tableView = UITableView(frame: .zero, style: .plain)
    private let slider = UISlider()
    private let sizeLabel = UILabel()
    private let backgroundColorWell = UIColorWell()
    private let removeBackgroundBtn = UIButton(type: .system)
    private var selectedRow = 0
    private var currentSize: CGFloat

    init(fonts: [(display: String, name: String)],
         initialFontName: String,
         initialFontSize: CGFloat,
         initialBackgroundColor: UIColor?,
         onApply: @escaping (String, CGFloat, UIColor?) -> Void) {
        self.fonts = fonts
        self.initialFontName = initialFontName
        self.initialFontSize = initialFontSize
        self.onApply = onApply
        self.currentSize = initialFontSize
        super.init(nibName: nil, bundle: nil)
        self.selectedRow = fonts.firstIndex(where: { $0.name == initialFontName }) ?? 0
        self.backgroundColorWell.selectedColor = initialBackgroundColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Tekststil"
        preferredContentSize = CGSize(width: 360, height: 560)

        let titleLabel = UILabel()
        titleLabel.text = "Velg font og størrelse"
        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "font")
        tableView.layer.cornerRadius = 10
        tableView.clipsToBounds = true
        tableView.rowHeight = 44
        tableView.translatesAutoresizingMaskIntoConstraints = false

        slider.minimumValue = 8
        slider.maximumValue = 1000
        slider.value = Float(currentSize)
        slider.addTarget(self, action: #selector(sliderChanged), for: .valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false

        sizeLabel.text = "\(Int(currentSize))"
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
        sizeLabel.textAlignment = .center
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = UIButton(type: .system)
        cancelBtn.setTitle("Avbryt", for: .normal)
        cancelBtn.titleLabel?.font = .systemFont(ofSize: 17)
        cancelBtn.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)

        let applyBtn = UIButton(type: .system)
        applyBtn.setTitle("Lagre", for: .normal)
        applyBtn.titleLabel?.font = .boldSystemFont(ofSize: 17)
        applyBtn.backgroundColor = .systemBlue
        applyBtn.setTitleColor(.white, for: .normal)
        applyBtn.layer.cornerRadius = 10
        applyBtn.addTarget(self, action: #selector(applyTapped), for: .touchUpInside)

        let buttonStack = UIStackView(arrangedSubviews: [cancelBtn, applyBtn])
        buttonStack.axis = .horizontal
        buttonStack.spacing = 12
        buttonStack.distribution = .fillEqually
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let sizeHeaderStack = UIStackView(arrangedSubviews: [UILabel(), sizeLabel])
        sizeHeaderStack.axis = .horizontal
        sizeHeaderStack.translatesAutoresizingMaskIntoConstraints = false
        if let left = sizeHeaderStack.arrangedSubviews.first as? UILabel {
            left.text = "Størrelse"
            left.font = .systemFont(ofSize: 13, weight: .semibold)
            left.textColor = .secondaryLabel
        }
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)

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

        let contentStack = UIStackView(arrangedSubviews: [titleLabel, tableView, sizeHeaderStack, slider, bgRowStack, buttonStack])
        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            tableView.heightAnchor.constraint(equalToConstant: 260),
            slider.heightAnchor.constraint(equalToConstant: 44),
        ])

        tableView.selectRow(at: IndexPath(row: selectedRow, section: 0), animated: false, scrollPosition: .middle)
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { fonts.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "font", for: indexPath)
        let font = fonts[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = font.display
        cfg.textProperties.font = resolveFont(name: font.name, size: 16)
        cell.contentConfiguration = cfg
        cell.accessoryType = indexPath.row == selectedRow ? .checkmark : .none
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        selectedRow = indexPath.row
        tableView.reloadData()
    }

    @objc private func sliderChanged() {
        currentSize = CGFloat(slider.value)
        sizeLabel.text = "\(Int(currentSize))"
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func removeBackgroundTapped() {
        backgroundColorWell.selectedColor = nil
    }

    @objc private func applyTapped() {
        let fontName = fonts[selectedRow].name
        let fontSize = currentSize
        let bgColor = backgroundColorWell.selectedColor
        dismiss(animated: true) { [onApply] in
            onApply(fontName, fontSize, bgColor)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

// MARK: - Tool picker popover

private final class ToolPickerPopoverVC: UIViewController, UIPopoverPresentationControllerDelegate {
    private let symbols: [String]
    private let activeIndex: Int
    var onSelect: ((Int) -> Void)?

    init(symbols: [String], currentIndex: Int) {
        self.symbols = symbols
        self.activeIndex = currentIndex
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        let columns = 5
        let btnSize: CGFloat = 54
        let pad: CGFloat = 8
        let rows = Int(ceil(Double(symbols.count) / Double(columns)))
        let totalW = CGFloat(columns) * btnSize + CGFloat(columns + 1) * pad
        let totalH = CGFloat(rows) * btnSize + CGFloat(rows + 1) * pad
        preferredContentSize = CGSize(width: totalW, height: totalH)

        for (i, symbol) in symbols.enumerated() {
            let col = i % columns
            let row = i / columns
            let isActive = i == activeIndex
            let btn = UIButton(type: .system)
            let cfg = UIImage.SymbolConfiguration(pointSize: 24, weight: .medium)
            btn.setImage(UIImage(systemName: symbol, withConfiguration: cfg), for: .normal)
            btn.tintColor = isActive ? .systemYellow : .label
            btn.backgroundColor = isActive ? UIColor.systemYellow.withAlphaComponent(0.18) : .clear
            btn.layer.cornerRadius = 10
            btn.frame = CGRect(
                x: pad + CGFloat(col) * (btnSize + pad),
                y: pad + CGFloat(row) * (btnSize + pad),
                width: btnSize,
                height: btnSize
            )
            btn.tag = i
            btn.addTarget(self, action: #selector(btnTapped(_:)), for: .touchUpInside)
            view.addSubview(btn)
        }
    }

    @objc private func btnTapped(_ sender: UIButton) {
        dismiss(animated: true) { [weak self] in
            self?.onSelect?(sender.tag)
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}

// MARK: - Slider picker popover

private final class SliderPickerPopoverVC: UIViewController, UIPopoverPresentationControllerDelegate {
    private let title_: String
    private let minValue: Float
    private let maxValue: Float
    private let initialValue: Float
    private let format: (Float) -> String
    var onChange: ((CGFloat) -> Void)?

    private let valueLbl = UILabel()

    init(title: String, min: Float, max: Float, value: Float, format: @escaping (Float) -> String) {
        self.title_ = title
        self.minValue = min
        self.maxValue = max
        self.initialValue = value
        self.format = format
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        valueLbl.text = format(initialValue)
        valueLbl.font = UIFont.monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        valueLbl.textAlignment = .center

        let slider = TrackSlider()
        slider.minValue = minValue
        slider.maxValue = maxValue
        slider.value = initialValue
        slider.onValueChanged = { [weak self] v in
            guard let self else { return }
            self.valueLbl.text = self.format(v)
            self.onChange?(CGFloat(v))
        }

        [valueLbl, slider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        NSLayoutConstraint.activate([
            valueLbl.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            valueLbl.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            valueLbl.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            slider.topAnchor.constraint(equalTo: valueLbl.bottomAnchor, constant: 8),
            slider.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            slider.heightAnchor.constraint(equalToConstant: 44),
            slider.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])

        preferredContentSize = CGSize(width: 260, height: 100)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}

// MARK: - Mac Catalyst color well (wraps UIColorWell → opens native NSColorPanel)

#if targetEnvironment(macCatalyst)
private final class MacColorWellVC: UIViewController, UIPopoverPresentationControllerDelegate {
    private let well = UIColorWell()
    var onColorChanged: ((UIColor) -> Void)?

    init(initialColor: UIColor) {
        super.init(nibName: nil, bundle: nil)
        well.selectedColor = initialColor
        well.supportsAlpha = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        preferredContentSize = CGSize(width: 160, height: 90)

        let lbl = UILabel()
        lbl.text = "Klikk for fargevelger"
        lbl.font = .systemFont(ofSize: 12)
        lbl.textColor = .secondaryLabel
        lbl.textAlignment = .center

        well.addTarget(self, action: #selector(wellChanged), for: .valueChanged)

        [lbl, well].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        NSLayoutConstraint.activate([
            lbl.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            lbl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            well.topAnchor.constraint(equalTo: lbl.bottomAnchor, constant: 10),
            well.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            well.widthAnchor.constraint(equalToConstant: 44),
            well.heightAnchor.constraint(equalToConstant: 32),
            well.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
        ])
    }

    @objc private func wellChanged() {
        guard let color = well.selectedColor else { return }
        onColorChanged?(color)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}
#endif

// MARK: - Custom track slider (avoids UISlider's private CoreHaptics symbols)

private final class TrackSlider: UIView {
    var minValue: Float = 0
    var maxValue: Float = 1
    var value: Float = 0.5 { didSet { setNeedsDisplay() } }
    var onValueChanged: ((Float) -> Void)?

    private let trackH: CGFloat = 5
    private let thumbR: CGFloat = 13
    private let pad: CGFloat = 16

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let y = bounds.midY
        let left = pad + thumbR
        let right = bounds.width - pad - thumbR
        let trackW = right - left
        let fraction = CGFloat((value - minValue) / max(maxValue - minValue, 1e-6))
        let thumbX = left + trackW * fraction

        // Background track
        let bgPath = UIBezierPath(roundedRect: CGRect(x: left, y: y - trackH/2, width: trackW, height: trackH),
                                  cornerRadius: trackH/2)
        UIColor.systemFill.setFill(); bgPath.fill()

        // Filled track
        if thumbX > left {
            let fillPath = UIBezierPath(roundedRect: CGRect(x: left, y: y - trackH/2, width: thumbX - left, height: trackH),
                                        cornerRadius: trackH/2)
            UIColor.systemBlue.setFill(); fillPath.fill()
        }

        // Thumb shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 5,
                      color: UIColor.black.withAlphaComponent(0.25).cgColor)
        UIColor.white.setFill()
        UIBezierPath(ovalIn: CGRect(x: thumbX - thumbR, y: y - thumbR, width: thumbR*2, height: thumbR*2)).fill()
        ctx.restoreGState()
    }

    @objc private func handleGesture(_ g: UIGestureRecognizer) {
        let x = g.location(in: self).x
        let left = pad + thumbR
        let right = bounds.width - pad - thumbR
        let fraction = Float((x - left) / (right - left))
        value = minValue + max(0, min(1, fraction)) * (maxValue - minValue)
        onValueChanged?(value)
    }
}

// MARK: - Color picker popover

private final class ColorPickerPopoverVC: UIViewController, UIPopoverPresentationControllerDelegate {
    private let colors: [UIColor]
    private let activeColor: UIColor
    var onSelect: ((UIColor) -> Void)?
    var onOpenFullPicker: (() -> Void)?

    init(colors: [UIColor], activeColor: UIColor) {
        self.colors = colors
        self.activeColor = activeColor
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        let columns = 4
        let size: CGFloat = 46
        let gap: CGFloat = 10
        let pad: CGFloat = 12
        // +1 for the rainbow/full-picker button — fills the grid to 4×2
        let totalItems = colors.count + 1
        let rows = Int(ceil(Double(totalItems) / Double(columns)))
        let totalW = pad * 2 + CGFloat(columns) * size + CGFloat(columns - 1) * gap
        let totalH = pad * 2 + CGFloat(rows) * size + CGFloat(rows - 1) * gap
        preferredContentSize = CGSize(width: totalW, height: totalH)

        for (i, color) in colors.enumerated() {
            view.addSubview(makeColorBtn(color: color, index: i,
                                        columns: columns, size: size, gap: gap, pad: pad,
                                        totalItems: totalItems))
        }

        // Rainbow button — opens full system color picker
        let rainbowBtn = makeRainbowBtn(index: colors.count,
                                        columns: columns, size: size, gap: gap, pad: pad)
        rainbowBtn.addTarget(self, action: #selector(rainbowTapped), for: .touchUpInside)
        view.addSubview(rainbowBtn)
    }

    private func makeColorBtn(color: UIColor, index: Int,
                               columns: Int, size: CGFloat, gap: CGFloat, pad: CGFloat,
                               totalItems: Int) -> UIButton {
        let col = index % columns
        let row = index / columns
        let itemsInRow = min(columns, totalItems - row * columns)
        let rowOffset = itemsInRow < columns ? CGFloat(columns - itemsInRow) * (size + gap) / 2 : 0

        let btn = UIButton(type: .custom)
        btn.backgroundColor = color
        btn.layer.cornerRadius = size / 2
        btn.layer.masksToBounds = false
        btn.layer.shadowColor = UIColor.black.withAlphaComponent(0.2).cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 3; btn.layer.shadowOpacity = 1

        if color == .white {
            btn.layer.borderWidth = 1
            btn.layer.borderColor = UIColor.systemGray4.cgColor
        }
        let isActive = color.cgColor == activeColor.cgColor
        if isActive {
            let checkColor: UIColor = (color == .white || color == .systemYellow) ? .black : .white
            let iv = UIImageView(image: UIImage(systemName: "checkmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)))
            iv.tintColor = checkColor
            iv.contentMode = .scaleAspectFit
            iv.frame = CGRect(x: 8, y: 8, width: size - 16, height: size - 16)
            btn.addSubview(iv)
        }
        btn.frame = CGRect(x: pad + rowOffset + CGFloat(col) * (size + gap),
                           y: pad + CGFloat(row) * (size + gap),
                           width: size, height: size)
        btn.tag = index
        btn.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
        return btn
    }

    private func makeRainbowBtn(index: Int, columns: Int,
                                 size: CGFloat, gap: CGFloat, pad: CGFloat) -> UIButton {
        let col = index % columns
        let row = index / columns
        let btn = UIButton(type: .custom)
        btn.layer.cornerRadius = size / 2
        btn.layer.masksToBounds = false
        btn.layer.shadowColor = UIColor.black.withAlphaComponent(0.2).cgColor
        btn.layer.shadowOffset = CGSize(width: 0, height: 2)
        btn.layer.shadowRadius = 3; btn.layer.shadowOpacity = 1

        // Conic gradient clipped to circle
        let clip = UIView(frame: CGRect(origin: .zero, size: CGSize(width: size, height: size)))
        clip.layer.cornerRadius = size / 2
        clip.layer.masksToBounds = true
        clip.isUserInteractionEnabled = false
        let grad = CAGradientLayer()
        grad.type = .conic
        grad.colors = [UIColor.red, UIColor.orange, UIColor.yellow, UIColor.green,
                       UIColor.cyan, UIColor.blue, UIColor.magenta, UIColor.red]
            .map { $0.cgColor }
        grad.startPoint = CGPoint(x: 0.5, y: 0.5)
        grad.endPoint   = CGPoint(x: 1.0, y: 0.5)
        grad.frame = CGRect(origin: .zero, size: CGSize(width: size, height: size))
        clip.layer.addSublayer(grad)
        btn.addSubview(clip)

        btn.frame = CGRect(x: pad + CGFloat(col) * (size + gap),
                           y: pad + CGFloat(row) * (size + gap),
                           width: size, height: size)
        btn.tag = 999
        return btn
    }

    @objc private func colorTapped(_ sender: UIButton) {
        guard sender.tag < colors.count else { return }
        let color = colors[sender.tag]
        dismiss(animated: true) { [weak self] in self?.onSelect?(color) }
    }

    @objc private func rainbowTapped() {
        dismiss(animated: true) { [weak self] in self?.onOpenFullPicker?() }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }
}

// MARK: - Project picker popover

private final class ProjectPickerVC: UIViewController, UITableViewDataSource, UITableViewDelegate,
                                     UITableViewDragDelegate, UITableViewDropDelegate,
                                     UIPopoverPresentationControllerDelegate {
    enum Mode {
        case openProject
        case chooseFolder
    }

    private enum Entry {
        case up(URL)
        case folder(URL)
        case project(URL)

        var url: URL {
            switch self {
            case .up(let url), .folder(let url), .project(let url):
                return url
            }
        }

        var title: String {
            switch self {
            case .up:
                return "Opp"
            case .folder(let url):
                return url.lastPathComponent
            case .project(let url):
                return url.deletingPathExtension().lastPathComponent
            }
        }

        var iconName: String {
            switch self {
            case .up:
                return "arrow.up"
            case .folder:
                return "folder"
            case .project:
                return "doc.fill"
            }
        }

        var isDeletable: Bool {
            if case .project = self { return true }
            return false
        }
    }

    private let rootDirectory: URL
    private let mode: Mode
    private var currentDirectory: URL
    private var entries: [Entry] = []
    var onSelect: ((URL) -> Void)?
    var onSelectFolder: ((URL) -> Void)?
    var onDelete: ((URL) -> Void)?

    private let chooseFolderButton = UIButton(type: .system)
    private let pathLabel = UILabel()
    private let tableView = UITableView(frame: .zero, style: .plain)

    init(rootDirectory: URL, mode: Mode = .openProject) {
        self.rootDirectory = rootDirectory
        self.mode = mode
        self.currentDirectory = rootDirectory
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground

        chooseFolderButton.setTitle("Velg denne mappen", for: .normal)
        chooseFolderButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        chooseFolderButton.addTarget(self, action: #selector(chooseFolderTapped), for: .touchUpInside)
        chooseFolderButton.translatesAutoresizingMaskIntoConstraints = false
        chooseFolderButton.isHidden = mode != .chooseFolder

        pathLabel.numberOfLines = 2
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabel
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        tableView.translatesAutoresizingMaskIntoConstraints = false

        let arrangedSubviews: [UIView] = mode == .chooseFolder ? [chooseFolderButton, pathLabel, tableView] : [pathLabel, tableView]
        let stack = UIStackView(arrangedSubviews: arrangedSubviews)
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tableView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        refreshEntries()
    }

    @objc private func chooseFolderTapped() {
        let url = currentDirectory
        dismiss(animated: true) { [weak self] in
            self?.onSelectFolder?(url)
        }
    }

    private func refreshEntries() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: currentDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var folderURLs: [URL] = []
        var projectURLs: [URL] = []

        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folderURLs.append(url)
            } else if url.pathExtension.lowercased() == "gphoto" {
                projectURLs.append(url)
            }
        }

        folderURLs.sort {
            $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending
        }
        projectURLs.sort {
            $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveCompare($1.deletingPathExtension().lastPathComponent) == .orderedAscending
        }

        entries = []
        if currentDirectory != rootDirectory {
            entries.append(.up(currentDirectory.deletingLastPathComponent()))
        }
        entries.append(contentsOf: folderURLs.map { .folder($0) })
        if mode == .openProject {
            entries.append(contentsOf: projectURLs.map { .project($0) })
        }

        pathLabel.text = displayPath()
        updatePreferredSize()
        tableView.reloadData()
    }

    private func displayPath() -> String {
        if currentDirectory == rootDirectory {
            return rootDirectory.lastPathComponent.isEmpty ? "Prosjekter" : rootDirectory.lastPathComponent
        }
        let relative = currentDirectory.path.replacingOccurrences(of: rootDirectory.path, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return relative.isEmpty ? currentDirectory.lastPathComponent : relative
    }

    private func updatePreferredSize() {
        let extraRows = mode == .chooseFolder ? 1 : 0
        preferredContentSize = CGSize(width: 340, height: min(CGFloat(max(entries.count + extraRows, 1)) * 52 + 80, 460))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { entries.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "c", for: indexPath)
        let entry = entries[indexPath.row]
        var cfg = cell.defaultContentConfiguration()
        cfg.text = entry.title
        cfg.image = UIImage(systemName: entry.iconName)
        cell.contentConfiguration = cfg
        cell.accessoryType = entry.isDeletable ? .none : .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 52 }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        entries[indexPath.row].isDeletable
    }

    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at indexPath: IndexPath) -> [UIDragItem] {
        dragItems(for: indexPath)
    }

    func tableView(_ tableView: UITableView, itemsForAddingTo session: UIDragSession, at indexPath: IndexPath, point: CGPoint) -> [UIDragItem] {
        dragItems(for: indexPath)
    }

    func tableView(_ tableView: UITableView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func tableView(_ tableView: UITableView,
                   dropSessionDidUpdate session: UIDropSession,
                   withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        guard session.localDragSession != nil,
              let destinationIndexPath,
              case .folder = entries[destinationIndexPath.row] else {
            return UITableViewDropProposal(operation: .forbidden)
        }
        return UITableViewDropProposal(operation: .move, intent: .insertIntoDestinationIndexPath)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let destinationIndexPath = coordinator.destinationIndexPath,
              case .folder(let destinationFolderURL) = entries[destinationIndexPath.row] else { return }
        var movedAny = false
        for item in coordinator.items {
            guard let sourceURL = item.dragItem.localObject as? URL else { continue }
            do {
                try moveEntry(from: sourceURL, into: destinationFolderURL)
                movedAny = true
            } catch {
                let alert = UIAlertController(title: "Kunne ikke flytte",
                                              message: error.localizedDescription,
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(alert, animated: true)
            }
        }
        if movedAny {
            refreshEntries()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch entries[indexPath.row] {
        case .up(let url), .folder(let url):
            currentDirectory = url
            refreshEntries()
        case .project(let url):
            guard mode == .openProject else { return }
            dismiss(animated: true) { [weak self] in self?.onSelect?(url) }
        }
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
                   forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        deleteEntry(at: indexPath)
    }

    func tableView(_ tableView: UITableView,
                   contextMenuConfigurationForRowAt indexPath: IndexPath,
                   point: CGPoint) -> UIContextMenuConfiguration? {
        let entry = entries[indexPath.row]
        if case .up = entry { return nil }
        let title = entry.title
        let url: URL
        switch entry {
        case .folder(let folderURL):
            url = folderURL
        case .project(let projectURL):
            url = projectURL
        case .up:
            return nil
        }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let openTitle = entry.isDeletable ? "Åpne i Filer" : "Åpne i Filer"
            let renameAction = UIAction(title: "Gi nytt navn", image: UIImage(systemName: "pencil")) { _ in
                self.renameEntry(at: indexPath)
            }
            let openAction = UIAction(title: openTitle, image: UIImage(systemName: "folder")) { _ in
                self.openInFiles(url)
            }
            let deleteAction = UIAction(title: "Slett", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                self.deleteEntry(at: indexPath)
            }
            return UIMenu(title: title, children: [openAction, renameAction, deleteAction])
        }
    }

    private func openInFiles(_ url: URL) {
        let folderURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.directoryURL = folderURL
        picker.modalPresentationStyle = .formSheet
        present(picker, animated: true)
    }

    private func dragItems(for indexPath: IndexPath) -> [UIDragItem] {
        let entry = entries[indexPath.row]
        let sourceURL: URL
        switch entry {
        case .folder(let folderURL), .project(let folderURL):
            sourceURL = folderURL
        case .up:
            return []
        }

        let item = UIDragItem(itemProvider: NSItemProvider(object: sourceURL as NSURL))
        item.localObject = sourceURL
        return [item]
    }

    private func moveEntry(from sourceURL: URL, into destinationFolderURL: URL) throws {
        let sourceStandard = sourceURL.standardizedFileURL
        let destinationStandard = destinationFolderURL.standardizedFileURL
        guard sourceStandard != destinationStandard else { return }
        guard !destinationStandard.path.hasPrefix(sourceStandard.path + "/") else { return }

        if sourceURL.hasDirectoryPath {
            let targetURL = destinationFolderURL.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                throw CocoaError(.fileWriteFileExists)
            }
            try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            if currentDirectory.standardizedFileURL == sourceStandard {
                currentDirectory = targetURL
            }
            return
        }

        guard sourceURL.pathExtension.lowercased() == "gphoto" else { return }
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let sourceFolder = sourceURL.deletingLastPathComponent()
        let targetProjectURL = destinationFolderURL.appendingPathComponent("\(baseName).gphoto")
        let sourcePNGURL = sourceFolder.appendingPathComponent("\(baseName).png")
        let targetPNGURL = destinationFolderURL.appendingPathComponent("\(baseName).png")

        if FileManager.default.fileExists(atPath: targetProjectURL.path) {
            throw CocoaError(.fileWriteFileExists)
        }
        if FileManager.default.fileExists(atPath: sourcePNGURL.path), FileManager.default.fileExists(atPath: targetPNGURL.path) {
            throw CocoaError(.fileWriteFileExists)
        }

        try FileManager.default.moveItem(at: sourceURL, to: targetProjectURL)
        if FileManager.default.fileExists(atPath: sourcePNGURL.path) {
            try FileManager.default.moveItem(at: sourcePNGURL, to: targetPNGURL)
        }
    }

    private func renameEntry(at indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        let currentURL: URL
        let currentName: String
        let fileExtension: String?

        switch entry {
        case .folder(let folderURL):
            currentURL = folderURL
            currentName = folderURL.lastPathComponent
            fileExtension = nil
        case .project(let projectURL):
            currentURL = projectURL
            currentName = projectURL.deletingPathExtension().lastPathComponent
            fileExtension = projectURL.pathExtension
        case .up:
            return
        }

        let alert = UIAlertController(title: "Gi nytt navn", message: currentURL.path, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.text = currentName
            tf.autocapitalizationType = .words
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lagre", style: .default) { [weak self] _ in
            guard let self,
                  let rawName = alert.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawName.isEmpty else { return }
            let safeName = rawName.replacingOccurrences(of: "/", with: "-")
            let newURL: URL
            if let fileExtension, !fileExtension.isEmpty {
                newURL = currentURL.deletingLastPathComponent().appendingPathComponent("\(safeName).\(fileExtension)")
            } else {
                newURL = currentURL.deletingLastPathComponent().appendingPathComponent(safeName)
            }
            guard newURL != currentURL else { return }
            do {
                try FileManager.default.moveItem(at: currentURL, to: newURL)
                if self.currentDirectory == currentURL {
                    self.currentDirectory = newURL
                }
                self.refreshEntries()
            } catch {
                let err = UIAlertController(title: "Kunne ikke gi nytt navn",
                                             message: error.localizedDescription,
                                             preferredStyle: .alert)
                err.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(err, animated: true)
            }
        })
        present(alert, animated: true)
    }

    private func deleteEntry(at indexPath: IndexPath) {
        let entry = entries[indexPath.row]
        let url: URL
        switch entry {
        case .folder(let folderURL), .project(let folderURL):
            url = folderURL
        case .up:
            return
        }

        let alert = UIAlertController(title: "Slette?", message: url.path, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Avbryt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Slett", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try FileManager.default.removeItem(at: url)
                self.refreshEntries()
            } catch {
                let err = UIAlertController(title: "Kunne ikke slette",
                                             message: error.localizedDescription,
                                             preferredStyle: .alert)
                err.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(err, animated: true)
            }
        })
        present(alert, animated: true)
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

extension ImageAnnotationViewController: UIPopoverPresentationControllerDelegate {
    public func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle { .none }
}

extension ImageAnnotationViewController: UIColorPickerViewControllerDelegate {
    public func colorPickerViewController(_ picker: UIColorPickerViewController,
                                          didSelect color: UIColor, continuously: Bool) {
        applyColor(color)
    }
}

extension ImageAnnotationViewController: UIDropInteractionDelegate {
    public func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.canLoadObjects(ofClass: UIImage.self)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    public func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        session.loadObjects(ofClass: UIImage.self) { [weak self] items in
            guard let self else { return }
            for case let droppedImage as UIImage in items {
                self.insertImageIntoCanvas(droppedImage)
            }
        }
    }
}

extension ImageAnnotationViewController: UIContextMenuInteractionDelegate {
    public func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                       configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        let toolIndex = interaction.view?.tag ?? -1
        let contextTool = (toolIndex >= 0 && toolIndex < toolMap.count) ? toolMap[toolIndex] : canvasView.currentTool
        let isOpacity = [AnnotationTool.number, .highlighter].contains(contextTool)
        let src = interaction.view
        let icon  = isOpacity ? "circle.lefthalf.filled" : "lineweight"
        let action = UIAction(title: "", image: UIImage(systemName: icon)) { [weak self] _ in
            self?.showCurrentToolSlider(isOpacity: isOpacity, from: src)
        }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(title: "", children: [action])
        }
    }
}

#if !targetEnvironment(macCatalyst)
@available(iOS 16.0, *)
extension ImageAnnotationViewController: UIEditMenuInteractionDelegate {
    public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                    menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let itemIndex = pendingCanvasMenuItemIndex,
              let actions = canvasMenuElements(for: itemIndex) else { return nil }
        return UIMenu(title: "", options: [], preferredElementSize: .small, children: actions)
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                    targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        CGRect(x: pendingCanvasMenuLocation.x, y: pendingCanvasMenuLocation.y, width: 1, height: 1)
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                    willDismissMenuFor configuration: UIEditMenuConfiguration,
                                    animator: any UIEditMenuInteractionAnimating) {
        pendingCanvasMenuItemIndex = nil
    }
}
#endif
