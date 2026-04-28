import Foundation
import UIKit

/// In-app messenger — what the user gets when their host app calls
/// `Luniq.shared.openMessenger()`. Modeled after Intercom/Crisp: user types a
/// question/issue/suggestion, the server replies with an AI-generated answer
/// the moment they hit Send. Conversation persists in the dashboard's
/// /v1/messages inbox so the team can follow up if AI couldn't resolve it.
final class MessengerWidget {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private let screenSource: (() -> String)?

    init(config: LuniqConfig, identity: IdentityManager, screenSource: @escaping () -> String = { "" }) {
        self.config = config
        self.identity = identity
        self.screenSource = screenSource
    }

    /// Floating 💬 bubble pinned to bottom-right. Strong reference required —
    /// UIWindow gets dealloc'd otherwise. Optional UX; host apps with their
    /// own help button should call `Luniq.shared.openMessenger()` instead.
    private var bubbleWindow: MessengerBubbleWindow?

    func enableFloatingBubble() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tryInstallBubble()
            // Re-try on scene activation — at app cold-launch the scene might
            // not be in foregroundActive state yet when start() is called.
            NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                object: nil, queue: .main) { [weak self] _ in
                self?.tryInstallBubble()
            }
        }
    }

    private func tryInstallBubble() {
        guard bubbleWindow == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
        let w = MessengerBubbleWindow(windowScene: scene)
        w.frame = scene.coordinateSpace.bounds
        w.onTap = { [weak self] in self?.present() }
        w.isHidden = false
        bubbleWindow = w
    }

    func disableFloatingBubble() {
        DispatchQueue.main.async { [weak self] in
            self?.bubbleWindow?.isHidden = true
            self?.bubbleWindow = nil
        }
    }

    func present(prefilledText: String = "") {
        guard let vc = topVC() else { return }
        let chat = MessengerViewController(
            config: config,
            identity: identity,
            screen: screenSource?() ?? "",
            prefilled: prefilledText
        )
        // Hide the floating bubble while the chat sheet is up — otherwise the
        // bubble UIWindow sits *above* the modal sheet (which renders in the
        // host's window) and its hit-test eats every tap on the segmented
        // control / send button. We restore visibility on dismiss.
        let bubble = bubbleWindow
        bubble?.isHidden = true
        chat.onDismiss = { [weak bubble] in bubble?.isHidden = false }

        let nav = UINavigationController(rootViewController: chat)
        nav.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let s = nav.sheetPresentationController {
                // Large-only — when the keyboard appears in a medium-detent
                // sheet, iOS shrinks the sheet and our Send button can end up
                // off-screen. Full sheet keeps everything reachable.
                s.detents = [.large()]
                s.prefersGrabberVisible = true
            }
        }
        vc.present(nav, animated: true)
    }

    private func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

/// Conversation UI. Two stacked bubbles per round: user message + AI reply.
/// On send: POST /v1/sdk/messages → backend ML composes a reply → display.
final class MessengerViewController: UIViewController, UITextViewDelegate {
    private let config: LuniqConfig
    private let identity: IdentityManager
    private let screen: String
    /// Fired after the sheet is dismissed (any way — swipe-down, close button,
    /// programmatic). Used by MessengerWidget to re-show the floating bubble.
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            onDismiss?()
        }
    }

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let composer = UITextView()
    private let kindControl = UISegmentedControl(items: ["Issue", "Idea", "Question"])
    private let sendButton = UIButton(type: .system)
    private let sendingSpinner = UIActivityIndicatorView(style: .medium)

    init(config: LuniqConfig, identity: IdentityManager, screen: String, prefilled: String) {
        self.config = config
        self.identity = identity
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
        composer.text = prefilled
    }
    required init?(coder: NSCoder) { fatalError() }

    private var sendBarButton: UIBarButtonItem!
    /// The composer's bottom-anchor constraint, pulled out so we can adjust
    /// its constant when the keyboard appears/disappears (manual keyboard
    /// avoidance — `view.keyboardLayoutGuide` causes layout cycles inside a
    /// page-sheet container on iPhone 16, so we observe notifications instead).
    private var composerBottomConstraint: NSLayoutConstraint!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Send a message"
        view.backgroundColor = .systemBackground

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close)
        )
        sendBarButton = UIBarButtonItem(
            title: "Send", style: .done, target: self, action: #selector(send)
        )
        navigationItem.rightBarButtonItem = sendBarButton

        // Keyboard toolbar with a Done button so users can dismiss the keyboard
        // even when the in-line Send button is covered.
        let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard)),
        ]
        toolbar.sizeToFit()
        composer.inputAccessoryView = toolbar

        // Scrollable conversation
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        // Greeting bubble (AI introduces itself). Replaced by the actual
        // conversation history if `loadHistory()` finds any below.
        addAIBubble("Hi! What can we help with? Describe the issue, suggestion, or question — we'll reply right away.")
        loadHistory()

        // Composer pinned to bottom
        let composerWrap = UIView()
        composerWrap.backgroundColor = .secondarySystemBackground
        composerWrap.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerWrap)

        kindControl.selectedSegmentIndex = 0
        kindControl.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(kindControl)

        composer.font = .systemFont(ofSize: 15)
        composer.layer.borderColor = UIColor.separator.cgColor
        composer.layer.borderWidth = 1
        composer.layer.cornerRadius = 10
        composer.delegate = self
        composer.translatesAutoresizingMaskIntoConstraints = false
        // Let intrinsic content size drive height so the input grows with the
        // user's typing instead of greedily filling all available vertical
        // space. Without this, UITextView (no inherent height limit) ate the
        // entire sheet and the chat scroll view collapsed to 0pt — which is
        // why the conversation thread was invisible.
        composer.isScrollEnabled = false
        composer.setContentHuggingPriority(.defaultHigh, for: .vertical)
        composer.setContentCompressionResistancePriority(.required, for: .vertical)
        composerWrap.addSubview(composer)

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        sendButton.backgroundColor = .systemBlue
        sendButton.setTitleColor(.white, for: .normal)
        sendButton.layer.cornerRadius = 8
        sendButton.contentEdgeInsets = .init(top: 8, left: 16, bottom: 8, right: 16)
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.addTarget(self, action: #selector(send), for: .touchUpInside)
        composerWrap.addSubview(sendButton)

        sendingSpinner.translatesAutoresizingMaskIntoConstraints = false
        sendingSpinner.hidesWhenStopped = true
        composerWrap.addSubview(sendingSpinner)

        // Place [composer | sendButton] in a horizontal stack so they stay
        // aligned regardless of how tall the textview grows. Bottom-aligned
        // so the send button hugs the last text line rather than floating.
        let inputRow = UIStackView(arrangedSubviews: [composer, sendButton])
        inputRow.axis = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false
        composerWrap.addSubview(inputRow)
        // Send button must not be compressed when textview grows.
        sendButton.setContentHuggingPriority(.required, for: .horizontal)
        sendButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: composerWrap.topAnchor),

            stack.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scroll.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -32),

            composerWrap.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerWrap.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            kindControl.topAnchor.constraint(equalTo: composerWrap.topAnchor, constant: 10),
            kindControl.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: 12),
            kindControl.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -12),

            inputRow.topAnchor.constraint(equalTo: kindControl.bottomAnchor, constant: 8),
            inputRow.leadingAnchor.constraint(equalTo: composerWrap.leadingAnchor, constant: 12),
            inputRow.trailingAnchor.constraint(equalTo: composerWrap.trailingAnchor, constant: -12),
            inputRow.bottomAnchor.constraint(equalTo: composerWrap.bottomAnchor, constant: -10),

            composer.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            // Cap composer growth — past this point the textview scrolls
            // internally instead of pushing the chat thread off-screen.
            composer.heightAnchor.constraint(lessThanOrEqualToConstant: 120),

            sendingSpinner.centerXAnchor.constraint(equalTo: sendButton.centerXAnchor),
            sendingSpinner.centerYAnchor.constraint(equalTo: sendButton.centerYAnchor),
        ])

        // Keyboard-avoidance: hold a reference to the composer's bottom anchor
        // and slide it up when the keyboard appears so the kindControl +
        // textfield aren't covered. Observed via NotificationCenter rather
        // than keyboardLayoutGuide to avoid the iPhone 16 page-sheet crash.
        composerBottomConstraint = composerWrap.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        composerBottomConstraint.isActive = true

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillShowNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillChange(_:)),
                       name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        nc.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                       name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardWillChange(_ note: NSNotification) {
        guard
            let info = note.userInfo,
            let endFrame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
            let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval
        else { return }
        let viewInWindow = view.convert(view.bounds, to: nil)
        let keyboardOverlap = max(0, viewInWindow.maxY - endFrame.origin.y)
        composerBottomConstraint.constant = -keyboardOverlap
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
        scrollToBottom()
    }

    @objc private func keyboardWillHide(_ note: NSNotification) {
        let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0.25
        composerBottomConstraint.constant = 0
        UIView.animate(withDuration: duration) { self.view.layoutIfNeeded() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Focus only after the sheet has finished animating in. Doing it in
        // viewDidLoad triggers keyboard layout while the sheet container is
        // still measuring → crash inside _UISheetLayoutInfo on iOS 18.
        composer.becomeFirstResponder()
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    /// Fetch the user's recent conversation thread from the backend so opening
    /// the messenger after a previous session shows the AI's prior replies in
    /// place — the "I sent something but where did it go?" fix.
    private func loadHistory() {
        guard let visitorId = identity.visitorId, !visitorId.isEmpty,
              var comps = URLComponents(string: "\(config.endpoint)/v1/sdk/messages/history") else {
            return
        }
        comps.queryItems = [
            URLQueryItem(name: "visitorId", value: visitorId),
            URLQueryItem(name: "accountId", value: identity.accountId ?? ""),
            URLQueryItem(name: "limit", value: "20"),
        ]
        guard let url = comps.url else { return }
        var req = URLRequest(url: url)
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard
                let self,
                let data,
                let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                !arr.isEmpty
            else { return }
            DispatchQueue.main.async {
                // Replace the static welcome with real history. Clear stack first.
                for v in self.stack.arrangedSubviews {
                    self.stack.removeArrangedSubview(v); v.removeFromSuperview()
                }
                self.addAIBubble("Welcome back. Here's your recent conversation:")
                for m in arr {
                    if let userText = m["userText"] as? String, !userText.isEmpty {
                        self.addUserBubble(userText)
                    }
                    if let reply = m["aiReply"] as? String, !reply.isEmpty {
                        self.addAIBubble(reply)
                    }
                    if let action = m["action"] as? String,
                       action == "filed_bug",
                       let jiraKey = m["jiraKey"] as? String, !jiraKey.isEmpty {
                        self.addAIBubble("📌 Filed as ticket \(jiraKey).")
                    }
                }
            }
        }.resume()
    }

    @objc private func send() {
        let text = (composer.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let kindIndex = kindControl.selectedSegmentIndex
        let kind = ["issue", "idea", "question"][kindIndex]

        addUserBubble(text)
        composer.text = ""
        sendButton.setTitle("", for: .normal)
        sendButton.isEnabled = false
        sendBarButton?.isEnabled = false
        sendingSpinner.startAnimating()

        guard let url = URL(string: "\(config.endpoint)/v1/sdk/messages") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        let body: [String: Any] = [
            "kind":      kind,
            "text":      text,
            "visitorId": identity.visitorId ?? "",
            "accountId": identity.accountId ?? "",
            "screen":    screen,
            "context":   identity.traits,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.sendingSpinner.stopAnimating()
                self.sendButton.setTitle("Send", for: .normal)
                self.sendButton.isEnabled = true
                self.sendBarButton?.isEnabled = true

                let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let success = err == nil && (200..<300).contains(httpStatus)

                // Network-level failure — tell the user, don't silently lie.
                if !success {
                    self.addAIBubble("⚠️ Couldn't reach support right now. Please check your connection and try again.")
                    return
                }

                // Backend's canonical field is `reply`; older builds returned
                // `aiReply`/`ai_reply`. Accept any of them so the chat works
                // regardless of which version of the API you're hitting.
                if let data,
                   let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let reply = (j["reply"] as? String)
                        ?? (j["aiReply"] as? String)
                        ?? (j["ai_reply"] as? String)
                        ?? ""
                    let action = (j["action"] as? String) ?? ""
                    let jiraKey = (j["jiraKey"] as? String) ?? ""

                    if !reply.isEmpty {
                        self.addAIBubble(reply)
                    } else {
                        self.addAIBubble("Thanks — we've logged this and a teammate will follow up.")
                    }
                    // If the backend auto-filed this as a bug, surface that
                    // small confirmation so the user knows it's tracked.
                    if action == "filed_bug" && !jiraKey.isEmpty {
                        self.addAIBubble("📌 Filed as ticket \(jiraKey).")
                    }
                } else {
                    self.addAIBubble("Thanks — we've logged this and a teammate will follow up.")
                }
            }
        }.resume()
    }

    private func addUserBubble(_ text: String) {
        let bubble = makeBubble(text: text, isUser: true)
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: row.leadingAnchor, constant: 40),
        ])
        stack.addArrangedSubview(row)
        scrollToBottom()
    }

    private func addAIBubble(_ text: String) {
        let bubble = makeBubble(text: text, isUser: false)
        let row = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(bubble)
        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: row.topAnchor),
            bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -40),
        ])
        stack.addArrangedSubview(row)
        scrollToBottom()
    }

    private func makeBubble(text: String, isUser: Bool) -> UIView {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.backgroundColor = isUser ? .systemBlue : .secondarySystemBackground
        v.layer.cornerRadius = 14
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 14)
        label.textColor = isUser ? .white : .label
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -14),
        ])
        return v
    }

    private func scrollToBottom() {
        DispatchQueue.main.async {
            self.scroll.layoutIfNeeded()
            let bottom = self.scroll.contentSize.height - self.scroll.bounds.height
            if bottom > 0 {
                self.scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: true)
            }
        }
    }
}

/// Overlay UIWindow hosting just the floating 💬 bubble so the host app's
/// rootViewController doesn't need to know anything about it. Sits above
/// app content but below system alerts. Pass-through hit testing — only
/// the bubble button captures taps.
final class MessengerBubbleWindow: UIWindow {
    var onTap: (() -> Void)?
    private let button = UIButton(type: .system)

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert - 1
        backgroundColor = .clear
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        rootViewController = vc

        button.translatesAutoresizingMaskIntoConstraints = false
        button.backgroundColor = UIColor(red: 0.36, green: 0.45, blue: 0.96, alpha: 1)
        button.tintColor = .white
        button.setTitle("💬", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 24)
        button.layer.cornerRadius = 28
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 8
        button.layer.shadowOffset = CGSize(width: 0, height: 4)
        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        vc.view.addSubview(button)

        // Position above any host tab bar — typical iOS tab bars are ~50pt
        // tall. 84pt clearance keeps the bubble inside the page area.
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 52),
            button.heightAnchor.constraint(equalToConstant: 52),
            button.trailingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor, constant: -14),
            button.bottomAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.bottomAnchor, constant: -84),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Pass-through except for the button itself.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let v = super.hitTest(point, with: event) else { return nil }
        return v === button ? v : nil
    }

    @objc private func handleTap() { onTap?() }
}
