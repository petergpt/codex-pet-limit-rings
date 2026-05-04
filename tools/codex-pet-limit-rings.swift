import AppKit
import Foundation
import SQLite3

struct LimitBucket {
    var usedPercent: Double
    var windowMinutes: Double?
    var resetAt: TimeInterval?

    var remainingPercent: Double {
        min(max(100.0 - usedPercent, 0.0), 100.0)
    }
}

struct LimitState {
    var planType: String?
    var primary: LimitBucket?
    var secondary: LimitBucket?
    var additional: [(name: String, bucket: LimitBucket)]
    var observedAt: Date
    var source: String

    static let empty = LimitState(planType: nil, primary: nil, secondary: nil, additional: [], observedAt: Date(), source: "none")
}

private let limitStatePollInterval: TimeInterval = 20.0
private let petFramePollInterval: TimeInterval = 0.12
private let ringsVisibleDefaultsKey = "CodexPetLimitRings.ringsVisible"
private let outerColorDefaultsKey = "CodexPetLimitRings.outerColor"
private let innerColorDefaultsKey = "CodexPetLimitRings.innerColor"
private let idleOpacityDefaultsKey = "CodexPetLimitRings.idleOpacity"
private let idleScaleDefaultsKey = "CodexPetLimitRings.idleScale"
private let liveUsageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

struct RingVisualSettings {
    var outerColorName: String
    var innerColorName: String
    var idleOpacity: CGFloat
    var idleScale: CGFloat

    static let defaultOuterColor = "mint"
    static let defaultInnerColor = "blue"
    static let defaultIdleOpacity: CGFloat = 0.10
    static let defaultIdleScale: CGFloat = 0.70

    static func load() -> RingVisualSettings {
        let defaults = UserDefaults.standard
        return RingVisualSettings(
            outerColorName: defaults.string(forKey: outerColorDefaultsKey) ?? defaultOuterColor,
            innerColorName: defaults.string(forKey: innerColorDefaultsKey) ?? defaultInnerColor,
            idleOpacity: CGFloat(defaults.object(forKey: idleOpacityDefaultsKey) as? Double ?? Double(defaultIdleOpacity)),
            idleScale: CGFloat(defaults.object(forKey: idleScaleDefaultsKey) as? Double ?? Double(defaultIdleScale))
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(outerColorName, forKey: outerColorDefaultsKey)
        defaults.set(innerColorName, forKey: innerColorDefaultsKey)
        defaults.set(Double(idleOpacity), forKey: idleOpacityDefaultsKey)
        defaults.set(Double(idleScale), forKey: idleScaleDefaultsKey)
    }

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: outerColorDefaultsKey)
        defaults.removeObject(forKey: innerColorDefaultsKey)
        defaults.removeObject(forKey: idleOpacityDefaultsKey)
        defaults.removeObject(forKey: idleScaleDefaultsKey)
    }
}

private struct EventPayload: Decodable {
    var type: String
    var plan_type: String?
    var rate_limits: RatePayload?
    var additional_rate_limits: [String: RatePayload]?
}

private struct AuthPayload: Decodable {
    var tokens: AuthTokens?
}

private struct AuthTokens: Decodable {
    var access_token: String?
}

private struct UsagePayload: Decodable {
    var plan_type: String?
    var rate_limit: RatePayload?
    var additional_rate_limits: [AdditionalUsagePayload]?
}

private struct AdditionalUsagePayload: Decodable {
    var limit_name: String?
    var metered_feature: String?
    var rate_limit: RatePayload?
}

private struct RatePayload: Decodable {
    var primary: BucketPayload?
    var secondary: BucketPayload?
    var primary_window: BucketPayload?
    var secondary_window: BucketPayload?
}

private struct BucketPayload: Decodable {
    var used_percent: Double?
    var window_minutes: Double?
    var limit_window_seconds: Double?
    var reset_at: Double?

    func toBucket() -> LimitBucket? {
        guard let used = used_percent else { return nil }
        let minutes = window_minutes ?? limit_window_seconds.map { $0 / 60.0 }
        return LimitBucket(usedPercent: used, windowMinutes: minutes, resetAt: reset_at)
    }
}

struct LimitRingsConfig {
    var codexHome: URL
    var globalStatePath: URL
    var logsPath: URL
    var authPath: URL
    var previewPath: URL?
    var fallbackSize: CGFloat = 220
}

final class LimitStateReader {
    private let logsPath: URL
    private let authPath: URL

    init(logsPath: URL, authPath: URL) {
        self.logsPath = logsPath
        self.authPath = authPath
    }

    func readLatest() -> LimitState {
        if let liveState = readLiveUsage() {
            return liveState
        }
        return readLatestLog()
    }

    private func readLiveUsage() -> LimitState? {
        guard let token = readAccessToken() else {
            return nil
        }

        var request = URLRequest(url: liveUsageURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 6.0
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResponse: URLResponse?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            resultData = data
            resultResponse = response
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + 7.0) == .success,
              let http = resultResponse as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let data = resultData,
              let payload = try? JSONDecoder().decode(UsagePayload.self, from: data) else {
            return nil
        }

        let primary = (payload.rate_limit?.primary ?? payload.rate_limit?.primary_window)?.toBucket()
        let secondary = (payload.rate_limit?.secondary ?? payload.rate_limit?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [])
            .compactMap { item -> (String, LimitBucket)? in
                guard let bucket = (item.rate_limit?.primary ?? item.rate_limit?.primary_window ?? item.rate_limit?.secondary ?? item.rate_limit?.secondary_window)?.toBucket() else {
                    return nil
                }
                return (item.limit_name ?? item.metered_feature ?? "Additional", bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "live")
    }

    private func readAccessToken() -> String? {
        guard let data = try? Data(contentsOf: authPath),
              let payload = try? JSONDecoder().decode(AuthPayload.self, from: data),
              let token = payload.tokens?.access_token,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func readLatestLog() -> LimitState {
        guard FileManager.default.fileExists(atPath: logsPath.path) else {
            return .empty
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(logsPath.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard openResult == SQLITE_OK, let db else {
            return .empty
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT feedback_log_body
        FROM logs
        WHERE feedback_log_body LIKE '%"type":"codex.rate_limits"%'
        ORDER BY ts DESC, ts_nanos DESC, id DESC
        LIMIT 1
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .empty
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cText = sqlite3_column_text(statement, 0) else {
            return .empty
        }

        let body = String(cString: cText)
        guard let json = extractRateLimitJSON(from: body),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(EventPayload.self, from: data) else {
            return .empty
        }

        let primary = (payload.rate_limits?.primary ?? payload.rate_limits?.primary_window)?.toBucket()
        let secondary = (payload.rate_limits?.secondary ?? payload.rate_limits?.secondary_window)?.toBucket()
        let additional = (payload.additional_rate_limits ?? [:])
            .compactMap { name, payload -> (String, LimitBucket)? in
                guard let bucket = (payload.primary ?? payload.primary_window ?? payload.secondary ?? payload.secondary_window)?.toBucket() else {
                    return nil
                }
                return (name, bucket)
            }
            .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        return LimitState(planType: payload.plan_type, primary: primary, secondary: secondary, additional: additional, observedAt: Date(), source: "log")
    }

    private func extractRateLimitJSON(from body: String) -> String? {
        guard let start = body.range(of: "{\"type\":\"codex.rate_limits\"")?.lowerBound else {
            return nil
        }

        var depth = 0
        var inString = false
        var escaping = false
        var endIndex: String.Index?
        var index = start

        while index < body.endIndex {
            let char = body[index]
            if inString {
                if escaping {
                    escaping = false
                } else if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    inString = false
                }
            } else {
                if char == "\"" {
                    inString = true
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                    if depth == 0 {
                        endIndex = body.index(after: index)
                        break
                    }
                }
            }
            index = body.index(after: index)
        }

        guard let endIndex else { return nil }
        return String(body[start..<endIndex])
    }
}

final class PetFrameReader {
    private let globalStatePath: URL

    init(globalStatePath: URL) {
        self.globalStatePath = globalStatePath
    }

    func readPetFrameTopLeft() -> CGRect? {
        guard let data = try? Data(contentsOf: globalStatePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              isAvatarOverlayOpen(root),
              let bounds = root["electron-avatar-overlay-bounds"] as? [String: Any],
              let x = number(bounds["x"]),
              let y = number(bounds["y"]),
              let mascot = bounds["mascot"] as? [String: Any],
              let left = number(mascot["left"]),
              let top = number(mascot["top"]),
              let width = number(mascot["width"]),
              let height = number(mascot["height"]) else {
            return nil
        }

        return CGRect(x: x + left, y: y + top, width: width, height: height)
    }

    private func isAvatarOverlayOpen(_ root: [String: Any]) -> Bool {
        if let isOpen = root["electron-avatar-overlay-open"] as? Bool {
            return isOpen
        }
        if let isOpen = root["electron-avatar-overlay-open"] as? NSNumber {
            return isOpen.boolValue
        }
        return true
    }

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        return nil
    }
}

struct LimitRingRenderer {
    var state: LimitState
    var phase: Double
    var showsReadout: Bool = false
    var hoverProgress: CGFloat = 0
    var settings: RingVisualSettings = .load()

    private var visualStrength: CGFloat {
        settings.idleOpacity + (1.0 - settings.idleOpacity) * easedHoverProgress
    }

    private var easedHoverProgress: CGFloat {
        let progress = min(max(hoverProgress, 0), 1)
        return progress * progress * (3.0 - 2.0 * progress)
    }

    func draw(in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShouldAntialias(true)
        context.clear(rect)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let minSide = min(rect.width, rect.height)
        let urgency = max(urgency(for: state.primary), urgency(for: state.secondary))
        let breathe = CGFloat((sin(phase * 2.0 * .pi) + 1.0) * 0.5)
        let pulse = CGFloat(1.0 + urgency * 0.025 * breathe)
        let strength = visualStrength
        let radiusScale = settings.idleScale + (1.0 - settings.idleScale) * easedHoverProgress
        let outerRadius = (minSide * 0.5 - 16.0) * pulse * radiusScale
        let innerRadius = outerRadius - (13.0 * (0.78 + 0.22 * easedHoverProgress))
        drawHalo(context, center: center, radius: outerRadius, urgency: CGFloat(urgency), breathe: breathe, strength: strength)
        drawTicks(context, center: center, radius: outerRadius + 5.0, strength: strength)

        if let primary = state.primary {
            drawRing(
                context,
                center: center,
                radius: outerRadius,
                lineWidth: 7.0 * (0.74 + 0.26 * easedHoverProgress),
                bucket: primary,
                color: color(forRemaining: primary.remainingPercent, role: .primary),
                trackAlpha: 0.20,
                phase: phase,
                strength: strength
            )
        } else {
            drawMissingRing(context, center: center, radius: outerRadius, lineWidth: 7.0 * (0.74 + 0.26 * easedHoverProgress), strength: strength)
        }

        if let secondary = state.secondary {
            drawRing(
                context,
                center: center,
                radius: innerRadius,
                lineWidth: 4.5 * (0.76 + 0.24 * easedHoverProgress),
                bucket: secondary,
                color: color(forRemaining: secondary.remainingPercent, role: .secondary),
                trackAlpha: 0.14,
                phase: phase + 0.18,
                strength: strength
            )
        }

        drawModelLimitDots(context, center: center, radius: outerRadius + 11.0, state: state, strength: strength)
        if showsReadout && hoverProgress > 0.82 {
            drawLimitReadouts(context, center: center, outerRadius: outerRadius, innerRadius: innerRadius, bounds: rect)
        }
        context.restoreGState()
    }

    private enum RingRole {
        case primary
        case secondary
    }

    private struct LimitReadout {
        var text: String
        var ringPoint: CGPoint
        var labelRect: CGRect
        var color: NSColor
        var angle: CGFloat
    }

    private func urgency(for bucket: LimitBucket?) -> Double {
        guard let bucket else { return 0.0 }
        return min(max((45.0 - bucket.remainingPercent) / 45.0, 0.0), 1.0)
    }

    private func drawHalo(_ context: CGContext, center: CGPoint, radius: CGFloat, urgency: CGFloat, breathe: CGFloat, strength: CGFloat) {
        guard strength > 0.5 else { return }
        context.saveGState()
        let color = NSColor(calibratedRed: 0.23 + urgency * 0.55, green: 0.85 - urgency * 0.30, blue: 0.78 - urgency * 0.48, alpha: 0.22 + urgency * 0.16)
        context.setLineCap(.round)
        context.setShadow(offset: .zero, blur: 14.0 + urgency * breathe * 5.0, color: color.withAlphaComponent(0.55 * strength).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.20 * strength).cgColor)
        context.setLineWidth(8.0)
        context.addArc(center: center, radius: radius + 3.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.045 * strength).cgColor)
        context.setLineWidth(1.0)
        context.addArc(center: center, radius: radius + 13.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawTicks(_ context: CGContext, center: CGPoint, radius: CGFloat, strength: CGFloat) {
        guard strength > 0.5 else { return }
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.10 * strength).cgColor)
        context.setLineWidth(1.2)
        context.setLineCap(.round)
        for i in 0..<24 {
            guard i % 2 == 0 else { continue }
            let angle = -CGFloat.pi / 2.0 + CGFloat(i) / 24.0 * CGFloat.pi * 2.0
            let inner = radius - 1.5
            let outer = radius + 2.5
            context.move(to: point(center: center, radius: inner, angle: angle))
            context.addLine(to: point(center: center, radius: outer, angle: angle))
            context.strokePath()
        }
        context.restoreGState()
    }

    private func drawRing(
        _ context: CGContext,
        center: CGPoint,
        radius: CGFloat,
        lineWidth: CGFloat,
        bucket: LimitBucket,
        color: NSColor,
        trackAlpha: CGFloat,
        phase: Double,
        strength: CGFloat
    ) {
        let start = -CGFloat.pi / 2.0
        let remaining = CGFloat(bucket.remainingPercent / 100.0)
        let end = start + max(remaining, 0.018) * CGFloat.pi * 2.0

        context.saveGState()
        context.setLineCap(.round)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(NSColor(calibratedWhite: 0.0, alpha: 0.08 * strength).cgColor)
        context.addArc(center: center, radius: radius + 1.0, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: trackAlpha * strength).cgColor)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 2.0, clockwise: false)
        context.strokePath()

        if strength > 0.5 {
            context.setShadow(offset: .zero, blur: 10.0, color: color.withAlphaComponent(0.42 * strength).cgColor)
            context.setStrokeColor(color.withAlphaComponent(0.30 * strength).cgColor)
            context.setLineWidth(lineWidth + 6.0)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.strokePath()
        }

        context.setShadow(offset: .zero, blur: 4.0 * strength, color: color.withAlphaComponent(0.52 * strength).cgColor)
        context.setStrokeColor(color.withAlphaComponent(0.88 * strength).cgColor)
        context.setLineWidth(lineWidth * (showsReadout ? 1.0 : 0.70))
        context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
        context.strokePath()

        if strength > 0.5 {
            let glintAngle = start + CGFloat(phase.truncatingRemainder(dividingBy: 1.0)) * CGFloat.pi * 2.0
            let glint = point(center: center, radius: radius, angle: glintAngle)
            context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.38 * strength).cgColor)
            context.fillEllipse(in: CGRect(x: glint.x - 1.8, y: glint.y - 1.8, width: 3.6, height: 3.6))
        }
        context.restoreGState()
    }

    private func drawMissingRing(_ context: CGContext, center: CGPoint, radius: CGFloat, lineWidth: CGFloat, strength: CGFloat) {
        context.saveGState()
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.16 * strength).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.addArc(center: center, radius: radius, startAngle: 0, endAngle: CGFloat.pi * 1.74, clockwise: false)
        context.strokePath()
        context.restoreGState()
    }

    private func drawLimitReadouts(_ context: CGContext, center: CGPoint, outerRadius: CGFloat, innerRadius: CGFloat, bounds: CGRect) {
        var readouts: [LimitReadout] = []
        if let primary = state.primary {
            readouts.append(makeReadout(
                label: "Outer \(windowLabel(for: primary) ?? "short")",
                bucket: primary,
                center: center,
                ringRadius: outerRadius,
                labelRadius: outerRadius + 31.0,
                color: color(forRemaining: primary.remainingPercent, role: .primary),
                bounds: bounds
            ))
        }

        if let secondary = state.secondary {
            readouts.append(makeReadout(
                label: "Inner weekly",
                bucket: secondary,
                center: center,
                ringRadius: innerRadius,
                labelRadius: innerRadius + 34.0,
                color: color(forRemaining: secondary.remainingPercent, role: .secondary),
                bounds: bounds
            ))
        }

        for readout in resolveReadoutOverlaps(readouts, bounds: bounds) {
            drawReadout(context, readout: readout)
        }
    }

    private func makeReadout(
        label: String,
        bucket: LimitBucket,
        center: CGPoint,
        ringRadius: CGFloat,
        labelRadius: CGFloat,
        color: NSColor,
        bounds: CGRect
    ) -> LimitReadout {
        let text = [
            label,
            "\(formatPercent(bucket.remainingPercent)) left",
            resetText(for: bucket)
        ].compactMap { $0 }.joined(separator: "\n")
        let remainingPercent = bucket.remainingPercent
        let angle = -CGFloat.pi / 2.0 + CGFloat(max(remainingPercent, 1.8) / 100.0) * CGFloat.pi * 2.0
        let ringPoint = point(center: center, radius: ringRadius, angle: angle)
        let labelPoint = point(center: center, radius: labelRadius, angle: angle)
        let labelSize = labelSize(for: text)
        var labelRect = CGRect(
            x: labelPoint.x - labelSize.width / 2,
            y: labelPoint.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        labelRect = clamp(labelRect, inside: bounds)
        return LimitReadout(text: text, ringPoint: ringPoint, labelRect: labelRect, color: color, angle: angle)
    }

    private func labelSize(for text: String) -> CGSize {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = lines.map(\.count).max() ?? 4
        return CGSize(
            width: max(74.0, min(128.0, CGFloat(longest) * 6.0 + 16.0)),
            height: CGFloat(lines.count) * 13.0 + 10.0
        )
    }

    private func resolveReadoutOverlaps(_ readouts: [LimitReadout], bounds: CGRect) -> [LimitReadout] {
        guard readouts.count > 1 else { return readouts }
        var resolved = readouts

        let averageAngle = resolved.map(\.angle).reduce(0, +) / CGFloat(resolved.count)
        let tangent = CGPoint(x: -sin(averageAngle), y: cos(averageAngle))
        for index in resolved.indices {
            let direction = index == 0 ? -1.0 : 1.0
            resolved[index].labelRect = clamp(resolved[index].labelRect.offsetBy(dx: tangent.x * 12.0 * direction, dy: tangent.y * 12.0 * direction), inside: bounds)
        }

        for _ in 0..<8 {
            var changed = false
            for firstIndex in 0..<resolved.count {
                for secondIndex in (firstIndex + 1)..<resolved.count {
                    let first = expanded(resolved[firstIndex].labelRect)
                    let second = expanded(resolved[secondIndex].labelRect)
                    guard first.intersects(second) else { continue }

                    let xOverlap = min(first.maxX, second.maxX) - max(first.minX, second.minX)
                    let yOverlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
                    let gap: CGFloat = 6.0
                    if xOverlap <= yOverlap {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midX <= resolved[secondIndex].labelRect.midX ? -1.0 : 1.0
                        let nudge = xOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: direction * nudge, dy: 0)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: -direction * nudge, dy: 0)
                    } else {
                        let direction: CGFloat = resolved[firstIndex].labelRect.midY <= resolved[secondIndex].labelRect.midY ? -1.0 : 1.0
                        let nudge = yOverlap / 2.0 + gap
                        resolved[firstIndex].labelRect = resolved[firstIndex].labelRect.offsetBy(dx: 0, dy: direction * nudge)
                        resolved[secondIndex].labelRect = resolved[secondIndex].labelRect.offsetBy(dx: 0, dy: -direction * nudge)
                    }

                    resolved[firstIndex].labelRect = clamp(resolved[firstIndex].labelRect, inside: bounds)
                    resolved[secondIndex].labelRect = clamp(resolved[secondIndex].labelRect, inside: bounds)
                    changed = true
                }
            }
            if !changed { break }
        }

        return resolved
    }

    private func expanded(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -4.0, dy: -3.0)
    }

    private func clamp(_ rect: CGRect, inside bounds: CGRect) -> CGRect {
        var clamped = rect
        let inset = bounds.insetBy(dx: 4, dy: 4)
        clamped.origin.x = min(max(clamped.minX, inset.minX), inset.maxX - clamped.width)
        clamped.origin.y = min(max(clamped.minY, inset.minY), inset.maxY - clamped.height)
        return clamped
    }

    private func drawReadout(_ context: CGContext, readout: LimitReadout) {
        context.saveGState()
        context.setLineCap(.round)
        context.setStrokeColor(readout.color.withAlphaComponent(0.44).cgColor)
        context.setLineWidth(1.2)
        context.move(to: readout.ringPoint)
        context.addLine(to: CGPoint(x: readout.labelRect.midX, y: readout.labelRect.midY))
        context.strokePath()

        let path = CGPath(roundedRect: readout.labelRect, cornerWidth: 8.0, cornerHeight: 8.0, transform: nil)
        context.setShadow(offset: .zero, blur: 8.0, color: readout.color.withAlphaComponent(0.22).cgColor)
        context.setFillColor(NSColor(calibratedWhite: 0.055, alpha: 0.78).cgColor)
        context.addPath(path)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0.0, color: nil)
        context.setStrokeColor(readout.color.withAlphaComponent(0.42).cgColor)
        context.setLineWidth(1.0)
        context.addPath(path)
        context.strokePath()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9.3, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 1.0, alpha: 0.92),
            .paragraphStyle: centeredParagraphStyle()
        ]
        let attributed = NSAttributedString(string: readout.text, attributes: attrs)
        attributed.draw(in: readout.labelRect.insetBy(dx: 6.0, dy: 5.0))
        context.restoreGState()
    }

    private func drawModelLimitDots(_ context: CGContext, center: CGPoint, radius: CGFloat, state: LimitState, strength: CGFloat) {
        guard strength > 0.5 else { return }
        let dots = Array(state.additional.prefix(8))
        guard dots.count > 0 else { return }
        context.saveGState()
        for (index, item) in dots.enumerated() {
            let angle = -CGFloat.pi / 2.0 + CGFloat(index) / CGFloat(max(dots.count, 1)) * CGFloat.pi * 2.0
            let dot = point(center: center, radius: radius, angle: angle)
            let color = color(forRemaining: item.bucket.remainingPercent, role: .primary)
            context.setShadow(offset: .zero, blur: 5.0, color: color.withAlphaComponent(0.35 * strength).cgColor)
            context.setFillColor(color.withAlphaComponent(0.82 * strength).cgColor)
            context.fillEllipse(in: CGRect(x: dot.x - 2.4, y: dot.y - 2.4, width: 4.8, height: 4.8))
        }
        context.restoreGState()
    }

    private func color(forRemaining remaining: Double, role: RingRole) -> NSColor {
        if remaining <= 12 {
            return NSColor(calibratedRed: 1.00, green: 0.26, blue: 0.22, alpha: 0.96)
        }
        if remaining <= 30 {
            return NSColor(calibratedRed: 1.00, green: 0.68, blue: 0.20, alpha: 0.96)
        }
        if role == .secondary {
            return paletteColor(named: settings.innerColorName)
        }
        return paletteColor(named: settings.outerColorName)
    }

    private func paletteColor(named name: String) -> NSColor {
        switch name {
        case "teal":
            return NSColor(calibratedRed: 0.18, green: 0.86, blue: 0.86, alpha: 0.96)
        case "blue":
            return NSColor(calibratedRed: 0.36, green: 0.70, blue: 1.00, alpha: 0.90)
        case "violet":
            return NSColor(calibratedRed: 0.66, green: 0.50, blue: 1.00, alpha: 0.94)
        case "pink":
            return NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.72, alpha: 0.94)
        case "gold":
            return NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.26, alpha: 0.96)
        case "white":
            return NSColor(calibratedWhite: 0.95, alpha: 0.88)
        default:
            return NSColor(calibratedRed: 0.24, green: 0.92, blue: 0.74, alpha: 0.96)
        }
    }

    private func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }

    private func windowLabel(for bucket: LimitBucket) -> String? {
        guard let minutes = bucket.windowMinutes else { return nil }
        if minutes >= 60 {
            let hours = minutes / 60.0
            if abs(hours.rounded() - hours) < 0.05 {
                return "\(Int(hours.rounded()))h"
            }
            return String(format: "%.1fh", hours)
        }
        return "\(Int(minutes.rounded()))m"
    }

    private func resetText(for bucket: LimitBucket) -> String? {
        guard let resetAt = bucket.resetAt else { return nil }
        let resetDate = Date(timeIntervalSince1970: resetAt)
        let interval = resetDate.timeIntervalSinceNow
        if interval <= 0 {
            return "reset now"
        }

        if interval < 24 * 60 * 60 {
            let formatter = DateFormatter()
            formatter.locale = .current
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "resets \(formatter.string(from: resetDate))"
        }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = interval < 7 * 24 * 60 * 60 ? "EEE h:mm a" : "M/d h:mm a"
        return "resets \(formatter.string(from: resetDate))"
    }

    private func centeredParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        style.lineSpacing = 0
        return style
    }
}

final class LimitRingView: NSView {
    var state: LimitState = .empty {
        didSet { needsDisplay = true }
    }
    var phase: Double = 0 {
        didSet { needsDisplay = true }
    }
    var showsReadout: Bool = false {
        didSet { needsDisplay = true }
    }
    var hoverProgress: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    var settings: RingVisualSettings = .load() {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        LimitRingRenderer(
            state: state,
            phase: phase,
            showsReadout: showsReadout,
            hoverProgress: hoverProgress,
            settings: settings
        ).draw(in: bounds)
    }
}

final class LimitRingsApp: NSObject {
    private let config: LimitRingsConfig
    private let stateReader: LimitStateReader
    private let frameReader: PetFrameReader
    private let panel: NSPanel
    private let ringView: LimitRingView
    private let stateQueue = DispatchQueue(label: "codex-pet-limit-rings.state-reader")
    private var statusItem: NSStatusItem?
    private var summaryItem: NSMenuItem?
    private var showRingsItem: NSMenuItem?
    private var stateTimer: Timer?
    private var frameTimer: Timer?
    private var animationTimer: Timer?
    private var hoverTimer: Timer?
    private var mouseDownMonitor: Any?
    private var mouseDragMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var rightMouseDownMonitor: Any?
    private var startTime = Date()
    private var currentPetFrameAppKit: CGRect?
    private var dragCenterOffset: CGPoint?
    private var holdDraggedFrameUntil: Date?
    private var ringsVisible: Bool
    private var isHovering = false
    private var stateReadInFlight = false

    init(config: LimitRingsConfig) {
        self.config = config
        self.stateReader = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath)
        self.frameReader = PetFrameReader(globalStatePath: config.globalStatePath)
        self.ringView = LimitRingView(frame: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)))
        self.ringsVisible = UserDefaults.standard.object(forKey: ringsVisibleDefaultsKey) as? Bool ?? true
        self.ringView.settings = RingVisualSettings.load()
        self.panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: CGSize(width: config.fallbackSize, height: config.fallbackSize)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.contentView = ringView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        super.init()
    }

    func run() {
        installStatusMenu()
        updateState()
        updateFrame()
        updateRingVisibility()

        stateTimer = Timer.scheduledTimer(withTimeInterval: limitStatePollInterval, repeats: true) { [weak self] _ in
            self?.updateState()
        }
        frameTimer = Timer.scheduledTimer(withTimeInterval: petFramePollInterval, repeats: true) { [weak self] _ in
            self?.updateFrame()
        }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.updateTooltip(at: NSEvent.mouseLocation)
        }
        installDragFollow()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.ringView.phase = Date().timeIntervalSince(self.startTime) / 4.6
            self.updateHoverAnimation()
        }
    }

    private func updateState() {
        guard !stateReadInFlight else { return }
        stateReadInFlight = true
        stateQueue.async { [weak self] in
            guard let self else { return }
            let state = self.stateReader.readLatest()
            DispatchQueue.main.async {
                self.ringView.state = state
                self.updateSummaryMenuItem()
                self.stateReadInFlight = false
            }
        }
    }

    private func updateFrame() {
        if dragCenterOffset != nil {
            return
        }
        if let holdDraggedFrameUntil, Date() < holdDraggedFrameUntil {
            return
        }
        holdDraggedFrameUntil = nil

        guard let petFrame = frameReader.readPetFrameTopLeft() else {
            currentPetFrameAppKit = nil
            dragCenterOffset = nil
            isHovering = false
            ringView.showsReadout = false
            panel.orderOut(nil)
            return
        }

        currentPetFrameAppKit = appKitRectFromTopLeft(petFrame)
        setPanelFrame(forPetFrameTopLeft: petFrame)
        if ringsVisible {
            panel.orderFrontRegardless()
        }
    }

    private func setPanelFrame(forPetFrameTopLeft petFrame: CGRect) {
        let padding: CGFloat = 38
        let size = max(petFrame.width, petFrame.height) + padding * 2
        let topLeft = CGPoint(x: petFrame.midX - size / 2, y: petFrame.midY - size / 2)
        let origin = appKitOriginFromTopLeft(topLeft, size: CGSize(width: size, height: size))

        panel.setFrame(CGRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.title = ""
            button.image = makeStatusBarIcon()
            button.imagePosition = .imageOnly
            button.toolTip = "Codex Pet Limit Rings"
        }

        let menu = NSMenu()
        let summary = NSMenuItem(title: "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Rings", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(settingsMenuItem())

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        updateSummaryMenuItem()
        updateShowRingsMenuItem()
    }

    private func settingsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Ring Settings", action: nil, keyEquivalent: "")
        item.submenu = makeSettingsMenu()
        return item
    }

    private func makeSettingsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(colorSubmenu(title: "Outer Color", keyPath: \.outerColorName, action: #selector(setOuterColor(_:))))
        menu.addItem(colorSubmenu(title: "Inner Color", keyPath: \.innerColorName, action: #selector(setInnerColor(_:))))
        menu.addItem(.separator())
        menu.addItem(valueSubmenu(title: "Idle Visibility", values: [
            ("5%", 0.05),
            ("10%", 0.10),
            ("20%", 0.20),
            ("35%", 0.35)
        ], current: Double(ringView.settings.idleOpacity), action: #selector(setIdleOpacity(_:))))
        menu.addItem(valueSubmenu(title: "Idle Size", values: [
            ("Inside pet", 0.58),
            ("Barely outside", 0.70),
            ("Medium", 0.82)
        ], current: Double(ringView.settings.idleScale), action: #selector(setIdleScale(_:))))
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Ring Settings", action: #selector(resetRingSettings(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        return menu
    }

    private func colorSubmenu(title: String, keyPath: KeyPath<RingVisualSettings, String>, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for option in colorOptions() {
            let child = NSMenuItem(title: option.title, action: action, keyEquivalent: "")
            child.target = self
            child.representedObject = option.name
            child.state = ringView.settings[keyPath: keyPath] == option.name ? .on : .off
            menu.addItem(child)
        }
        item.submenu = menu
        return item
    }

    private func valueSubmenu(title: String, values: [(String, Double)], current: Double, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for value in values {
            let child = NSMenuItem(title: value.0, action: action, keyEquivalent: "")
            child.target = self
            child.representedObject = value.1
            child.state = abs(current - value.1) < 0.001 ? .on : .off
            menu.addItem(child)
        }
        item.submenu = menu
        return item
    }

    private func colorOptions() -> [(title: String, name: String)] {
        [
            ("Mint", "mint"),
            ("Teal", "teal"),
            ("Blue", "blue"),
            ("Violet", "violet"),
            ("Pink", "pink"),
            ("Gold", "gold"),
            ("White", "white")
        ]
    }

    private func makeStatusBarIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.black.setStroke()
        let outer = NSBezierPath()
        outer.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 6.7,
            startAngle: 22,
            endAngle: 338,
            clockwise: false
        )
        outer.lineWidth = 2.0
        outer.lineCapStyle = .round
        outer.stroke()

        let inner = NSBezierPath()
        inner.appendArc(
            withCenter: NSPoint(x: 9, y: 9),
            radius: 3.6,
            startAngle: 210,
            endAngle: 82,
            clockwise: false
        )
        inner.lineWidth = 1.6
        inner.lineCapStyle = .round
        inner.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func updateSummaryMenuItem() {
        guard let summaryItem else { return }
        let primary = ringView.state.primary.map { "Short \(formatPercent($0.remainingPercent))" }
        let secondary = ringView.state.secondary.map { "Weekly \(formatPercent($0.remainingPercent))" }
        let pieces = [primary, secondary].compactMap { $0 }
        if pieces.isEmpty {
            summaryItem.title = "Waiting for Codex limit data"
        } else {
            let source = ringView.state.source == "live" ? "Live" : "Cached"
            summaryItem.title = "\(source) " + pieces.joined(separator: " | ")
        }
    }

    private func updateShowRingsMenuItem() {
        showRingsItem?.state = ringsVisible ? .on : .off
    }

    private func updateRingVisibility() {
        updateShowRingsMenuItem()
        if ringsVisible, currentPetFrameAppKit != nil {
            panel.orderFrontRegardless()
            updateTooltip(at: NSEvent.mouseLocation)
        } else {
            isHovering = false
            ringView.showsReadout = false
            panel.orderOut(nil)
        }
    }

    private func setRingsVisible(_ visible: Bool) {
        ringsVisible = visible
        UserDefaults.standard.set(visible, forKey: ringsVisibleDefaultsKey)
        updateRingVisibility()
    }

    @objc private func toggleRings(_ sender: NSMenuItem) {
        setRingsVisible(!ringsVisible)
    }

    @objc private func refreshNow(_ sender: NSMenuItem) {
        updateState()
        updateFrame()
        updateRingVisibility()
    }

    @objc private func setOuterColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var settings = ringView.settings
        settings.outerColorName = name
        applyRingSettings(settings)
    }

    @objc private func setInnerColor(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        var settings = ringView.settings
        settings.innerColorName = name
        applyRingSettings(settings)
    }

    @objc private func setIdleOpacity(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        var settings = ringView.settings
        settings.idleOpacity = CGFloat(value)
        applyRingSettings(settings)
    }

    @objc private func setIdleScale(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        var settings = ringView.settings
        settings.idleScale = CGFloat(value)
        applyRingSettings(settings)
    }

    @objc private func resetRingSettings(_ sender: NSMenuItem) {
        RingVisualSettings.reset()
        applyRingSettings(.load())
    }

    private func applyRingSettings(_ settings: RingVisualSettings) {
        settings.save()
        ringView.settings = settings
        statusItem?.menu = rebuildStatusMenu()
    }

    private func rebuildStatusMenu() -> NSMenu {
        let menu = NSMenu()
        let summary = NSMenuItem(title: summaryItem?.title ?? "Waiting for Codex limit data", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        summaryItem = summary

        menu.addItem(.separator())

        let showItem = NSMenuItem(title: "Show Rings", action: #selector(toggleRings(_:)), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        showRingsItem = showItem

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow(_:)), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        menu.addItem(settingsMenuItem())
        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Codex Pet Limit Rings", action: #selector(quit(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        updateShowRingsMenuItem()
        updateSummaryMenuItem()
        return menu
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    private func installDragFollow() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.beginDragFollowIfNeeded(at: NSEvent.mouseLocation)
            }
        }
        mouseDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.continueDragFollow(at: NSEvent.mouseLocation)
            }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endDragFollow()
            }
        }
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateTooltip(at: NSEvent.mouseLocation)
            }
        }
        rightMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.showSettingsMenuIfNeeded(at: NSEvent.mouseLocation)
            }
        }
    }

    private func beginDragFollowIfNeeded(at mouse: CGPoint) {
        guard ringsVisible else { return }
        updateFrame()
        guard let currentPetFrameAppKit else { return }
        let hitTarget = currentPetFrameAppKit.insetBy(dx: -24, dy: -24)
        guard hitTarget.contains(mouse) else { return }

        dragCenterOffset = CGPoint(x: panel.frame.midX - mouse.x, y: panel.frame.midY - mouse.y)
        holdDraggedFrameUntil = nil
    }

    private func continueDragFollow(at mouse: CGPoint) {
        guard let offset = dragCenterOffset else { return }
        let size = panel.frame.size
        let center = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        let origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        isHovering = false
        ringView.showsReadout = false
    }

    private func endDragFollow() {
        guard dragCenterOffset != nil else { return }
        dragCenterOffset = nil
        holdDraggedFrameUntil = Date().addingTimeInterval(1.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.30) { [weak self] in
            self?.updateFrame()
        }
    }

    private func updateHoverAnimation() {
        let target: CGFloat = isHovering ? 1.0 : 0.0
        let current = ringView.hoverProgress
        let step: CGFloat = target > current ? 0.16 : 0.12
        let next = current + (target - current) * step
        if abs(next - target) < 0.01 {
            ringView.hoverProgress = target
        } else {
            ringView.hoverProgress = next
        }
    }

    private func updateTooltip(at mouse: CGPoint) {
        if !ringsVisible || currentPetFrameAppKit == nil || dragCenterOffset != nil {
            isHovering = false
            ringView.showsReadout = false
            return
        }

        isHovering = isHoveringRingOrPet(mouse)
        ringView.showsReadout = isHovering
    }

    private func showSettingsMenuIfNeeded(at mouse: CGPoint) {
        guard ringsVisible, isHoveringRingOrPet(mouse) else { return }
        isHovering = true
        ringView.showsReadout = true
        let menu = makeSettingsMenu()
        menu.popUp(positioning: nil, at: mouse, in: nil)
    }

    private func isHoveringRingOrPet(_ mouse: CGPoint) -> Bool {
        if let petFrame = currentPetFrameAppKit,
           petFrame.insetBy(dx: -10, dy: -10).contains(mouse) {
            return true
        }

        let frame = panel.frame
        guard frame.insetBy(dx: -4, dy: -4).contains(mouse) else {
            return false
        }

        let local = CGPoint(x: mouse.x - frame.minX, y: mouse.y - frame.minY)
        let center = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let distance = hypot(local.x - center.x, local.y - center.y)
        let radius = min(frame.width, frame.height) * 0.5 - 16.0
        return distance >= radius - 24.0 && distance <= radius + 19.0
    }

    private func appKitOriginFromTopLeft(_ topLeft: CGPoint, size: CGSize) -> CGPoint {
        let topLeftRect = CGRect(origin: topLeft, size: size)
        guard let screen = screenForTopLeftRect(topLeftRect) else {
            return CGPoint(x: topLeft.x, y: max(0, config.fallbackSize - topLeft.y))
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = topLeft.x - screenTopLeftFrame.minX
        let localY = topLeft.y - screenTopLeftFrame.minY
        return CGPoint(x: screen.frame.minX + localX, y: screen.frame.maxY - localY - size.height)
    }

    private func appKitRectFromTopLeft(_ rect: CGRect) -> CGRect {
        guard let screen = screenForTopLeftRect(rect) else {
            return rect
        }

        let screenTopLeftFrame = topLeftFrame(for: screen)
        let localX = rect.minX - screenTopLeftFrame.minX
        let localY = rect.minY - screenTopLeftFrame.minY
        return CGRect(
            x: screen.frame.minX + localX,
            y: screen.frame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private func screenForTopLeftRect(_ rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        if let screen = screens.first(where: { topLeftFrame(for: $0).contains(center) }) {
            return screen
        }

        return screens.min {
            distanceSquared(center, to: topLeftFrame(for: $0)) < distanceSquared(center, to: topLeftFrame(for: $1))
        }
    }

    private func topLeftFrame(for screen: NSScreen) -> CGRect {
        let primaryMaxY = (primaryScreen() ?? NSScreen.screens.first)?.frame.maxY ?? screen.frame.maxY
        return CGRect(
            x: screen.frame.minX,
            y: primaryMaxY - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first { abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5 }
    }

    private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let clampedX = min(max(point.x, rect.minX), rect.maxX)
        let clampedY = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - clampedX
        let dy = point.y - clampedY
        return dx * dx + dy * dy
    }

    private func formatPercent(_ percent: Double) -> String {
        if abs(percent.rounded() - percent) < 0.05 {
            return "\(Int(percent.rounded()))%"
        }
        return String(format: "%.1f%%", percent)
    }
}

func renderPreview(config: LimitRingsConfig) -> Bool {
    let state = LimitStateReader(logsPath: config.logsPath, authPath: config.authPath).readLatest()
    let size = CGSize(width: config.fallbackSize, height: config.fallbackSize)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.clear.setFill()
    NSRect(origin: .zero, size: size).fill()
    LimitRingRenderer(state: state, phase: 0.18, showsReadout: true).draw(in: CGRect(origin: .zero, size: size))
    image.unlockFocus()

    guard let previewPath = config.previewPath,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        return false
    }

    do {
        try FileManager.default.createDirectory(at: previewPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: previewPath)
        return true
    } catch {
        fputs("codex-pet-limit-rings: could not write preview: \(error)\n", stderr)
        return false
    }
}

func parseConfig() -> LimitRingsConfig? {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let codexHome = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path)
    var config = LimitRingsConfig(
        codexHome: codexHome,
        globalStatePath: codexHome.appendingPathComponent(".codex-global-state.json"),
        logsPath: defaultLogsPath(codexHome: codexHome),
        authPath: codexHome.appendingPathComponent("auth.json"),
        previewPath: nil
    )

    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--help", "-h":
            print("""
            Usage: codex-pet-limit-rings [--preview PATH] [--codex-home PATH] [--logs PATH] [--auth PATH] [--state PATH]

            Draws a transparent Codex rate-limit rings around the current pet.
            """)
            exit(0)
        case "--preview":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.previewPath = URL(fileURLWithPath: value)
        case "--codex-home":
            guard let value = args.first else { return nil }
            args.removeFirst()
            let url = URL(fileURLWithPath: value)
            config.codexHome = url
            config.globalStatePath = url.appendingPathComponent(".codex-global-state.json")
            config.logsPath = defaultLogsPath(codexHome: url)
            config.authPath = url.appendingPathComponent("auth.json")
        case "--logs":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.logsPath = URL(fileURLWithPath: value)
        case "--auth":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.authPath = URL(fileURLWithPath: value)
        case "--state":
            guard let value = args.first else { return nil }
            args.removeFirst()
            config.globalStatePath = URL(fileURLWithPath: value)
        case "--size":
            guard let value = args.first, let size = Double(value) else { return nil }
            args.removeFirst()
            config.fallbackSize = CGFloat(size)
        default:
            fputs("codex-pet-limit-rings: unknown argument \(arg)\n", stderr)
            return nil
        }
    }

    return config
}

func defaultLogsPath(codexHome: URL) -> URL {
    let logs2 = codexHome.appendingPathComponent("logs_2.sqlite")
    if FileManager.default.fileExists(atPath: logs2.path) {
        return logs2
    }
    return codexHome.appendingPathComponent("logs_1.sqlite")
}

guard let config = parseConfig() else {
    fputs("codex-pet-limit-rings: invalid arguments. Use --help.\n", stderr)
    exit(2)
}

if config.previewPath != nil {
    exit(renderPreview(config: config) ? 0 : 1)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let rings = LimitRingsApp(config: config)
rings.run()
app.run()
