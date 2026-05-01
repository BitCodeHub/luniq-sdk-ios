import Foundation
import UIKit

public struct PulseSurvey: Codable {
    public let id: String
    public let name: String
    public let kind: String // nps | csat | custom
    public let trigger: [String: AnyCodable]
    public let audience: [String: AnyCodable]
    public let questions: [[String: AnyCodable]]
}

final class SurveyEngine {
    private let config: LuniqConfig
    private let track: (String, [String: Any]) -> Void
    private var surveys: [PulseSurvey] = []
    private var answered: Set<String> = []
    private let defaults = UserDefaults(suiteName: "ai.luniq.sdk") ?? .standard
    private let kAnswered = "luniq.surveys.answered"

    init(config: LuniqConfig, track: @escaping (String, [String: Any]) -> Void) {
        self.config = config
        self.track = track
        self.answered = Set(defaults.stringArray(forKey: kAnswered) ?? [])
    }

    func fetchSurveys(completion: (() -> Void)? = nil) {
        guard let url = URL(string: "\(config.endpoint)/v1/sdk/surveys") else { completion?(); return }
        var req = URLRequest(url: url)
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self else { DispatchQueue.main.async { completion?() }; return }
            if let data, let s = try? JSONDecoder().decode([PulseSurvey].self, from: data) {
                DispatchQueue.main.async {
                    self.surveys = s
                    Logger.log("Luniq: loaded \(s.count) survey(s)")
                    completion?()
                }
            } else {
                DispatchQueue.main.async { completion?() }
            }
        }.resume()
    }

    func evaluate(eventName: String, screenName: String?, traits: [String: Any]) {
        DispatchQueue.main.async {
            for s in self.surveys {
                if self.answered.contains(s.id) { continue }
                let triggerHit: Bool = {
                    if let onEvent = s.trigger["onEvent"]?.value as? String, onEvent == eventName { return true }
                    if let onScreen = s.trigger["onScreen"]?.value as? String, onScreen == (screenName ?? "") { return true }
                    return false
                }()
                if !triggerHit { continue }
                if !self.matchesPredictiveCohort(s) { continue }
                self.show(s, traits: traits); return
            }
        }
    }

    private func matchesPredictiveCohort(_ s: PulseSurvey) -> Bool {
        guard let pc = s.audience["predictiveCohort"]?.value as? [String: Any], !pc.isEmpty else { return true }
        guard Luniq.shared.profile() != nil else { return false }
        if let personas = pc["persona"] as? [String], !personas.isEmpty, !personas.contains(Luniq.shared.persona()) { return false }
        if !inBand(Luniq.shared.predictChurn(),           pc["churnRisk"])             { return false }
        if !inBand(Luniq.shared.sessionScore(),           pc["sessionScore"])          { return false }
        if !inBand(Luniq.shared.conversionProbability(),  pc["conversionProbability"]) { return false }
        return true
    }
    private func inBand(_ value: Int, _ band: Any?) -> Bool {
        guard let b = band as? [String: Any] else { return true }
        if let mn = b["min"] as? Int, value < mn { return false }
        if let mx = b["max"] as? Int, value > mx { return false }
        return true
    }

    private func show(_ s: PulseSurvey, traits: [String: Any]) {
        track("$survey_shown", ["survey_id": s.id, "survey_name": s.name])
        SurveyRenderer.render(s) { [weak self] score, answers in
            guard let self else { return }
            self.answered.insert(s.id)
            self.defaults.set(Array(self.answered), forKey: self.kAnswered)
            self.submit(surveyId: s.id, score: score, answers: answers)
            self.track("$survey_completed", ["survey_id": s.id, "score": score ?? NSNull()])
        }
    }

    private func submit(surveyId: String, score: Int?, answers: [String: Any]) {
        guard let url = URL(string: "\(config.endpoint)/v1/surveys/\(surveyId)/responses") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "X-Luniq-Key")
        var payload: [String: Any] = ["answers": answers]
        if let score = score { payload["score"] = score }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        URLSession.shared.dataTask(with: req).resume()
    }
}

enum SurveyRenderer {
    static func render(_ survey: PulseSurvey, done: @escaping (Int?, [String: Any]) -> Void) {
        guard let vc = topVC() else { return }
        let sheet = UIViewController()
        sheet.view.backgroundColor = .systemBackground
        sheet.modalPresentationStyle = .pageSheet
        if #available(iOS 15.0, *) {
            if let s = sheet.sheetPresentationController { s.detents = [.medium()]; s.prefersGrabberVisible = true }
        }

        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        sheet.view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sheet.view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: sheet.view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: sheet.view.trailingAnchor, constant: -24),
        ])

        let title = UILabel(); title.text = survey.name; title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let question = (survey.questions.first?["text"]?.value as? String) ?? "How likely are you to recommend us?"
        let qLabel = UILabel(); qLabel.text = question; qLabel.numberOfLines = 0
        stack.addArrangedSubview(qLabel)

        var selectedScore: Int? = nil
        let comment = UITextField()
        comment.placeholder = "Tell us why (optional)"
        comment.borderStyle = .roundedRect

        let submit = UIButton(type: .system)
        submit.setTitle("Submit", for: .normal); submit.backgroundColor = .systemBlue
        submit.setTitleColor(.white, for: .normal); submit.layer.cornerRadius = 8
        submit.contentEdgeInsets = .init(top: 10, left: 20, bottom: 10, right: 20)
        submit.isEnabled = false; submit.alpha = 0.5

        if survey.kind == "nps" {
            let scale = UIStackView(); scale.axis = .horizontal; scale.distribution = .equalSpacing
            for i in 0...10 {
                let b = UIButton(type: .system)
                b.setTitle("\(i)", for: .normal)
                b.frame.size = CGSize(width: 28, height: 36)
                b.layer.borderColor = UIColor.separator.cgColor
                b.layer.borderWidth = 1; b.layer.cornerRadius = 6
                if #available(iOS 14.0, *) {
                    b.addAction(UIAction { _ in
                        selectedScore = i
                        scale.arrangedSubviews.enumerated().forEach { idx, v in
                            v.backgroundColor = idx == i ? .systemBlue : .clear
                            (v as? UIButton)?.setTitleColor(idx == i ? .white : .systemBlue, for: .normal)
                        }
                        submit.isEnabled = true; submit.alpha = 1
                    }, for: .touchUpInside)
                }
                scale.addArrangedSubview(b)
            }
            stack.addArrangedSubview(scale)
            stack.addArrangedSubview(comment)
        } else {
            stack.addArrangedSubview(comment)
            submit.isEnabled = true; submit.alpha = 1
        }
        stack.addArrangedSubview(submit)

        if #available(iOS 14.0, *) {
            submit.addAction(UIAction { _ in
                var answers: [String: Any] = [:]
                if let c = comment.text, !c.isEmpty { answers["comment"] = c }
                sheet.dismiss(animated: true) { done(selectedScore, answers) }
            }, for: .touchUpInside)
        }

        vc.present(sheet, animated: true)
    }

    private static func topVC() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var vc = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}
