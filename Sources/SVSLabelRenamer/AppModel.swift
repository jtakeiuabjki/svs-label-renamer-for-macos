import AppKit
import Foundation
import UniformTypeIdentifiers

private struct FolderLocator: Sendable {
    private struct Identity: Sendable, Equatable {
        let device: UInt64
        let inode: UInt64
    }

    let originalURL: URL
    private let bookmarkData: Data?
    private let originalIdentity: Identity?

    init(_ url: URL) {
        originalURL = url
        bookmarkData = try? url.bookmarkData(options: .minimalBookmark)
        originalIdentity = Self.identity(url)
    }

    func resolve() -> URL? {
        if let bookmarkData {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ), Self.isTrackedDirectory(resolved, identity: originalIdentity) {
                return resolved
            }
        }
        guard Self.isTrackedDirectory(originalURL, identity: originalIdentity) else {
            return nil
        }
        return originalURL
    }

    private static func isTrackedDirectory(_ url: URL, identity: Identity?) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard let identity else { return true }
        return Self.identity(url) == identity
    }

    private static func identity(_ url: URL) -> Identity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Identity(device: device.uint64Value, inode: inode.uint64Value)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var records: [SlideRecord] = []
    @Published var selectedFolder: URL?
    @Published var isWorking = false
    @Published private(set) var message: AppMessage = .chooseFolder
    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: Self.languageDefaultsKey) }
    }
    @Published var completedCount = 0
    @Published var totalCount = 0
    @Published private(set) var currentFilename: String?
    private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var selectedFolderLocator: FolderLocator?
    private var lastCompletedOperations: [RenameOperation] = []
    private let processSlide: @Sendable (URL, URL) async -> SlideRecord
    private static let languageDefaultsKey = "appLanguage"

    init(
        processSlide: @escaping @Sendable (URL, URL) async -> SlideRecord = { file, output in
            await SlideProcessor.process(file: file, outputDirectory: output)
        }
    ) {
        self.processSlide = processSlide
        if let saved = UserDefaults.standard.string(forKey: Self.languageDefaultsKey),
           let language = AppLanguage(rawValue: saved) {
            self.language = language
        } else {
            self.language = .preferred
        }
    }

    var confirmedCount: Int { records.filter(\.isReadyToRename).count }
    var canUndo: Bool { !lastCompletedOperations.isEmpty }
    var messageText: String { message.localized(language) }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if let svs = UTType(filenameExtension: "svs") {
            panel.allowedContentTypes = [.folder, svs]
        }
        if panel.runModal() == .OK, let url = panel.url {
            openFolder(url)
        }
    }

    func openFolder(_ url: URL) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue || url.pathExtension.lowercased() == "svs" else {
            message = .invalidSelection
            return
        }
        let folder = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let requestedFilename = isDirectory.boolValue ? nil : url.lastPathComponent
        let locator = FolderLocator(folder)
        selectedFolder = folder
        selectedFolderLocator = locator
        scanTask?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        scanTask = Task {
            await scan(locator, requestedFilename: requestedFilename, scanID: scanID)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        message = .cancelling
    }

    private func scan(
        _ locator: FolderLocator,
        requestedFilename: String?,
        scanID: UUID
    ) async {
        guard activeScanID == scanID else { return }
        isWorking = true
        records = []
        lastCompletedOperations = []
        completedCount = 0
        currentFilename = nil
        defer {
            if activeScanID == scanID { currentFilename = nil }
        }

        guard let initialFolder = locator.resolve() else {
            message = .sourceUnavailable(0, 0)
            isWorking = false
            return
        }
        selectedFolder = initialFolder
        let filenames: [String]
        if let requestedFilename {
            filenames = [requestedFilename]
        } else {
            do {
                let available = try FileManager.default.contentsOfDirectory(
                    at: initialFolder, includingPropertiesForKeys: [.fileSizeKey],
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension.lowercased() == "svs" }
                 .map(\.lastPathComponent)
                 .sorted()
                filenames = available
            } catch {
                guard activeScanID == scanID else { return }
                message = .cannotReadFolder(error.localizedDescription)
                isWorking = false
                return
            }
        }
        totalCount = filenames.count
        message = .analyzing(filenames.count)

        var scannedRecords: [SlideRecord] = []
        for filename in filenames {
            if Task.isCancelled || activeScanID != scanID { break }
            currentFilename = filename
            guard let folder = locator.resolve() else {
                message = .sourceUnavailable(completedCount, totalCount)
                isWorking = false
                return
            }
            if selectedFolder != folder {
                rebase(&scannedRecords, folder: folder)
                records = scannedRecords
            }
            selectedFolder = folder
            let output = folder.appendingPathComponent("SVS_Label_Renamer_Output", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            } catch {
                guard activeScanID == scanID else { return }
                message = .error(error.localizedDescription)
                isWorking = false
                return
            }

            let file = folder.appendingPathComponent(filename)
            var record = await processSlide(file, output)
            guard activeScanID == scanID else { return }
            if Task.isCancelled { break }

            // Finder renames invalidate path URLs. Resolve the folder bookmark
            // again, retry the in-flight file once, and rebase every URL retained
            // by the result so label, macro, and overview links remain valid.
            if let relocatedFolder = locator.resolve(), relocatedFolder != folder {
                rebase(&scannedRecords, folder: relocatedFolder)
                records = scannedRecords
                selectedFolder = relocatedFolder
                let relocatedOutput = relocatedFolder.appendingPathComponent(
                    "SVS_Label_Renamer_Output", isDirectory: true
                )
                let relocatedFile = relocatedFolder.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: relocatedFile.path) {
                    try? FileManager.default.createDirectory(
                        at: relocatedOutput, withIntermediateDirectories: true
                    )
                    record = await processSlide(relocatedFile, relocatedOutput)
                    guard activeScanID == scanID else { return }
                    if Task.isCancelled { break }
                }
                rebase(&record, filename: filename, folder: relocatedFolder)
            }

            scannedRecords.append(record)
            records = scannedRecords
            completedCount = scannedRecords.count
        }
        guard activeScanID == scanID else { return }
        if Task.isCancelled {
            message = .cancelled(completedCount, totalCount)
            isWorking = false
            return
        }
        guard let finalFolder = locator.resolve() else {
            message = .sourceUnavailable(completedCount, totalCount)
            isWorking = false
            return
        }
        rebase(&scannedRecords, folder: finalFolder)
        records = scannedRecords
        selectedFolder = finalFolder
        let output = finalFolder.appendingPathComponent("SVS_Label_Renamer_Output", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try CSVWriter.write(
                records,
                to: output.appendingPathComponent("rename_preview.csv"),
                language: language
            )
        } catch {
            guard activeScanID == scanID else { return }
            message = .cannotSavePreview(error.localizedDescription)
            isWorking = false
            return
        }
        message = .complete
        isWorking = false
    }

    private func rebase(_ records: inout [SlideRecord], folder: URL) {
        for index in records.indices {
            rebase(
                &records[index],
                filename: records[index].sourceURL.lastPathComponent,
                folder: folder
            )
        }
    }

    private func rebase(_ record: inout SlideRecord, filename: String, folder: URL) {
        let output = folder.appendingPathComponent("SVS_Label_Renamer_Output", isDirectory: true)
        let stem = URL(fileURLWithPath: record.originalFilename)
            .deletingPathExtension().lastPathComponent
        record.sourceURL = folder.appendingPathComponent(filename)
        if record.labelImageURL != nil {
            record.labelImageURL = output.appendingPathComponent(stem + "_label.png")
        }
        if record.macroImageURL != nil {
            record.macroImageURL = output.appendingPathComponent(stem + "_macro.png")
        }
        if record.overviewImageURL != nil {
            record.overviewImageURL = output.appendingPathComponent(stem + "_overview.png")
        }
    }

    func waitForCurrentScan() async {
        let task = scanTask
        await task?.value
    }

    func applyRename() {
        guard let folder = resolvedSelectedFolder() else {
            message = .sourceUnavailable(completedCount, totalCount)
            return
        }
        selectedFolder = folder
        rebase(&records, folder: folder)
        let indexes = records.indices.filter { records[$0].isReadyToRename }
        let operations = indexes.map {
            RenameOperation(
                source: records[$0].sourceURL,
                destination: folder.appendingPathComponent(records[$0].proposedFilename)
            )
        }
        let output = folder.appendingPathComponent("SVS_Label_Renamer_Output", isDirectory: true)
        do {
            let timestamp = RenameTransactionService.timestamp()
            try CSVWriter.write(
                records,
                to: output.appendingPathComponent("rename_preview_\(timestamp).csv"),
                language: language
            )
            _ = try RenameTransactionService().execute(operations, logDirectory: output)
            lastCompletedOperations = operations
            for (offset, index) in indexes.enumerated() {
                records[index].sourceURL = operations[offset].destination
                records[index].status = .renamed
                records[index].isConfirmed = false
            }
            do {
                try CSVWriter.write(
                    records,
                    to: output.appendingPathComponent("rename_log_\(timestamp).csv"),
                    language: language
                )
                message = .renamed(operations.count)
            } catch {
                message = .renamedButCSVFailed(error.localizedDescription)
            }
        } catch let error as RenameTransactionError {
            message = .renameFailure(error)
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    func undoLastRename() {
        guard !lastCompletedOperations.isEmpty else { return }
        guard let folder = resolvedSelectedFolder() else {
            message = .sourceUnavailable(completedCount, totalCount)
            return
        }
        selectedFolder = folder
        rebase(&records, folder: folder)
        let reversed = lastCompletedOperations.reversed().map {
            RenameOperation(
                source: folder.appendingPathComponent($0.destination.lastPathComponent),
                destination: folder.appendingPathComponent($0.source.lastPathComponent)
            )
        }
        let output = folder.appendingPathComponent("SVS_Label_Renamer_Output", isDirectory: true)
        do {
            _ = try RenameTransactionService().execute(reversed, logDirectory: output)
            for operation in lastCompletedOperations {
                if let index = records.firstIndex(where: {
                    $0.sourceURL.lastPathComponent == operation.destination.lastPathComponent
                }) {
                    records[index].sourceURL = folder.appendingPathComponent(
                        operation.source.lastPathComponent
                    )
                    records[index].status = .restored
                    records[index].isConfirmed = false
                }
            }
            let count = lastCompletedOperations.count
            lastCompletedOperations = []
            try CSVWriter.write(
                records,
                to: output.appendingPathComponent("undo_log_\(RenameTransactionService.timestamp()).csv"),
                language: language
            )
            message = .undone(count)
        } catch let error as RenameTransactionError {
            message = .renameFailure(error)
        } catch {
            message = .error(error.localizedDescription)
        }
    }

    private func resolvedSelectedFolder() -> URL? {
        if let selectedFolderLocator { return selectedFolderLocator.resolve() }
        return selectedFolder
    }
}
