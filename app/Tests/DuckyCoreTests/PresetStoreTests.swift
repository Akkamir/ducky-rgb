import XCTest
@testable import DuckyCore

@MainActor
final class PresetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var file: URL { directory.appendingPathComponent("presets.json") }

    func testStartsWithBuiltInsOnly() {
        let store = PresetStore(fileURL: file)
        XCTAssertEqual(store.all.map(\.name), Preset.builtIns.map(\.name))
        XCTAssertNil(store.loadError)
    }

    func testUserPresetsSurviveReload() {
        var overlay = [RGB?](repeating: nil, count: 68)
        overlay[17] = RGB(255, 0, 0)
        let store = PresetStore(fileURL: file)
        store.add(Preset(name: "Mien", base: BaseSettings(effectID: 2), overlay: overlay))
        let reloaded = PresetStore(fileURL: file)
        XCTAssertEqual(reloaded.userPresets.count, 1)
        XCTAssertEqual(reloaded.userPresets[0].name, "Mien")
        XCTAssertEqual(reloaded.userPresets[0].overlayColors(), overlay)
    }

    func testRenameDuplicateDelete() throws {
        let store = PresetStore(fileURL: file)
        let preset = Preset(name: "A", base: BaseSettings(), overlay: [])
        store.add(preset)
        store.rename(id: preset.id, to: "B")
        let copy = try XCTUnwrap(store.duplicate(id: preset.id))
        XCTAssertEqual(copy.name, "B (copie)")
        store.delete(id: preset.id)
        XCTAssertEqual(store.userPresets.map(\.name), ["B (copie)"])
    }

    func testBuiltInsCannotBeDeletedOrRenamed() {
        let store = PresetStore(fileURL: file)
        let builtIn = Preset.builtIns[0]
        store.delete(id: builtIn.id)
        store.rename(id: builtIn.id, to: "X")
        XCTAssertEqual(store.all.first?.name, builtIn.name)
        XCTAssertNotNil(store.duplicate(id: builtIn.id))
    }

    func testCorruptFileIsSetAside() throws {
        try Data("not json".utf8).write(to: file)
        let store = PresetStore(fileURL: file)
        XCTAssertNotNil(store.loadError)
        XCTAssertEqual(store.all.count, Preset.builtIns.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path + ".corrupt"))
    }

    func testMatches() {
        let preset = Preset.builtIns[0]
        XCTAssertTrue(preset.matches(base: preset.base, overlay: preset.overlayColors()))
        var other = preset.base
        other.speed &+= 1
        XCTAssertFalse(preset.matches(base: other, overlay: preset.overlayColors()))
    }
}
