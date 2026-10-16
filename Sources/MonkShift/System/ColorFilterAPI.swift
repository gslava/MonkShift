import AppKit
import MonkShiftCore
import Darwin

/// Private symbols are isolated here. No compile-time link to private frameworks.
final class ColorFilterAPI {
    struct State: Codable {
        let enabled: Bool
        let type: Int32
        let intensity: Double
    }
    private let media: UnsafeMutableRawPointer
    private let universal: UnsafeMutableRawPointer
    private let getEnabled: @convention(c) (Int32) -> Bool
    private let setEnabled: @convention(c) (Int32, Bool) -> Void
    private let getType: @convention(c) (Int32) -> Int32
    private let setType: @convention(c) (Int32, Int32) -> Void
    private let getIntensity: @convention(c) () -> Double
    private let setIntensity: @convention(c) (Double) -> Void
    private let startDaemon: @convention(c) (Int32) -> Void
    private var ownsHandles = false
    let minimum: Double
    let maximum: Double

    init() throws {
        guard let media = dlopen("/System/Library/Frameworks/MediaAccessibility.framework/MediaAccessibility", RTLD_LAZY) else {
            throw MonkError("System color filter APIs are unavailable.")
        }
        guard let universal = dlopen("/System/Library/PrivateFrameworks/UniversalAccess.framework/UniversalAccess", RTLD_LAZY) else {
            dlclose(media)
            throw MonkError("The system color filter activation API is unavailable.")
        }
        self.media = media
        self.universal = universal
        func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw MonkError("This macOS version does not expose \(name).") }
            return unsafeBitCast(pointer, to: T.self)
        }
        do {
            getEnabled = try symbol(media, "MADisplayFilterPrefGetCategoryEnabled", (@convention(c) (Int32) -> Bool).self)
            setEnabled = try symbol(media, "MADisplayFilterPrefSetCategoryEnabled", (@convention(c) (Int32, Bool) -> Void).self)
            getType = try symbol(media, "MADisplayFilterPrefGetType", (@convention(c) (Int32) -> Int32).self)
            setType = try symbol(media, "MADisplayFilterPrefSetType", (@convention(c) (Int32, Int32) -> Void).self)
            getIntensity = try symbol(media, "MADisplayFilterPrefGetGrayscaleCorrectionIntensity", (@convention(c) () -> Double).self)
            setIntensity = try symbol(media, "MADisplayFilterPrefSetGrayscaleCorrectionIntensity", (@convention(c) (Double) -> Void).self)
            startDaemon = try symbol(universal, "_UniversalAccessDStart", (@convention(c) (Int32) -> Void).self)
            guard let minPointer = dlsym(media, "kMADisplayFilterPrefGrayscaleIntensityMin"),
                  let maxPointer = dlsym(media, "kMADisplayFilterPrefGrayscaleIntensityMax") else {
                throw MonkError("The system color filter intensity range is unavailable.")
            }
            minimum = minPointer.assumingMemoryBound(to: Double.self).pointee
            maximum = maxPointer.assumingMemoryBound(to: Double.self).pointee
            guard minimum.isFinite, maximum.isFinite, maximum > minimum else {
                throw MonkError("The system returned an invalid color filter intensity range.")
            }
            ownsHandles = true
        } catch {
            dlclose(media)
            dlclose(universal)
            throw error
        }
    }

    deinit { if ownsHandles { dlclose(media); dlclose(universal) } }
    func read() -> State { State(enabled: getEnabled(1), type: getType(1), intensity: getIntensity()) }
    func normalizedIntensity() -> Double { min(1, max(0, (getIntensity() - minimum) / (maximum - minimum))) }
    func apply(intensity: Double) throws {
        guard intensity.isFinite else { throw MonkError("Color filter intensity must be a finite number.") }
        setType(1, 1)
        setIntensity(minimum + min(1, max(0, intensity)) * (maximum - minimum))
        setEnabled(1, true)
        startDaemon(8)
        let actual = read()
        guard actual.enabled, actual.type == 1,
              abs(actual.intensity - (minimum + min(1, max(0, intensity)) * (maximum - minimum))) < 0.01 else {
            throw MonkError("macOS did not retain the grayscale settings. The previous settings are saved for restoration.")
        }
    }
    func disable() { setEnabled(1, false); startDaemon(8) }
    func restore(_ state: State) throws {
        setIntensity(state.intensity)
        setType(1, state.type)
        setEnabled(1, state.enabled)
        startDaemon(8)
        let actual = read()
        guard actual.enabled == state.enabled, actual.type == state.type, abs(actual.intensity - state.intensity) < 0.01 else {
            throw MonkError("macOS did not restore the saved color filter settings.")
        }
    }
}
