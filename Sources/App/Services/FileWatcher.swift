import Foundation

/// Watches directories for file changes and triggers callbacks
final class FileWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private var fileDescriptors: [Int32] = []
    private let queue = DispatchQueue(label: "FileWatcher", qos: .utility)
    private var debounceWorkItems: [URL: DispatchWorkItem] = [:]
    private let debounceInterval: TimeInterval = 0.5
    
    typealias ChangeHandler = @Sendable () -> Void
    
    /// Start watching a directory for changes
    func watch(directory: URL, onChange: @escaping ChangeHandler) {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("FileWatcher: Failed to open directory: \(directory.path)")
            return
        }
        
        fileDescriptors.append(fd)
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .link, .rename, .revoke, .delete],
            queue: queue
        )
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending debounced callback for this directory
            self.debounceWorkItems[directory]?.cancel()
            
            // Create a new debounced work item
            let workItem = DispatchWorkItem {
                DispatchQueue.main.async {
                    NSLog("FileWatcher: Change detected in: \(directory.lastPathComponent)")
                    onChange()
                }
            }
            
            self.debounceWorkItems[directory] = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounceInterval, execute: workItem)
        }
        
        source.setCancelHandler {
            close(fd)
        }
        
        source.resume()
        sources.append(source)
        
        NSLog("FileWatcher: Watching directory: \(directory.path)")
    }
    
    /// Stop all watchers
    func stopAll() {
        for source in sources {
            source.cancel()
        }
        sources.removeAll()
        fileDescriptors.removeAll()
        debounceWorkItems.values.forEach { $0.cancel() }
        debounceWorkItems.removeAll()
    }
    
    deinit {
        stopAll()
    }
}
