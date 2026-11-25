import Foundation

/// A question an agent asks you with choices (Claude Code's AskUserQuestion). It reaches Bangs as a permission request
/// for that tool, and is answered by allowing it with the answers added to its input.
public struct AgentQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var description: String
    }

    public var question: String
    /// A word or two naming the question, shown above it.
    public var header: String
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String = "", options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// The tool that asks.
    public static let tool = "AskUserQuestion"

    /// The questions in the tool's input; empty unless every one has a question and options to choose from.
    public static func parse(_ input: Any?) -> [AgentQuestion] {
        guard let list = (input as? [String: Any])?["questions"] as? [[String: Any]], !list.isEmpty else { return [] }
        let questions = list.compactMap { item -> AgentQuestion? in
            guard let question = item["question"] as? String, !question.isEmpty,
                  let options = item["options"] as? [[String: Any]] else { return nil }
            let choices = options.compactMap { option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: option["description"] as? String ?? "")
            }
            guard !choices.isEmpty else { return nil }
            return AgentQuestion(question: question, header: item["header"] as? String ?? "", options: choices,
                                 multiSelect: item["multiSelect"] as? Bool ?? false)
        }
        return questions.count == list.count ? questions : []
    }

    /// The answers as the tool takes them: question text → the chosen labels, several separated by commas. `chosen` is
    /// by question index, since two questions may read the same; the tool's answers cannot tell those apart, so theirs
    /// are sent together.
    public static func answers(_ questions: [AgentQuestion], chosen: [Int: [String]]) -> [String: String] {
        var answers: [String: [String]] = [:]
        for (index, question) in questions.enumerated() {
            for label in chosen[index] ?? [] where !(answers[question.question] ?? []).contains(label) {
                answers[question.question, default: []].append(label)
            }
        }
        return answers.mapValues { $0.joined(separator: ", ") }
    }
}
