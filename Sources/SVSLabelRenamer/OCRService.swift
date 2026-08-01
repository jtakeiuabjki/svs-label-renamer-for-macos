import CoreGraphics
import Foundation
import Vision

struct ParsedLabel: Sendable {
    var pathology = ""
    var block = ""
    var stain = ""
    var raw = ""
}

struct OCRTextObservation: Sendable {
    let text: String
    let confidence: Float
    let boundingBox: CGRect?

    init(text: String, confidence: Float = 1, boundingBox: CGRect? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

enum OCRServiceError: LocalizedError {
    case noResult

    var errorDescription: String? { "ラベルの文字を読み取れませんでした" }
}

struct OCRService {
    private struct LegacyStainMatch {
        let index: Int
        let name: String
        let distance: Int
    }

    private struct Token {
        let index: Int
        let text: String
        let confidence: Float
        let boundingBox: CGRect?
    }

    private struct PositionedStainMatch {
        let token: Token
        let name: String
        let distance: Int
    }

    private struct CandidatePair {
        let pathology: Token
        let stain: PositionedStainMatch
        let score: Float
        let layoutScore: Float
    }

    private struct ParseDetails {
        let label: ParsedLabel
        let layoutScore: Float
    }

    private static let knownStains = [
        "HE", "H&E", "CD3", "CD4", "CD8", "CD20", "CD31", "CD34", "CD56", "CD68",
        "CD163", "KI67", "KI-67", "P53", "AE1AE3", "AE1/AE3", "SMA", "DESMIN",
        "S100", "SOX10", "ER", "PR", "HER2", "PD-L1", "PDL1", "VEGFA"
    ]

    static func recognize(_ image: CGImage) throws -> ParsedLabel {
        var attempts: [[OCRTextObservation]] = []
        var lastError: Error?
        for orientation in [CGImagePropertyOrientation.up, .right, .down, .left] {
            do {
                attempts.append(try recognize(image, orientation: orientation))
            } catch {
                lastError = error
            }
        }
        guard let parsed = parseBestOrientation(attempts) else {
            throw lastError ?? OCRServiceError.noResult
        }
        return parsed
    }

    private static func recognize(
        _ image: CGImage, orientation: CGImagePropertyOrientation
    ) throws -> [OCRTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        request.customWords = knownStains
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation -> OCRTextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRTextObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: observation.boundingBox
            )
        }
    }

    static func parseBestOrientation(_ attempts: [[OCRTextObservation]]) -> ParsedLabel? {
        guard let best = attempts.filter({ !$0.isEmpty }).max(by: { score($0) < score($1) }) else {
            return nil
        }
        return parse(best)
    }

    static func parse(_ lines: [String]) -> ParsedLabel {
        legacyParse(lines)
    }

    static func parse(_ observations: [OCRTextObservation]) -> ParsedLabel {
        parseDetails(observations).label
    }

    private static func score(_ observations: [OCRTextObservation]) -> Float {
        guard !observations.isEmpty else { return -.infinity }
        let details = parseDetails(observations)
        let parsed = details.label
        let structureBonus: Float = (parsed.pathology.isEmpty ? 0 : 2) + (parsed.stain.isEmpty ? 0 : 3)
        let meanConfidence = observations.map(\.confidence).reduce(0, +) / Float(observations.count)
        let positioned = observations.compactMap { validBox($0.boundingBox) }
        let horizontalBonus: Float
        if positioned.isEmpty {
            horizontalBonus = 0
        } else {
            let horizontalCount = positioned.filter { $0.width >= $0.height }.count
            horizontalBonus = 0.5 * Float(horizontalCount) / Float(positioned.count)
        }
        return structureBonus + (2 * meanConfidence) + details.layoutScore + horizontalBonus
    }

    private static func parseDetails(_ observations: [OCRTextObservation]) -> ParseDetails {
        guard observations.contains(where: { validBox($0.boundingBox) != nil }) else {
            return ParseDetails(label: legacyParse(observations.map(\.text)), layoutScore: 0)
        }

        let tokens = makeTokens(from: observations)
        let pathologyCandidates = tokens.filter { isPathologyCandidate($0.text) }
        let stainMatches = tokens.compactMap {
            positionedStainMatch(for: $0, pathologyCandidates: pathologyCandidates)
        }

        var pairs: [CandidatePair] = []
        for pathology in pathologyCandidates {
            for stain in stainMatches where pathology.index != stain.token.index {
                let layout = pairLayoutScore(pathology: pathology, stain: stain.token)
                let lexical = Float(pathologyScore(pathology.text) + 8 - (4 * stain.distance))
                let confidence = 0.25 * (pathology.confidence + stain.token.confidence)
                pairs.append(CandidatePair(
                    pathology: pathology,
                    stain: stain,
                    score: lexical + layout + confidence,
                    layoutScore: layout
                ))
            }
        }

        let selectedPair = pairs.max { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.pathology.index > rhs.pathology.index
            }
            return lhs.score < rhs.score
        }
        let selectedStain = selectedPair?.stain ?? stainMatches.max { lhs, rhs in
            standaloneStainScore(lhs) < standaloneStainScore(rhs)
        }
        let selectedPathology = selectedPair?.pathology ?? pathologyCandidates
            .filter { $0.index != selectedStain?.token.index }
            .max { lhs, rhs in
                standalonePathologyScore(lhs) < standalonePathologyScore(rhs)
            }

        let block = findBlock(
            in: tokens,
            pathology: selectedPathology,
            stain: selectedStain?.token
        )
        let rawLines = spatiallyOrderedLines(observations)
        return ParseDetails(
            label: ParsedLabel(
                pathology: selectedPathology?.text ?? "",
                block: block,
                stain: selectedStain?.name ?? "",
                raw: rawLines.joined(separator: " | ")
            ),
            layoutScore: selectedPair?.layoutScore ?? 0
        )
    }

    private static func legacyParse(_ lines: [String]) -> ParsedLabel {
        let normalized = lines.map { $0.uppercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let candidates = normalized.flatMap { line in
            line.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
        }.filter { !$0.isEmpty }

        var stainMatches: [LegacyStainMatch] = []
        for (index, token) in candidates.enumerated() {
            let cleaned = stainKey(token)
            var tokenMatches: [(String, Int)] = []
            for known in knownStains {
                let distance = editDistance(cleaned, stainKey(known))
                if distance <= (cleaned.count >= 5 ? 1 : 0) {
                    tokenMatches.append((known, distance))
                }
            }
            tokenMatches.sort {
                $0.1 == $1.1 ? stainKey($0.0).count > stainKey($1.0).count : $0.1 < $1.1
            }
            if let match = tokenMatches.first {
                stainMatches.append(LegacyStainMatch(
                    index: index,
                    name: canonicalStain(match.0),
                    distance: match.1
                ))
            }
        }
        stainMatches.sort {
            $0.distance == $1.distance ? $0.name.count > $1.name.count : $0.distance < $1.distance
        }
        let stainMatch = stainMatches.first

        let pathologyMatches = candidates.enumerated().filter { index, token in
            index != stainMatch?.index &&
            token.range(of: #"^[A-Z]{1,3}[A-Z0-9-]*[0-9][A-Z0-9-]*$"#, options: .regularExpression) != nil
        }.sorted { pathologyScore($0.element) > pathologyScore($1.element) }
        let pathologyMatch = pathologyMatches.first

        var block = ""
        if let pathologyIndex = pathologyMatch?.offset, let stainIndex = stainMatch?.index,
           pathologyIndex < stainIndex {
            block = candidates[(pathologyIndex + 1)..<stainIndex].first {
                $0.range(of: #"^(?:[A-Z]{1,2}|[A-Z]?[0-9]{1,2})$"#, options: .regularExpression) != nil
            } ?? ""
        }

        return ParsedLabel(
            pathology: pathologyMatch?.element ?? "",
            block: block,
            stain: stainMatch?.name ?? "",
            raw: lines.joined(separator: " | ")
        )
    }

    private static func makeTokens(from observations: [OCRTextObservation]) -> [Token] {
        var tokens: [Token] = []
        for observation in observations {
            let normalized = observation.text.uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = normalized.components(
                separatedBy: CharacterSet.alphanumerics
                    .union(CharacterSet(charactersIn: "-"))
                    .inverted
            ).filter { !$0.isEmpty }
            for part in parts {
                tokens.append(Token(
                    index: tokens.count,
                    text: part,
                    confidence: observation.confidence,
                    boundingBox: validBox(observation.boundingBox)
                ))
            }
        }
        return tokens
    }

    private static func positionedStainMatch(
        for token: Token,
        pathologyCandidates: [Token]
    ) -> PositionedStainMatch? {
        let cleaned = stainKey(token.text)
        guard !cleaned.isEmpty else { return nil }

        let enhancedTolerance = hasPathologyAbove(token, in: pathologyCandidates)
        let maximumDistance: Int
        if enhancedTolerance, cleaned.count >= 4 {
            maximumDistance = 1
        } else {
            maximumDistance = cleaned.count >= 5 ? 1 : 0
        }

        var bestByCanonical: [String: (source: String, distance: Int)] = [:]
        for known in knownStains {
            let distance = editDistance(cleaned, stainKey(known))
            guard distance <= maximumDistance else { continue }
            let canonical = canonicalStain(known)
            if let current = bestByCanonical[canonical], current.distance <= distance { continue }
            bestByCanonical[canonical] = (known, distance)
        }
        guard let minimumDistance = bestByCanonical.values.map(\.distance).min() else { return nil }
        let closest = bestByCanonical.filter { $0.value.distance == minimumDistance }
        if minimumDistance > 0, closest.count > 1 {
            return nil
        }
        guard let match = closest.max(by: {
            stainKey($0.value.source).count < stainKey($1.value.source).count
        }) else { return nil }
        return PositionedStainMatch(
            token: token,
            name: match.key,
            distance: minimumDistance
        )
    }

    private static func hasPathologyAbove(_ token: Token, in candidates: [Token]) -> Bool {
        guard let stainBox = validBox(token.boundingBox), stainBox.midY <= 0.72 else { return false }
        return candidates.contains { candidate in
            guard candidate.index != token.index,
                  let pathologyBox = validBox(candidate.boundingBox) else { return false }
            return pathologyBox.midY > stainBox.midY + 0.04
        }
    }

    private static func pairLayoutScore(pathology: Token, stain: Token) -> Float {
        guard let pathologyBox = validBox(pathology.boundingBox),
              let stainBox = validBox(stain.boundingBox) else { return 0 }

        let delta = pathologyBox.midY - stainBox.midY
        var score: CGFloat = 0
        if delta > 0 {
            score += 4
        } else {
            score -= min(2.5, 0.5 + (abs(delta) * 5))
        }

        score += edgePrintedPriority(pathology, box: pathologyBox)
        let columnAlignment = max(0, 1 - (abs(pathologyBox.midX - stainBox.midX) * 4))
        score += columnAlignment
        score += 0.75 * (1 - stainBox.midY)
        return Float(score)
    }

    private static func standaloneStainScore(_ match: PositionedStainMatch) -> Float {
        let lowerBonus = validBox(match.token.boundingBox).map { Float(1 - $0.midY) } ?? 0
        return Float(8 - (4 * match.distance)) + lowerBonus + (0.25 * match.token.confidence)
    }

    private static func standalonePathologyScore(_ token: Token) -> Float {
        var score = Float(pathologyScore(token.text)) + (0.25 * token.confidence)
        if let box = validBox(token.boundingBox) {
            score += Float(edgePrintedPriority(token, box: box))
        }
        return score
    }

    private static func edgePrintedPriority(_ token: Token, box: CGRect) -> CGFloat {
        // Vision coordinates use a lower-left origin after applying each candidate
        // orientation. A larger midY is therefore closer to the upper short edge.
        let edgePosition = min(1, max(0, (box.midY - 0.50) / 0.45))
        var score = 14 * edgePosition

        // Printed accession IDs commonly span most of the label and may contain a
        // hyphen. These are bounded bonuses, so other label layouts can still fall
        // back to their text match instead of being rejected outright.
        if token.text.count >= 8, box.width >= 0.60 { score += 4 }
        if token.text.count >= 8, token.text.contains("-") { score += 2 }
        return score
    }

    private static func findBlock(in tokens: [Token], pathology: Token?, stain: Token?) -> String {
        guard let pathology, let stain else { return "" }
        let blockPattern = #"^(?:[A-Z]{1,2}|[A-Z]?[0-9]{1,2})$"#

        if let pathologyBox = validBox(pathology.boundingBox),
           let stainBox = validBox(stain.boundingBox),
           pathologyBox.midY > stainBox.midY {
            let spatialMatch = tokens.filter { token in
                guard token.index != pathology.index,
                      token.index != stain.index,
                      let box = validBox(token.boundingBox) else { return false }
                return box.midY < pathologyBox.midY &&
                    box.midY > stainBox.midY &&
                    token.text.range(of: blockPattern, options: .regularExpression) != nil
            }.sorted {
                (validBox($0.boundingBox)?.midY ?? 0) > (validBox($1.boundingBox)?.midY ?? 0)
            }.first?.text
            if let spatialMatch { return spatialMatch }
        }

        guard pathology.index < stain.index else { return "" }
        return tokens[(pathology.index + 1)..<stain.index].first {
            $0.text.range(of: blockPattern, options: .regularExpression) != nil
        }?.text ?? ""
    }

    private static func spatiallyOrderedLines(_ observations: [OCRTextObservation]) -> [String] {
        let positioned = observations.compactMap { validBox($0.boundingBox) }
        guard positioned.count == observations.count else {
            return observations.map(\.text)
        }
        return observations.enumerated().sorted { lhs, rhs in
            let left = positioned[lhs.offset]
            let right = positioned[rhs.offset]
            if left.midY != right.midY {
                return left.midY > right.midY
            }
            if left.minX != right.minX {
                return left.minX < right.minX
            }
            return lhs.offset < rhs.offset
        }.map(\.element.text)
    }

    private static func isPathologyCandidate(_ token: String) -> Bool {
        token.range(
            of: #"^[A-Z]{1,3}[A-Z0-9-]*[0-9][A-Z0-9-]*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func validBox(_ box: CGRect?) -> CGRect? {
        guard let box,
              box.minX.isFinite, box.minY.isFinite,
              box.maxX.isFinite, box.maxY.isFinite,
              box.width > 0, box.height > 0,
              box.minX >= -0.01, box.minY >= -0.01,
              box.maxX <= 1.01, box.maxY <= 1.01 else { return nil }
        return box
    }

    private static func pathologyScore(_ token: String) -> Int {
        var score = 0
        if token.hasPrefix("K") { score += 6 }
        if !token.contains("-") { score += 4 }
        if (3...8).contains(token.count) { score += 3 }
        if token.count > 10 { score -= 5 }
        return score
    }

    private static func stainKey(_ value: String) -> String {
        String(value.uppercased().filter { $0.isLetter || $0.isNumber })
    }

    private static func canonicalStain(_ value: String) -> String {
        switch stainKey(value) {
        case "HE": return "HE"
        case "KI67": return "Ki-67"
        case "PDL1": return "PD-L1"
        default: return value.uppercased()
        }
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1]
            for (j, right) in b.enumerated() {
                let insertion = current[j] + 1
                let deletion = previous[j + 1] + 1
                let substitution = previous[j] + (left == right ? 0 : 1)
                current.append(min(min(insertion, deletion), substitution))
            }
            previous = current
        }
        return previous[b.count]
    }
}
