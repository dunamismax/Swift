
import Foundation
import AVFoundation
import SwiftUI

// MARK: - Enums and Structs

enum FileStatus: String {
    case pending = "Pending"
    case processing = "Processing..."
    case upmixed = "Upmixed"
    case failed = "Failed"
    case cancelled = "Cancelled"

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .processing: return .accentColor
        case .upmixed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }
}

enum UpmixError: LocalizedError {
    case ffmpegNotFound
    case processFailed(String)
    case operationCancelled
    case bookmarkFailed

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg executable not found in the app bundle."
        case .processFailed(let message):
            return "The upmix operation failed: \(message)"
        case .operationCancelled:
            return "The upmix operation was cancelled."
        case .bookmarkFailed:
            return "Failed to create a security-scoped bookmark for file access."
        }
    }
}

struct BookmarkedURL: Identifiable {
    let id = UUID()
    let bookmarkData: Data
    let originalURL: URL
}

struct AudioFile: Identifiable {
    let id = UUID()
    let bookmarkedURL: BookmarkedURL
    var status: FileStatus = .pending
    
    var url: URL {
        // This will be a security-scoped URL
        var isStale = false
        guard let resolvedURL = try? URL(resolvingBookmarkData: bookmarkedURL.bookmarkData,
                                         options: .withSecurityScope,
                                         relativeTo: nil,
                                         bookmarkDataIsStale: &isStale) else {
            // Fallback to original URL, though access may fail
            return bookmarkedURL.originalURL
        }
        
        if isStale {
            // Handle stale bookmark data if necessary
            print("Warning: Bookmark data is stale for \(bookmarkedURL.originalURL.lastPathComponent)")
        }
        
        return resolvedURL
    }
}

// MARK: - AudioUpmixer Class

@MainActor
class AudioUpmixer: ObservableObject {
    @Published var files: [AudioFile] = []
    @Published var isUpmixing = false
    @Published var progress: Double = 0.0
    @Published var status: String = "Ready"
    @Published var errorMessage: String?
    @Published var outputDirectory: BookmarkedURL?

    private var ffmpegPath: String?
    private var currentProcess: Process?
    private var isCancelled = false

    init() {
        self.ffmpegPath = Bundle.main.path(forResource: "ffmpeg", ofType: nil)
    }

    // MARK: - Public Methods

    func setOutputDirectory(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            handleError(UpmixError.bookmarkFailed)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            self.outputDirectory = BookmarkedURL(bookmarkData: bookmarkData, originalURL: url)
        } catch {
            handleError(UpmixError.bookmarkFailed)
        }
    }
    
    func addFile(url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            handleError(UpmixError.bookmarkFailed)
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            let bookmarkedURL = BookmarkedURL(bookmarkData: bookmarkData, originalURL: url)
            
            if !files.contains(where: { $0.bookmarkedURL.originalURL == url }) {
                files.append(AudioFile(bookmarkedURL: bookmarkedURL))
            }
        } catch {
            handleError(UpmixError.bookmarkFailed)
        }
    }

    func clearFiles() {
        guard !isUpmixing else { return }
        files.removeAll()
        resetStatus()
    }

    func startUpmixing() {
        guard !files.isEmpty, !isUpmixing else { return }
        guard ffmpegPath != nil else {
            handleError(UpmixError.ffmpegNotFound)
            return
        }
        guard outputDirectory != nil else {
            handleError(UpmixError.processFailed("Please select an output directory first."))
            return
        }

        isUpmixing = true
        isCancelled = false
        resetStatus()
        status = "Starting upmix..."

        Task {
            await processFiles()
            
            if !isCancelled {
                status = "Upmixing complete."
            }
            isUpmixing = false
        }
    }
    
    func cancelUpmixing() {
        isCancelled = true
        currentProcess?.terminate()
        status = "Cancelling..."
    }

    // MARK: - Private Methods

    private func processFiles() async {
        let totalFiles = files.count
        for i in 0..<files.count {
            if isCancelled {
                await handleCancellation(from: i)
                break
            }
            
            let file = files[i]
            
            guard file.url.startAccessingSecurityScopedResource() else {
                await updateFileStatus(at: i, to: .failed)
                handleError(UpmixError.processFailed("Could not access file at \(file.bookmarkedURL.originalURL.lastPathComponent)"))
                continue
            }
            
            await updateFileStatus(at: i, to: .processing, message: "Upmixing \(file.bookmarkedURL.originalURL.lastPathComponent)...")

            do {
                try await upmix(file: file)
                await updateFileStatus(at: i, to: .upmixed)
            } catch {
                if isCancelled {
                    await handleCancellation(from: i)
                    break
                }
                await updateFileStatus(at: i, to: .failed)
                handleError(error)
                break
            }
            
            file.url.stopAccessingSecurityScopedResource()
            
            progress = Double(i + 1) / Double(totalFiles)
        }
    }

    private func upmix(file: AudioFile) async throws {
        guard let ffmpegPath = ffmpegPath else { throw UpmixError.ffmpegNotFound }
        guard let outputDir = outputDirectory else { throw UpmixError.processFailed("Output directory not set.") }

        var isStale = false
        guard let outputDirURL = try? URL(resolvingBookmarkData: outputDir.bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) else {
            throw UpmixError.bookmarkFailed
        }
        
        guard outputDirURL.startAccessingSecurityScopedResource() else {
            throw UpmixError.processFailed("Could not access output directory.")
        }
        defer { outputDirURL.stopAccessingSecurityScopedResource() }

        let outputFileName = file.bookmarkedURL.originalURL.deletingPathExtension().lastPathComponent + "_5.1.flac"
        let outputURL = outputDirURL.appendingPathComponent(outputFileName)
        
        let filter = createFFmpegFilter()

        let arguments = [
            "-i", file.url.path,
            "-vn",
            "-filter_complex", filter,
            "-c:a", "flac",
            "-y",
            outputURL.path
        ]

        currentProcess = Process()
        currentProcess?.executableURL = URL(fileURLWithPath: ffmpegPath)
        currentProcess?.arguments = arguments

        let errorPipe = Pipe()
        currentProcess?.standardError = errorPipe

        do {
            try currentProcess?.run()
            currentProcess?.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

            if currentProcess?.terminationStatus != 0 {
                if isCancelled {
                    throw UpmixError.operationCancelled
                } else {
                    throw UpmixError.processFailed(errorOutput)
                }
            }
        } catch {
            throw UpmixError.processFailed(error.localizedDescription)
        }
    }
    
    private func createFFmpegFilter() -> String {
        // A robust pan filter for stereo to 5.1 upmixing.
        return "[0:a]pan=5.1(side)|FL=FL|FR=FR|FC=0.5*FL+0.5*FR|LFE=0.1*FL+0.1*FR|SL=0.5*FL|SR=0.5*FR"
    }
    
    private func handleCancellation(from index: Int) async {
        for i in index..<files.count {
            await updateFileStatus(at: i, to: .cancelled)
        }
        status = "Upmix operation cancelled."
        progress = 1.0 // Show completion of cancellation
    }

    private func updateFileStatus(at index: Int, to newStatus: FileStatus, message: String? = nil) async {
        guard index < files.count else { return }
        files[index].status = newStatus
        if let message = message {
            status = message
        }
    }

    private func handleError(_ error: Error) {
        if let upmixError = error as? UpmixError {
            self.errorMessage = upmixError.localizedDescription
        } else {
            self.errorMessage = error.localizedDescription
        }
        self.status = "An error occurred."
    }
    
    private func resetStatus() {
        progress = 0.0
        status = "Ready"
        errorMessage = nil
    }
}

