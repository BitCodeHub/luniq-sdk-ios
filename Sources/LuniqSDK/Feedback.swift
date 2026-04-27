import Foundation
import UIKit

final class FeedbackWidget {
    private let config: LuniqConfig
    private let identity: IdentityManager

    init(config: LuniqConfig, identity: IdentityManager) {
        self.config = config
        self.identity = identity
    }

    func present(kind: String = "idea") {
        guard let vc = topVC() else { return }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemBackground
        sheet.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let s = sheet.sheetPresentationController { s.detents = [.medium()] }
        }

        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: sheet.view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: sheet.view.trailingAnchor, constant: -24),
        ])

        let title = UILabel(); title.text = "Share feedback"; title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let seg = UISegmentedControl(items: ["Idea", "Bug", "Kudos"])
        seg.selectedSegmentIndex = kind == "bug" ? 1 : (kind == "kudos" ? 2 : 0)
        stack.addArrangedSubview(seg)

        let tv = UITextView()
        tv.text = "What's on your mind?"
        tv.textColor = .placeholderText
        tv.font = .systemFont(ofSize: 15)
        tv.layer.borderColor = UIColor.separator.cgColor
        tv.layer.borderWidth = 1; tv.layer.cornerRadius = 8
        tv.translatesAutoresizingMaskIntoConstraints = false
        tv.heightAnchor.constraint(equalToConstant: 120).isActive = true
        stack.addArrangedSubview(tv)

        let submit = UIButton(type: .system)
        submit.setTitle("Send", for: .normal); submit.backgroundColor = .systemBlue
        submit.setTitleColor(.white, for: .normal); submit.layer.cornerRadius = 8
        submit.contentEdgeInsets = .init(top: 10, left: 20, bottom: 10, right: 20)
        stack.addArrangedSubview(submit)

        // placeholder handling
        let tvDelegate = PlaceholderDelegate()
        tv.delegate = tvDelegate
        objc_setAssociatedObject(tv, "hp_delegate", tvDelegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        if #available(iOS 14.0, *) {
        submit.addAction(UIAction { [weak self] _ in
            let kinds = ["idea", "bug", "kudos"]
            let k = kinds[seg.selectedSegmentIndex]
            let msg = (tv.textColor == .placeholderText ? "" : (tv.text ?? ""))
            guard !msg.isEmpty else { return }
            self?.submit(kind: k, message: msg)
            sheet.dismiss(animated: true)
            self?.showThanks(on: vc)
        }, for: .touchUpInside)
        }

        vc.present(sheet, animated: true)
    }

    private func submit(kind: String, message: String) {
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/feedback") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        let body: [String: Any] = [
            "kind": kind,
            "message": message,
            "visitorId": identity.visitorId ?? "",
            "accountId": identity.accountId ?? "",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    private func showThanks(on vc: UIViewController) {
        let a = UIAlertController(title: "Thanks!", message: "We got your feedback.", preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        vc.present(a, animated: true)
    }

    private func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

final class PlaceholderDelegate: NSObject, UITextViewDelegate {
    func textViewDidBeginEditing(_ tv: UITextView) {
        if tv.textColor == .placeholderText { tv.text = ""; tv.textColor = .label }
    }
    func textViewDidEndEditing(_ tv: UITextView) {
        if (tv.text ?? "").isEmpty { tv.text = "What's on your mind?"; tv.textColor = .placeholderText }
    }
}
