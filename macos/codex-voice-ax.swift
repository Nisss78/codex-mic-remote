import ApplicationServices
import AppKit
import Foundation

// Codex Mic Remote only acts on visible, labelled Codex controls. It never
// changes the macOS-wide microphone state and does not use global keyboard
// shortcuts, which could otherwise land in a different app.
let microphoneLabels = ["マイクをミュート", "Unmute microphone", "Mute microphone", "マイクのミュートを解除"]
let newChatLabels = ["New chat", "New Chat", "New task", "New Task", "新しいチャット", "新規チャット", "新しいタスク", "新規タスク", "新しいタブ"]
// Do not add 「音声入力」 here. It is dictation, not Codex Voice conversation.
let startVoiceLabels = ["Start voice conversation", "Start Voice conversation", "Start voice mode", "音声会話を開始", "音声モードを開始"]
let modelNames = ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
let effortNames = ["low", "medium", "high", "xhigh", "max"]

struct Capability: Encodable {
    let available: Bool
    let error: String?
}

struct Capabilities: Encodable {
    let newChat: Capability
    let startVoice: Capability
    let model: Capability
    let effort: Capability
}

struct CurrentSettings: Encodable {
    let model: String?
    let effort: String?
}

struct PickerChoices: Encodable {
    let models: [String]
    let efforts: [String]
}

struct Result: Encodable {
    let ok: Bool
    let available: Bool
    let muted: Bool?
    let label: String?
    let error: String?
    let capabilities: Capabilities?
    let action: String?
    let current: CurrentSettings?
    let choices: PickerChoices?
    let targetWindow: String?
    let permissionRequired: Bool

    init(ok: Bool, available: Bool, muted: Bool?, label: String?, error: String?, capabilities: Capabilities?, action: String?, current: CurrentSettings? = nil, choices: PickerChoices? = nil, targetWindow: String? = nil, permissionRequired: Bool = false) {
        self.ok = ok; self.available = available; self.muted = muted; self.label = label; self.error = error
        self.capabilities = capabilities; self.action = action; self.current = current; self.choices = choices; self.targetWindow = targetWindow; self.permissionRequired = permissionRequired
    }
}

func emit(_ result: Result) {
    let data = try! JSONEncoder().encode(result)
    print(String(data: data, encoding: .utf8)!)
}

func string(_ element: AXUIElement, _ attribute: CFString) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
    return value as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let list = value as? [AXUIElement] else { return [] }
    return list
}

func element(_ source: AXUIElement, _ attribute: CFString) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(source, attribute, &value) == .success else { return nil }
    return (value as! AXUIElement)
}

func enabled(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success else { return true }
    return (value as? Bool) ?? true
}

func textValues(_ element: AXUIElement) -> [String] {
    [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute, kAXHelpAttribute]
        .compactMap { string(element, $0 as CFString) }
}

func normal(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func compact(_ text: String) -> String {
    normal(text).replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: " ", with: "")
}

func role(_ element: AXUIElement) -> String? {
    string(element, kAXRoleAttribute as CFString)
}

func hasExactText(_ element: AXUIElement, _ labels: [String]) -> String? {
    textValues(element).first { value in labels.contains { normal($0) == normal(value) } }
}

func hasTextContaining(_ element: AXUIElement, _ needles: [String]) -> Bool {
    textValues(element).contains { value in
        let candidate = normal(value)
        return needles.contains { candidate.contains(normal($0)) }
    }
}

func isPressableControl(_ element: AXUIElement) -> Bool {
    [kAXButtonRole, kAXPopUpButtonRole, kAXMenuItemRole].contains { role(element) == $0 }
}

func find(_ element: AXUIElement, depth: Int = 0, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    guard depth < 45 else { return nil }
    if predicate(element) { return element }
    for child in children(element) {
        if let result = find(child, depth: depth + 1, where: predicate) { return result }
    }
    return nil
}

func findAll(_ element: AXUIElement, depth: Int = 0, where predicate: (AXUIElement) -> Bool) -> [AXUIElement] {
    guard depth < 45 else { return [] }
    var result = predicate(element) ? [element] : []
    for child in children(element) { result += findAll(child, depth: depth + 1, where: predicate) }
    return result
}

func findPressableWithExactText(_ root: AXUIElement, _ labels: [String]) -> (AXUIElement, String)? {
    guard let element = find(root, where: { isPressableControl($0) && hasExactText($0, labels) != nil }),
          let text = hasExactText(element, labels) else { return nil }
    return (element, text)
}

func findMenuItemWithExactText(_ root: AXUIElement, _ labels: [String]) -> (AXUIElement, String)? {
    guard let item = find(root, where: { role($0) == kAXMenuItemRole && enabled($0) && hasExactText($0, labels) != nil }),
          let text = hasExactText(item, labels) else { return nil }
    return (item, text)
}

func findMenuChoice(_ root: AXUIElement, requested: String, isModel: Bool) -> AXUIElement? {
    find(root, where: { element in
        guard role(element) == kAXMenuItemRole && enabled(element) else { return false }
        return textValues(element).contains { value in
            let candidate = isModel ? canonicalModel(value) : canonicalEffort(value)
            return candidate == requested
        }
    })
}

func findMicButton(_ root: AXUIElement) -> (AXUIElement, String)? {
    findPressableWithExactText(root, microphoneLabels)
}

func findModelPicker(_ root: AXUIElement) -> AXUIElement? {
    find(root, where: { element in
        guard role(element) == kAXButtonRole || role(element) == kAXPopUpButtonRole else { return false }
        return textValues(element).contains { canonicalModel($0) != nil } || hasTextContaining(element, ["model", "モデル"])
    })
}

func findEffortPicker(_ root: AXUIElement) -> AXUIElement? {
    find(root, where: { element in
        guard role(element) == kAXButtonRole || role(element) == kAXPopUpButtonRole else { return false }
        return hasTextContaining(element, ["reasoning", "effort", "推論", "思考", "エフォート"])
    }) ?? findModelPicker(root) // Current Codex combines model and effort in one popup, e.g. "GPT-5.6 Terra 中".
}

func canonical(_ value: String, in values: [String]) -> String? {
    values.first { normal($0) == normal(value) }
}

func canonicalModel(_ value: String) -> String? {
    let candidate = compact(value)
    return modelNames.first { candidate.hasPrefix(compact($0)) }
}

func canonicalEffort(_ value: String) -> String? {
    if let exact = canonical(value, in: effortNames) { return exact }
    let candidate = normal(value)
    if candidate == "低" || candidate.hasSuffix(" low") { return "low" }
    if candidate == "中" || candidate.hasSuffix(" 中") || candidate.hasSuffix(" medium") { return "medium" }
    if candidate == "高" || candidate.hasSuffix(" high") { return "high" }
    if candidate == "最高" || candidate.hasSuffix(" extra high") { return "xhigh" }
    if candidate == "最大" || candidate.hasSuffix(" max") { return "max" }
    return nil
}

func activeWindow(_ app: AXUIElement) -> AXUIElement? {
    element(app, kAXFocusedWindowAttribute as CFString)
}

func currentSettings(_ root: AXUIElement) -> CurrentSettings {
    let model = findModelPicker(root).flatMap { picker in textValues(picker).compactMap(canonicalModel).first }
    let effort = findEffortPicker(root).flatMap { picker in textValues(picker).compactMap(canonicalEffort).first }
    return CurrentSettings(model: model, effort: effort)
}

func openedMenu(_ app: AXUIElement) -> AXUIElement? {
    var current = element(app, kAXFocusedUIElementAttribute as CFString)
    for _ in 0..<8 {
        guard let item = current else { return nil }
        if role(item) == kAXMenuRole { return item }
        current = element(item, kAXParentAttribute as CFString)
    }
    return nil
}

func visibleMenuChoices(_ menu: AXUIElement, matching allowed: [String]) -> [String] {
    var result: [String] = []
    for item in findAll(menu, where: { role($0) == kAXMenuItemRole && enabled($0) }) {
        for value in textValues(item) {
            let match = allowed == modelNames ? canonicalModel(value) : canonicalEffort(value)
            if let match, !result.contains(match) { result.append(match) }
        }
    }
    return result
}

func discoverChoices(_ app: AXUIElement, root: AXUIElement) -> PickerChoices {
    var models: [String] = []
    var efforts: [String] = []
    if let picker = findModelPicker(root), AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success {
        waitForMenu()
        if let menu = openedMenu(app) { models = visibleMenuChoices(menu, matching: modelNames) }
    }
    if let picker = findEffortPicker(root), AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success {
        waitForMenu()
        if let menu = openedMenu(app) { efforts = visibleMenuChoices(menu, matching: effortNames) }
    }
    return PickerChoices(models: models, efforts: efforts)
}

func capabilities(_ root: AXUIElement) -> Capabilities {
    Capabilities(
        newChat: Capability(available: findPressableWithExactText(root, newChatLabels) != nil,
                            error: "A visible New chat control was not found."),
        startVoice: Capability(available: findPressableWithExactText(root, startVoiceLabels) != nil,
                               error: "A visible Start voice conversation control was not found."),
        model: Capability(available: findModelPicker(root) != nil,
                          error: "A visible model picker was not found."),
        effort: Capability(available: findEffortPicker(root) != nil,
                           error: "A visible reasoning-effort picker was not found.")
    )
}

func press(_ element: AXUIElement, action: String, root: AXUIElement, successLabel: String) {
    let outcome = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard outcome == .success else {
        emit(Result(ok: false, available: true, muted: nil, label: nil,
                    error: "\(action) could not be pressed (AX error \(outcome.rawValue)).",
                    capabilities: capabilities(root), action: action))
        exit(1)
    }
    emit(Result(ok: true, available: true, muted: nil, label: successLabel,
                error: nil, capabilities: capabilities(root), action: action))
}

func unavailable(_ action: String, _ message: String, _ root: AXUIElement) -> Never {
    emit(Result(ok: false, available: false, muted: nil, label: nil, error: message,
                capabilities: capabilities(root), action: action))
    exit(0)
}

func waitForMenu() {
    // AX menu population is asynchronous. This happens only after an explicit,
    // authenticated configuration request from the paired phone.
    RunLoop.current.run(until: Date().addingTimeInterval(0.15))
}

let command = CommandLine.arguments.dropFirst().first ?? "status"
guard AXIsProcessTrusted() else {
    if command == "request-accessibility" {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    emit(Result(ok: false, available: false, muted: nil, label: nil,
                error: "Accessibility permission is required for Codex Mic Remote.", capabilities: nil, action: command, permissionRequired: true))
    exit(2)
}

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
guard let app = apps.first else {
    emit(Result(ok: true, available: false, muted: nil, label: nil,
                error: "Codex desktop app is not running.", capabilities: nil, action: nil))
    exit(0)
}

let appElement = AXUIElementCreateApplication(app.processIdentifier)
guard let root = activeWindow(appElement) else {
    emit(Result(ok: true, available: false, muted: nil, label: nil,
                error: "No focused Codex window was found. Bring the target Codex chat to the front.", capabilities: nil, action: command))
    exit(0)
}
let targetWindow = string(root, kAXTitleAttribute as CFString)

switch command {
case "status":
    let found = findMicButton(root)
    if let found {
        let isMuted = found.1 == "Unmute microphone" || found.1 == "マイクのミュートを解除"
        emit(Result(ok: true, available: true, muted: isMuted, label: found.1, error: nil,
                    capabilities: capabilities(root), action: nil, current: currentSettings(root), targetWindow: targetWindow))
    } else {
        emit(Result(ok: true, available: false, muted: nil, label: nil,
                    error: "No active Codex Voice microphone control was found.", capabilities: capabilities(root), action: nil, current: currentSettings(root), targetWindow: targetWindow))
    }
case "toggle":
    guard let found = findMicButton(root) else {
        unavailable("toggle", "No active Codex Voice microphone control was found.", root)
    }
    press(found.0, action: "toggle", root: root, successLabel: found.1)
case "new-chat":
    guard let found = findPressableWithExactText(root, newChatLabels) else {
        unavailable("new-chat", "A visible New chat control was not found.", root)
    }
    press(found.0, action: "new-chat", root: root, successLabel: found.1)
case "start-voice":
    guard let found = findPressableWithExactText(root, startVoiceLabels) else {
        unavailable("start-voice", "A visible Start voice conversation control was not found.", root)
    }
    press(found.0, action: "start-voice", root: root, successLabel: found.1)
case "choices":
    let found = discoverChoices(appElement, root: root)
    emit(Result(ok: !found.models.isEmpty || !found.efforts.isEmpty, available: true, muted: nil, label: nil,
                error: (found.models.isEmpty && found.efforts.isEmpty) ? "No visible configuration choices were found." : nil,
                capabilities: capabilities(root), action: "choices", current: currentSettings(root), choices: found, targetWindow: targetWindow))
case "set-model":
    guard let requested = CommandLine.arguments.dropFirst(2).first,
          modelNames.contains(where: { normal($0) == normal(requested) }) else {
        unavailable("set-model", "The requested model is not supported by this remote.", root)
    }
    guard let picker = findModelPicker(root) else {
        unavailable("set-model", "A visible model picker was not found.", root)
    }
    guard AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success else {
        unavailable("set-model", "The model picker could not be opened.", root)
    }
    waitForMenu()
    guard let menu = openedMenu(appElement), let choice = findMenuChoice(menu, requested: requested, isModel: true) else {
        unavailable("set-model", "\(requested) is not available in this Codex model picker.", root)
    }
    press(choice, action: "set-model", root: root, successLabel: requested)
case "set-effort":
    guard let requested = CommandLine.arguments.dropFirst(2).first,
          effortNames.contains(where: { normal($0) == normal(requested) }) else {
        unavailable("set-effort", "The requested reasoning effort is not supported by this remote.", root)
    }
    guard let picker = findEffortPicker(root) else {
        unavailable("set-effort", "A visible reasoning-effort picker was not found.", root)
    }
    guard AXUIElementPerformAction(picker, kAXPressAction as CFString) == .success else {
        unavailable("set-effort", "The reasoning-effort picker could not be opened.", root)
    }
    waitForMenu()
    guard let menu = openedMenu(appElement), let choice = findMenuChoice(menu, requested: requested, isModel: false) else {
        unavailable("set-effort", "\(requested) is not available in this Codex reasoning-effort picker.", root)
    }
    press(choice, action: "set-effort", root: root, successLabel: requested)
default:
    emit(Result(ok: false, available: false, muted: nil, label: nil,
                error: "Unsupported action.", capabilities: capabilities(root), action: command))
    exit(64)
}
