import Foundation
import Testing
@testable import SVSLabelRenamer

@Test @MainActor func switchingFoldersCannotMixResultsFromCancelledScan() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SVSLabelRenamerScanTests-\(UUID().uuidString)")
    let first = root.appendingPathComponent("first", isDirectory: true)
    let second = root.appendingPathComponent("second", isDirectory: true)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data([1]).write(to: first.appendingPathComponent("old.svs"))
    try Data([2]).write(to: second.appendingPathComponent("new.svs"))
    defer { try? FileManager.default.removeItem(at: root) }

    let model = AppModel { file, _ in
        let delay: Duration = file.lastPathComponent == "old.svs" ? .milliseconds(180) : .milliseconds(10)
        _ = await Task.detached {
            try? await Task.sleep(for: delay)
        }.value
        return SlideRecord(sourceURL: file)
    }

    model.openFolder(first)
    try await Task.sleep(for: .milliseconds(20))
    model.openFolder(second)
    await model.waitForCurrentScan()
    try await Task.sleep(for: .milliseconds(220))

    #expect(
        model.selectedFolder?.resolvingSymlinksInPath().path
            == second.resolvingSymlinksInPath().path
    )
    #expect(model.records.map(\.originalFilename) == ["new.svs"])
    #expect(model.completedCount == 1)
    #expect(model.totalCount == 1)
    #expect(!model.isWorking)
}

@Test @MainActor func openingOneSVSProcessesOnlyThatFile() async throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("SVSLabelRenamerSingleFileTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let first = folder.appendingPathComponent("first.svs")
    let target = folder.appendingPathComponent(".target.svs")
    try Data([1]).write(to: first)
    try Data([2]).write(to: target)
    defer { try? FileManager.default.removeItem(at: folder) }

    let model = AppModel { file, _ in SlideRecord(sourceURL: file) }
    model.openFolder(target)
    await model.waitForCurrentScan()

    #expect(
        model.selectedFolder?.resolvingSymlinksInPath().path
            == folder.resolvingSymlinksInPath().path
    )
    #expect(model.records.map(\.originalFilename) == [".target.svs"])
    #expect(model.completedCount == 1)
    #expect(model.totalCount == 1)
}

@Test @MainActor func scanFollowsFolderRenameBetweenFiles() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SVSLabelRenamerFolderRenameTests-\(UUID().uuidString)")
    let original = root.appendingPathComponent("before", isDirectory: true)
    let renamed = root.appendingPathComponent("after", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    try Data([1]).write(to: original.appendingPathComponent("first.svs"))
    try Data([2]).write(to: original.appendingPathComponent("second.svs"))
    defer { try? FileManager.default.removeItem(at: root) }

    let model = AppModel { file, output in
        var record = SlideRecord(sourceURL: file)
        record.labelImageURL = output.appendingPathComponent(
            file.deletingPathExtension().lastPathComponent + "_label.png"
        )
        record.macroImageURL = output.appendingPathComponent(
            file.deletingPathExtension().lastPathComponent + "_macro.png"
        )
        record.overviewImageURL = output.appendingPathComponent(
            file.deletingPathExtension().lastPathComponent + "_overview.png"
        )
        if file.lastPathComponent == "second.svs",
           FileManager.default.fileExists(atPath: original.path) {
            try? FileManager.default.moveItem(at: original, to: renamed)
        }
        return record
    }
    model.openFolder(original)
    await model.waitForCurrentScan()

    #expect(model.records.map(\.originalFilename) == ["first.svs", "second.svs"])
    #expect(model.records.allSatisfy {
        $0.sourceURL.deletingLastPathComponent().lastPathComponent == "after"
    })
    #expect(model.records.allSatisfy {
        $0.labelImageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent == "after"
    })
    #expect(model.records.allSatisfy {
        $0.macroImageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent == "after"
    })
    #expect(model.records.allSatisfy {
        $0.overviewImageURL?.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent == "after"
    })
    #expect(model.selectedFolder?.lastPathComponent == "after")
    #expect(FileManager.default.fileExists(
        atPath: renamed.appendingPathComponent("SVS_Label_Renamer_Output/rename_preview.csv").path
    ))
}

@Test @MainActor func renameAndUndoFollowFolderMovesAfterScan() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SVSLabelRenamerPostScanMoveTests-\(UUID().uuidString)")
    let original = root.appendingPathComponent("original", isDirectory: true)
    let afterScan = root.appendingPathComponent("after-scan", isDirectory: true)
    let afterRename = root.appendingPathComponent("after-rename", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    let source = original.appendingPathComponent("sample.svs")
    try Data([1]).write(to: source)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = AppModel { file, _ in
        SlideRecord(
            sourceURL: file,
            pathologyNumber: "K1234",
            stain: "HE",
            extractionSucceeded: true,
            isConfirmed: true
        )
    }
    model.openFolder(original)
    await model.waitForCurrentScan()

    try FileManager.default.moveItem(at: original, to: afterScan)
    model.applyRename()
    #expect(FileManager.default.fileExists(
        atPath: afterScan.appendingPathComponent("K1234_HE.svs").path
    ))

    try FileManager.default.moveItem(at: afterScan, to: afterRename)
    model.undoLastRename()
    #expect(FileManager.default.fileExists(
        atPath: afterRename.appendingPathComponent("sample.svs").path
    ))
    #expect(model.selectedFolder?.lastPathComponent == "after-rename")
}
