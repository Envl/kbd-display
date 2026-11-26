import Cocoa
import ImageIO

struct KeyHint: Codable, Hashable {
    let keyCode: UInt16
    let label: String
    let symbol: String
    var iconID: String? = nil

    var isFunctional: Bool { iconID == nil }
}

struct HintProvider: Codable, Hashable {
    let id: String
    let pid: Int32
}

struct HintFrame: Codable {
    let provider: HintProvider
    let title: String?
    let hints: [KeyHint]
    var press: UInt16?
}

final class HintReceiver: NSObject {
    private final class Registration {
        let provider: HintProvider
        let lifetime: DispatchSourceProcess
        var snapshot: HintFrame?

        init(_ provider: HintProvider) {
            self.provider = provider
            lifetime = DispatchSource.makeProcessSource(identifier: provider.pid, eventMask: .exit, queue: .main)
        }

        deinit { lifetime.cancel() }
    }

    private struct IconRequest: Encodable {
        let provider: HintProvider
        let iconID: String
    }

    private struct IconReply: Decodable {
        let provider: HintProvider
        let iconID: String
        let png: Data
    }

    private let center = DistributedNotificationCenter.default()
    private let namespace: String
    // Most recently active registration is last. Idle providers retain their exit monitor.
    private var registrations: [Registration] = []
    private var displayed: HintProvider?
    private var expected: Set<String> = []
    private let cache = NSCache<NSString, KeyArtwork>()
    private var pending: Set<String> = []
    private var retry: DispatchWorkItem?
    private let onUpdate: (HintFrame?) -> Void
    private let onIcon: (String, KeyArtwork) -> Void

    init(namespace: String = "kbd-display.v2", onIcon: @escaping (String, KeyArtwork) -> Void = { _, _ in },
         onUpdate: @escaping (HintFrame?) -> Void) {
        self.namespace = namespace
        self.onIcon = onIcon
        self.onUpdate = onUpdate
        super.init()
        cache.countLimit = 256
        observe("register", #selector(register))
        observe("state", #selector(receive))
        observe("unregister", #selector(unregister))
        observe("icon", #selector(receiveIcon))
        requestState()
    }

    private func observe(_ topic: String, _ selector: Selector) {
        center.addObserver(self, selector: selector, name: .init("\(namespace).\(topic)"),
                           object: nil, suspensionBehavior: .deliverImmediately)
    }

    func requestState() {
        registrations.removeAll()
        render()
        center.postNotificationName(.init("\(namespace).discover"), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func decode<T: Decodable>(_ type: T.Type, from notification: Notification, limit: Int = 65536) -> T? {
        guard let json = notification.object as? String, json.utf8.count <= limit else { return nil }
        return try? JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @objc private func register(_ notification: Notification) {
        guard var frame = decode(HintFrame.self, from: notification), frame.hints.count <= 128 else { return }
        let provider = frame.provider
        guard provider.pid > 0, !provider.id.isEmpty, provider.id.utf8.count <= 255 else { return }
        frame.press = nil // Discovery snapshots must never replay input.
        if let existing = registrations.first(where: { $0.provider == provider }) {
            if existing.snapshot?.title == frame.title && (existing.snapshot?.hints ?? []) == frame.hints { return }
        } else {
            guard registrations.count < 128, kill(provider.pid, 0) == 0 else { return }
            let entry = Registration(provider)
            entry.lifetime.setEventHandler { [weak self, weak entry] in
                if let entry { self?.remove(entry) }
            }
            registrations.append(entry)
            entry.lifetime.resume()
        }
        update(frame)
    }

    @objc private func receive(_ notification: Notification) {
        guard let frame = decode(HintFrame.self, from: notification), frame.hints.count <= 128 else { return }
        update(frame)
    }

    private func update(_ frame: HintFrame) {
        guard let index = registrations.firstIndex(where: { $0.provider == frame.provider }) else { return }
        let entry = registrations.remove(at: index)
        var snapshot = frame
        snapshot.press = nil
        entry.snapshot = frame.title == nil && frame.hints.isEmpty ? nil : snapshot
        registrations.append(entry)
        render(updated: frame.provider, press: frame.press)
    }

    @objc private func unregister(_ notification: Notification) {
        guard let provider = decode(HintProvider.self, from: notification),
              let entry = registrations.first(where: { $0.provider == provider }) else { return }
        remove(entry)
    }

    private func remove(_ entry: Registration) {
        registrations.removeAll { $0 === entry }
        render()
    }

    private func render(updated: HintProvider? = nil, press: UInt16? = nil) {
        var frame = registrations.last(where: { $0.snapshot != nil })?.snapshot
        let selected = frame?.provider
        if selected != displayed {
            displayed = selected
            expected.removeAll()
            pending.removeAll()
            cache.removeAllObjects()
            retry?.cancel()
            retry = nil
        } else if selected == nil || selected != updated {
            return
        }
        if selected == updated { frame?.press = press }
        onUpdate(frame)
        guard let frame else { return }
        let ids = Set(frame.hints.compactMap(\.iconID))
        let added = ids.subtracting(expected)
        expected = ids
        pending.formIntersection(ids)
        for id in added {
            if let image = cache.object(forKey: id as NSString) {
                onIcon(id, image)
            } else {
                pending.insert(id)
                request(id, provider: frame.provider)
            }
        }
        scheduleRetry()
    }

    private func request(_ id: String, provider: HintProvider) {
        guard let data = try? JSONEncoder().encode(IconRequest(provider: provider, iconID: id)),
              let json = String(data: data, encoding: .utf8) else { return }
        center.postNotificationName(.init("\(namespace).requestIcon"), object: json, userInfo: nil, deliverImmediately: true)
    }

    private func scheduleRetry() {
        guard !pending.isEmpty, retry == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self, let provider = self.displayed else { return }
            self.retry = nil
            for id in self.pending { self.request(id, provider: provider) }
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    @objc private func receiveIcon(_ notification: Notification) {
        guard let icon = decode(IconReply.self, from: notification, limit: 48 * 1024),
              icon.provider == displayed, pending.contains(icon.iconID),
              let source = CGImageSourceCreateWithData(icon.png as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              props[kCGImagePropertyPixelWidth] as? Int == 64, props[kCGImagePropertyPixelHeight] as? Int == 64,
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let image = KeyArtwork(NSImage(cgImage: cg, size: NSSize(width: 64, height: 64)))
        pending.remove(icon.iconID)
        cache.setObject(image, forKey: icon.iconID as NSString)
        onIcon(icon.iconID, image)
    }

    deinit {
        center.removeObserver(self)
        retry?.cancel()
    }
}
