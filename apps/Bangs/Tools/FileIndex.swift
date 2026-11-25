import CoreServices
import Darwin
import Foundation

/// Search by file name, as Everything does on Windows: every name under the folders in scope, kept in memory and on
/// disk, read once with a parallel `getattrlistbulk` walk and then kept current from FSEvents. A search runs `memmem`
/// over the lowercased names, so it takes milliseconds over hundreds of thousands of files.
///
/// Everything happens on one serial queue except the full walk, which runs on threads of its own and hands the new
/// table over when done; changes that arrive meanwhile are applied afterwards.
final class FileIndex: @unchecked Sendable {
    /// What is indexed: the roots, folders not gone into (by path, or by name wherever they are), and its fingerprint,
    /// which a saved index must match to be used.
    struct Scope: Equatable, Sendable {
        var roots: [String]
        var skipPaths: Set<String>
        var skipNames: Set<String>

        /// Roots as FSEvents names them: links resolved (/var is /private/var).
        init(roots: [String], skipPaths: Set<String>, skipNames: Set<String>) {
            self.roots = roots.map(FileIndex.canonical)
            self.skipPaths = skipPaths
            self.skipNames = skipNames
        }

        /// Home, the applications and iCloud Drive; or the whole startup disk except the system volume and other disks.
        static func make(wholeDisk: Bool, exclusions: [String], home: String = NSHomeDirectory()) -> Scope {
            let own = Storage.root.path
            let names = Set(exclusions.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
            if wholeDisk {
                return Scope(roots: ["/", "/System/Applications"],
                             skipPaths: ["/System", "/Volumes", "/dev", "/cores", "/.vol", "/.Spotlight-V100", "/.fseventsd", "/.DocumentRevisions-V100",
                                         "/.MobileBackups", "/private/var/folders", "/private/var/db", "/private/var/vm", home + "/.Trash", own],
                             skipNames: names)
            }
            var roots = [home, "/Applications", "/System/Applications"]
            let drive = home + "/Library/Mobile Documents/com~apple~CloudDocs"
            if FileManager.default.fileExists(atPath: drive) { roots.append(drive) }
            return Scope(roots: roots, skipPaths: [home + "/Library", home + "/.Trash", own], skipNames: names)
        }

        var fingerprint: UInt64 {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            let text = roots.joined(separator: "\u{1}") + "\u{2}" + skipPaths.sorted().joined(separator: "\u{1}") + "\u{2}"
                + skipNames.sorted().joined(separator: "\u{1}") + "\u{2}packages:\(FileIndex.packages.count)"
            for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
            return hash
        }

        /// Whether the walk goes into this folder.
        func descends(into path: String, lowerName: String) -> Bool {
            if skipNames.contains(lowerName) || skipPaths.contains(path) { return false }
            if let dot = lowerName.lastIndex(of: "."), dot != lowerName.startIndex, FileIndex.packages.contains(String(lowerName[lowerName.index(after: dot)...])) {
                return false
            }
            return true
        }
    }

    /// Folders the Finder shows as one file: apps, libraries, documents saved as folders. Their insides are not indexed.
    static let packages: Set<String> = [
        "app", "framework", "bundle", "plugin", "kext", "appex", "xpc", "qlgenerator", "mdimporter", "prefpane", "saver", "systemextension",
        "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle", "theater", "logicx", "band", "xcarchive", "xcodeproj",
        "xcworkspace", "playground", "sparsebundle", "rtfd", "pages", "numbers", "key", "dsym", "doccarchive", "nib", "storyboardc", "momd",
        "lrdata", "lrlibrary", "aplibrary", "migratedphotolibrary", "photolibrary", "scriptd", "wdgt", "mlmodelc",
    ]

    /// Dependencies, build products and caches: thousands of files nobody looks for by name. Editable in the settings.
    static let defaultExclusions = [
        "node_modules", "bower_components", ".pnpm-store", ".npm", ".yarn", "Pods", "Carthage", ".build", "build", "DerivedData", "target", "dist",
        "out", ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".gradle", ".m2", ".cargo", ".rustup", "__pycache__", ".venv", "venv",
        "site-packages", ".tox", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".terraform", "Caches", ".cache", ".git", ".hg", ".svn",
    ]

    struct Entry {
        var parent: Int32
        /// Folders: the newest child, or -1. Children are linked through `next`.
        var firstChild: Int32
        var next: Int32
        var offset: UInt32
        var length: UInt16
        var flags: UInt8
        var spare: UInt8 = 0
    }

    enum Flag {
        static let folder: UInt8 = 1
        static let deleted: UInt8 = 2
        static let root: UInt8 = 4
        /// A folder not gone into: excluded, a package or out of scope.
        static let pruned: UInt8 = 8
        static let link: UInt8 = 16
    }

    /// The names, each followed by a 0, as found (in NFC) and lowercased at the same offsets; the entries in the order
    /// their names were added, so an offset finds its entry by binary search.
    struct Table {
        var entries: ContiguousArray<Entry> = []
        var names: [UInt8] = []
        var lower: [UInt8] = []
        var roots: [Int32] = []
        var deleted = 0

        var live: Int { entries.count - deleted - roots.count }
        var bytes: Int { entries.count * MemoryLayout<Entry>.stride + names.count + lower.count }

        mutating func reserve(_ count: Int) {
            entries.reserveCapacity(count)
            names.reserveCapacity(count * 22)
            lower.reserveCapacity(count * 22)
        }

        @discardableResult
        mutating func add(_ name: UnsafeBufferPointer<UInt8>, lower folded: UnsafeBufferPointer<UInt8>, parent: Int32, flags: UInt8) -> Int32 {
            let id = Int32(entries.count)
            entries.append(Entry(parent: parent, firstChild: -1, next: parent >= 0 ? entries[Int(parent)].firstChild : -1,
                                 offset: UInt32(names.count), length: UInt16(name.count), flags: flags))
            names.append(contentsOf: name)
            names.append(0)
            lower.append(contentsOf: folded)
            lower.append(0)
            if parent >= 0 { entries[Int(parent)].firstChild = id }
            return id
        }

        mutating func addRoot(_ path: String) -> Int32 {
            let bytes = Array(path.utf8), folded = Array(path.lowercased().utf8)
            let id = bytes.withUnsafeBufferPointer { name in
                (folded.count == bytes.count ? folded : bytes).withUnsafeBufferPointer { add(name, lower: $0, parent: -1, flags: Flag.folder | Flag.root) }
            }
            roots.append(id)
            return id
        }

        func name(_ id: Int32) -> String {
            let entry = entries[Int(id)]
            return names.withUnsafeBufferPointer { String(decoding: UnsafeBufferPointer(rebasing: $0[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)]), as: UTF8.self) }
        }

        func children(_ id: Int32) -> [Int32] {
            var result: [Int32] = []
            var child = entries[Int(id)].firstChild
            while child >= 0 {
                if entries[Int(child)].flags & Flag.deleted == 0 { result.append(child) }
                child = entries[Int(child)].next
            }
            return result
        }

        /// Where an entry is: its root's path and the names below it.
        func path(_ id: Int32, cache: inout [Int32: String]) -> String {
            if let known = cache[id] { return known }
            let entry = entries[Int(id)]
            let path: String
            if entry.parent < 0 {
                path = name(id)
            } else {
                let parent = self.path(entry.parent, cache: &cache)
                path = (parent.hasSuffix("/") ? parent : parent + "/") + name(id)
            }
            if entry.flags & Flag.folder != 0 { cache[id] = path }
            return path
        }

        /// The entry whose name holds this offset.
        func entry(at offset: Int, in entries: UnsafeBufferPointer<Entry>) -> Int {
            var low = 0, high = entries.count
            while high - low > 1 {
                let middle = (low + high) / 2
                if Int(entries[middle].offset) <= offset { low = middle } else { high = middle }
            }
            return low
        }
    }

    // MARK: Reading folders

    /// A folder's contents: names as found (NFC) and lowercased, end to end, with their lengths and kinds.
    struct Listing {
        var names: [UInt8] = []
        var lower: [UInt8] = []
        var lengths: [Int] = []
        var flags: [UInt8] = []

        mutating func clear() {
            names.removeAll(keepingCapacity: true)
            lower.removeAll(keepingCapacity: true)
            lengths.removeAll(keepingCapacity: true)
            flags.removeAll(keepingCapacity: true)
        }
    }

    /// Reads one folder with `getattrlistbulk`, which returns many entries a call. False when it cannot be opened (gone,
    /// or not allowed); `errno` says which.
    static func list(_ path: String, buffer: UnsafeMutableRawBufferPointer, into listing: inout Listing) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_OBJTYPE)
        let base = buffer.baseAddress!
        while true {
            let count = getattrlistbulk(fd, &request, base, buffer.count, 0)
            if count <= 0 { return true }
            var record = base
            for _ in 0..<count {
                let length = Int(record.loadUnaligned(as: UInt32.self))
                defer { record += length }
                var field = record + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0, returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 else { continue }
                let reference = field.loadUnaligned(as: attrreference_t.self)
                let name = UnsafeRawPointer(field + Int(reference.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                let nameLength = strnlen(UnsafeRawPointer(name).assumingMemoryBound(to: CChar.self), Int(reference.attr_length))
                field += MemoryLayout<attrreference_t>.size
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                guard nameLength > 0 else { continue }
                let flags: UInt8 = type == fsobj_type_t(VDIR.rawValue) ? Flag.folder : type == fsobj_type_t(VLNK.rawValue) ? Flag.link : 0
                append(UnsafeBufferPointer(start: name, count: nameLength), flags: flags, to: &listing)
            }
        }
    }

    private static func append(_ name: UnsafeBufferPointer<UInt8>, flags: UInt8, to listing: inout Listing) {
        if !name.contains(where: { $0 >= 0x80 }) {
            listing.names.append(contentsOf: name)
            for byte in name { listing.lower.append(byte >= 65 && byte <= 90 ? byte + 32 : byte) }
            listing.lengths.append(name.count)
        } else {
            // Names may be stored decomposed; people type them composed.
            let text = String(decoding: name, as: UTF8.self).precomposedStringWithCanonicalMapping
            let bytes = Array(text.utf8)
            var folded = Array(text.lowercased().utf8)
            // Lowercasing that changes the length (rare) would put the two copies out of step: fold ASCII only.
            if folded.count != bytes.count { folded = bytes.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 } }
            guard bytes.count <= Int(UInt16.max) else { return }
            listing.names.append(contentsOf: bytes)
            listing.lower.append(contentsOf: folded)
            listing.lengths.append(bytes.count)
        }
        listing.flags.append(flags)
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Text as the index compares it: composed, lowercased.
    static func fold(_ text: String) -> String { text.precomposedStringWithCanonicalMapping.lowercased() }

    // MARK: The full walk

    /// Walks the scope on several threads. Each takes a folder, reads it without a lock, then adds what it found and
    /// the folders to go into under one.
    final class Walk: @unchecked Sendable {
        let scope: Scope
        private let condition = NSCondition()
        private var table = Table()
        private var jobs: [(path: String, id: Int32)] = []
        private var busy = 0
        private(set) var found = 0

        init(scope: Scope, expected: Int) {
            self.scope = scope
            table.reserve(max(expected, 100_000))
        }

        func run(threads: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount))) -> Table {
            for root in scope.roots {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: root, isDirectory: &isFolder), isFolder.boolValue else { continue }
                jobs.append((root, table.addRoot(root)))
            }
            let group = DispatchGroup()
            for _ in 0..<threads {
                group.enter()
                let thread = Thread { [self] in
                    work()
                    group.leave()
                }
                thread.qualityOfService = .utility
                thread.start()
            }
            group.wait()
            return table
        }

        var progress: Int {
            condition.lock()
            defer { condition.unlock() }
            return found
        }

        private func next() -> (path: String, id: Int32)? {
            condition.lock()
            defer { condition.unlock() }
            while jobs.isEmpty && busy > 0 { condition.wait() }
            guard let job = jobs.popLast() else {
                condition.broadcast()
                return nil
            }
            busy += 1
            return job
        }

        private func work() {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)
            defer { buffer.deallocate() }
            var listing = Listing()
            var descend: [(index: Int, path: String)] = []
            while let job = next() {
                listing.clear()
                descend.removeAll(keepingCapacity: true)
                _ = FileIndex.list(job.path, buffer: buffer, into: &listing)
                // Which folders to go into is decided before taking the lock.
                var start = 0
                for index in listing.lengths.indices {
                    let length = listing.lengths[index]
                    defer { start += length }
                    guard listing.flags[index] & Flag.folder != 0 else { continue }
                    let name = String(decoding: listing.names[start..<start + length], as: UTF8.self)
                    let path = (job.path.hasSuffix("/") ? job.path : job.path + "/") + name
                    let lower = String(decoding: listing.lower[start..<start + length], as: UTF8.self)
                    if scope.descends(into: path, lowerName: lower) {
                        descend.append((index, path))
                    } else {
                        listing.flags[index] |= Flag.pruned
                    }
                }
                condition.lock()
                let first = FileIndex.add(listing, to: &table, parent: job.id)
                for (index, path) in descend { jobs.append((path, first + Int32(index))) }
                found = table.entries.count
                busy -= 1
                condition.broadcast()
                condition.unlock()
            }
        }
    }

    /// Adds a listing's entries under `parent`; returns the first one's id (the rest follow in order).
    @discardableResult
    static func add(_ listing: Listing, to table: inout Table, parent: Int32) -> Int32 {
        let first = Int32(table.entries.count)
        listing.names.withUnsafeBufferPointer { names in
            listing.lower.withUnsafeBufferPointer { lower in
                var start = 0
                for index in listing.lengths.indices {
                    let length = listing.lengths[index]
                    table.add(UnsafeBufferPointer(rebasing: names[start..<start + length]), lower: UnsafeBufferPointer(rebasing: lower[start..<start + length]),
                              parent: parent, flags: listing.flags[index])
                    start += length
                }
            }
        }
        return first
    }

    // MARK: State

    enum State: Equatable {
        case off
        /// Reading the saved index.
        case loading
        /// The first walk, with how many entries it found so far.
        case scanning(Int)
        case ready
    }

    struct Status: Equatable {
        var state: State = .off
        var count = 0
        var bytes = 0
        /// When the folders were last read in full.
        var scanned: Date?
        /// A walk is running behind a ready index (a rebuild, or a changed scope).
        var rebuilding = false
    }

    /// Called on the main queue.
    var onStatus: (Status) -> Void = { _ in }

    private let queue = DispatchQueue(label: "bangs.files", qos: .userInitiated)
    private var table = Table()
    private var scope: Scope?
    private var stream: FSEventStreamRef?
    private var lastEvent = FSEventStreamEventId(kFSEventStreamEventIdSinceNow)
    private var scanned: Date?
    private var walk: Walk?
    /// Changes seen while a walk runs, applied when it is done.
    private var pending: [(path: String, recursive: Bool)] = []
    private var saveWork: DispatchWorkItem?
    private var progressTimer: DispatchSourceTimer?
    private var state: State = .off
    /// Where the index is kept; nil keeps nothing on disk (tests).
    let file: URL?

    init(file: URL? = Storage.directory("FileIndex").appendingPathComponent("index.bin")) {
        self.file = file
    }

    /// The stream holds the index unretained: it must not outlive it.
    deinit {
        stopStream()
    }

    // MARK: Turning on and off

    /// Starts indexing `scope`, from the saved index when it matches, else with a walk. A new scope starts a walk.
    func start(_ scope: Scope) {
        queue.async { [self] in
            guard scope != self.scope else { return }
            let first = self.scope == nil
            self.scope = scope
            stopStream()
            if first {
                state = .loading
                publish()
                if let saved = load(scope: scope) {
                    table = saved.table
                    scanned = saved.scanned
                    state = .ready
                    publish()
                    startStream(since: saved.lastEvent)
                    // Changes the history no longer holds would otherwise be missed for good.
                    if Date().timeIntervalSince(saved.scanned) > 7 * 86400 { rebuild() }
                    return
                }
            }
            // A walk of the old scope is left to finish unheard.
            walk = nil
            progressTimer?.cancel()
            progressTimer = nil
            pending = []
            startStream(since: FSEventStreamEventId(kFSEventStreamEventIdSinceNow))
            rebuild()
        }
    }

    /// Stops watching and forgets the index, on disk too.
    func stop() {
        queue.async { [self] in
            stopStream()
            scope = nil
            walk = nil
            table = Table()
            pending = []
            saveWork?.cancel()
            state = .off
            scanned = nil
            if let file { try? FileManager.default.removeItem(at: file) }
            publish()
        }
    }

    /// Stops following changes, keeping the index; for tests (a quit, as far as the index can tell).
    func stopWatching() {
        queue.sync {
            stopStream()
            if saveWork != nil { saveWork?.cancel(); save() }
        }
    }

    /// Reads every folder again: asked for, after a change the history could not describe, or to compact.
    func rebuild() {
        queue.async { [self] in
            guard let scope, walk == nil else { return }
            if state != .ready { state = .scanning(0) }
            let walk = Walk(scope: scope, expected: table.entries.count)
            self.walk = walk
            publish()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self, weak walk] in
                guard let self, let walk, self.walk === walk, case .scanning = self.state else { return }
                self.state = .scanning(walk.progress)
                self.publish()
            }
            timer.resume()
            progressTimer = timer
            let started = Date()
            Thread.detachNewThread { [weak self] in
                let result = walk.run()
                self?.queue.async {
                    guard let self, self.walk === walk else { return }
                    self.progressTimer?.cancel()
                    self.progressTimer = nil
                    self.walk = nil
                    guard self.scope == walk.scope else { return }
                    self.table = result
                    self.scanned = started
                    self.state = .ready
                    Log.write("files: indexed \(result.entries.count) entries in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                    let changes = self.pending
                    self.pending = []
                    self.apply(changes)
                    self.publish()
                    self.save()
                    // The table before this one is gone, and so is what the walk worked with.
                    malloc_zone_pressure_relief(nil, 0)
                }
            }
        }
    }

    /// Writes the index now; on quit.
    func flush() {
        queue.sync {
            guard saveWork != nil else { return }
            saveWork?.cancel()
            save()
        }
    }

    private func publish() {
        let status = Status(state: state, count: table.live, bytes: table.bytes, scanned: scanned, rebuilding: walk != nil && state == .ready)
        DispatchQueue.main.async { [onStatus] in onStatus(status) }
    }

    // MARK: Watching

    private func startStream(since: FSEventStreamEventId) {
        guard let scope else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, ids in
            guard let info else { return }
            let index = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            index.receive((0..<count).map { (paths.indices.contains($0) ? paths[$0] : "", flags[$0], ids[$0]) })
        }
        let watched = scope.roots.filter { FileManager.default.fileExists(atPath: $0) }
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, watched as CFArray, since, 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
        if since == FSEventStreamEventId(kFSEventStreamEventIdSinceNow) { lastEvent = FSEventsGetCurrentEventId() }
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    private func receive(_ events: [(path: String, flags: FSEventStreamEventFlags, id: FSEventStreamEventId)]) {
        var changes: [(path: String, recursive: Bool)] = []
        for event in events {
            let flags = Int(event.flags)
            if event.id != 0 { lastEvent = max(lastEvent, event.id) }
            if flags & kFSEventStreamEventFlagHistoryDone != 0 { continue }
            if flags & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped) != 0 {
                rebuild()
                continue
            }
            var path = event.path
            // The data volume, seen through its firmlinks, may come by its own name.
            if path.hasPrefix("/System/Volumes/Data/") { path.removeFirst("/System/Volumes/Data".count) }
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            let deep = flags & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
            changes.append((path, deep))
        }
        guard !changes.isEmpty else { return }
        if walk != nil {
            pending += changes
        } else {
            apply(changes)
        }
    }

    private func apply(_ changes: [(path: String, recursive: Bool)]) {
        guard let scope, !changes.isEmpty else { return }
        var seen: [String: Bool] = [:]
        for change in changes { seen[change.path] = (seen[change.path] ?? false) || change.recursive }
        let before = table.entries.count, deletedBefore = table.deleted
        for (path, recursive) in seen {
            // A change at or above a root is too broad to follow folder by folder.
            if recursive, scope.roots.contains(where: { $0 == path || $0.hasPrefix(path == "/" ? "/" : path + "/") }) {
                rebuild()
                return
            }
            refresh(path, recursive: recursive)
        }
        guard table.entries.count != before || table.deleted != deletedBefore else { return }
        // Removed entries stay as gaps until the next walk.
        if table.deleted > max(50_000, table.entries.count / 4) { rebuild() }
        publish()
        scheduleSave()
    }

    /// The entry at a path, if it is indexed.
    func lookup(_ path: String) -> Int32? {
        guard let (root, rest) = locate(path) else { return nil }
        var id = root
        for component in rest {
            let target = Array(component.precomposedStringWithCanonicalMapping.utf8)
            let folded = Array(FileIndex.fold(component).utf8)
            var match: Int32?
            for child in table.children(id) {
                let entry = table.entries[Int(child)]
                let range = Int(entry.offset)..<Int(entry.offset) + Int(entry.length)
                if table.names[range].elementsEqual(target) { match = child; break }
                if match == nil, table.lower[range].elementsEqual(folded) { match = child }
            }
            guard let match else { return nil }
            id = match
        }
        return id
    }

    /// The root a path is under, and the names below it.
    private func locate(_ path: String) -> (Int32, [String])? {
        var best: (Int32, String)?
        for root in table.roots {
            let rootPath = table.name(root)
            let inside = path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
            if inside, rootPath.count > best?.1.count ?? -1 { best = (root, rootPath) }
        }
        guard let (root, rootPath) = best else { return nil }
        return (root, path.dropFirst(rootPath.count).split(separator: "/").map(String.init))
    }

    /// Reads a folder again and brings its entries up to date; with `recursive`, the folders inside it too.
    private func refresh(_ path: String, recursive: Bool) {
        guard let scope, let (root, rest) = locate(path) else { return }
        // Inside a folder the index leaves out.
        var walked = table.name(root)
        for component in rest {
            walked = (walked.hasSuffix("/") ? walked : walked + "/") + component
            if !scope.descends(into: walked, lowerName: FileIndex.fold(component)) { return }
        }
        guard let id = lookup(path) else {
            // Not known yet: the nearest folder that is gets read, which finds this one.
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, !parent.isEmpty { refresh(parent, recursive: false) }
            return
        }
        let entry = table.entries[Int(id)]
        guard entry.flags & Flag.folder != 0, entry.flags & Flag.pruned == 0 else { return }
        update(id, path: path, recursive: recursive)
    }

    private lazy var buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 256 << 10, alignment: 16)

    private func update(_ id: Int32, path: String, recursive: Bool) {
        guard let scope else { return }
        var listing = Listing()
        guard FileIndex.list(path, buffer: buffer, into: &listing) else {
            if errno == ENOENT || errno == ENOTDIR, table.entries[Int(id)].flags & Flag.root == 0 {
                remove(id)
                relink(table.entries[Int(id)].parent)
            }
            return
        }
        var existing: [[UInt8]: Int32] = [:]
        for child in table.children(id) {
            let entry = table.entries[Int(child)]
            existing[Array(table.names[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)])] = child
        }
        var start = 0
        var added = Listing()
        var kept: [(Int32, String)] = []
        for index in listing.lengths.indices {
            let length = listing.lengths[index]
            defer { start += length }
            let name = Array(listing.names[start..<start + length])
            var flags = listing.flags[index]
            let childPath = (path.hasSuffix("/") ? path : path + "/") + String(decoding: name, as: UTF8.self)
            if flags & Flag.folder != 0, !scope.descends(into: childPath, lowerName: String(decoding: listing.lower[start..<start + length], as: UTF8.self)) {
                flags |= Flag.pruned
            }
            if let old = existing.removeValue(forKey: name) {
                if table.entries[Int(old)].flags & (Flag.folder | Flag.link | Flag.pruned) == flags & (Flag.folder | Flag.link | Flag.pruned) {
                    if recursive, flags & Flag.folder != 0, flags & Flag.pruned == 0 { kept.append((old, childPath)) }
                    continue
                }
                remove(old)
            }
            added.names += name
            added.lower += listing.lower[start..<start + length]
            added.lengths.append(length)
            added.flags.append(flags)
        }
        for old in existing.values { remove(old) }
        if !existing.isEmpty { relink(id) }
        let first = FileIndex.add(added, to: &table, parent: id)
        // New folders are read in full.
        var start2 = 0
        for index in added.lengths.indices {
            let length = added.lengths[index]
            defer { start2 += length }
            guard added.flags[index] & Flag.folder != 0, added.flags[index] & Flag.pruned == 0 else { continue }
            let childPath = (path.hasSuffix("/") ? path : path + "/") + String(decoding: added.names[start2..<start2 + length], as: UTF8.self)
            update(first + Int32(index), path: childPath, recursive: true)
        }
        for (child, childPath) in kept { update(child, path: childPath, recursive: true) }
    }

    /// Marks an entry and everything under it removed.
    private func remove(_ id: Int32) {
        var stack = [id]
        while let next = stack.popLast() {
            guard table.entries[Int(next)].flags & Flag.deleted == 0 else { continue }
            table.entries[Int(next)].flags |= Flag.deleted
            table.deleted += 1
            var child = table.entries[Int(next)].firstChild
            while child >= 0 {
                stack.append(child)
                child = table.entries[Int(child)].next
            }
        }
    }

    /// Drops removed children from a folder's list.
    private func relink(_ id: Int32) {
        guard id >= 0 else { return }
        let live = table.children(id)
        table.entries[Int(id)].firstChild = live.first ?? -1
        for (index, child) in live.enumerated() {
            table.entries[Int(child)].next = index + 1 < live.count ? live[index + 1] : -1
        }
    }

    // MARK: Saving

    private static let magic: UInt32 = 0x4246_4931 // "BFI1"

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        queue.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private static func volumeID() -> String {
        var info = stat()
        guard stat(NSHomeDirectory(), &info) == 0, let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return "" }
        return CFUUIDCreateString(nil, uuid) as String? ?? ""
    }

    private func save() {
        saveWork = nil
        guard let file, let scope, state == .ready else { return }
        var data = Data()
        data.reserveCapacity(table.bytes + 256)
        func put<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let volume = Array(Self.volumeID().utf8)
        put(Self.magic)
        put(UInt32(MemoryLayout<Entry>.stride))
        put(scope.fingerprint)
        put(UInt64(lastEvent))
        put((scanned ?? Date()).timeIntervalSince1970)
        put(UInt64(table.entries.count))
        put(UInt64(table.names.count))
        put(UInt64(table.deleted))
        put(UInt32(volume.count))
        data.append(contentsOf: volume)
        put(UInt32(table.roots.count))
        for root in table.roots { put(root) }
        table.entries.withUnsafeBytes { data.append(contentsOf: $0) }
        data.append(contentsOf: table.names)
        data.append(contentsOf: table.lower)
        do {
            try data.write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            Log.write("files: could not save the index: \(error)")
        }
    }

    private func load(scope: Scope) -> (table: Table, lastEvent: FSEventStreamEventId, scanned: Date)? {
        guard let file, let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return nil }
        return data.withUnsafeBytes { raw -> (Table, FSEventStreamEventId, Date)? in
            var cursor = 0
            func take<T>(_: T.Type) -> T? {
                guard cursor + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { cursor += MemoryLayout<T>.size }
                return raw.loadUnaligned(fromByteOffset: cursor, as: T.self)
            }
            guard take(UInt32.self) == Self.magic, take(UInt32.self) == UInt32(MemoryLayout<Entry>.stride), take(UInt64.self) == scope.fingerprint,
                  let event = take(UInt64.self), let time = take(Double.self), let count = take(UInt64.self), let arena = take(UInt64.self),
                  let deleted = take(UInt64.self), let volumeLength = take(UInt32.self), cursor + Int(volumeLength) <= raw.count else { return nil }
            let volume = String(decoding: raw[cursor..<cursor + Int(volumeLength)], as: UTF8.self)
            cursor += Int(volumeLength)
            // Another disk, or one erased since: the event history means nothing.
            guard volume == Self.volumeID(), let rootCount = take(UInt32.self) else { return nil }
            var table = Table()
            for _ in 0..<rootCount {
                guard let root = take(Int32.self) else { return nil }
                table.roots.append(root)
            }
            // A damaged file must cost a walk, not a crash on every launch: sizes are checked before any arithmetic
            // that could overflow, and every id and name range before anything follows them.
            let stride = MemoryLayout<Entry>.stride, remaining = raw.count - cursor
            guard count <= UInt64(min(remaining / stride, Int(Int32.max))), arena <= UInt64(remaining), deleted <= count else { return nil }
            let entryCount = Int(count), arenaBytes = Int(arena), entryBytes = entryCount * stride
            guard entryBytes + 2 * arenaBytes == remaining, table.roots.allSatisfy({ $0 >= 0 && Int($0) < entryCount }) else { return nil }
            table.entries = ContiguousArray(unsafeUninitializedCapacity: entryCount) { buffer, initialized in
                if entryCount > 0 { memcpy(buffer.baseAddress!, raw.baseAddress! + cursor, entryBytes) }
                initialized = entryCount
            }
            guard Self.consistent(table.entries, arena: arenaBytes) else { return nil }
            cursor += entryBytes
            table.names = Array(raw[cursor..<cursor + arenaBytes])
            cursor += arenaBytes
            table.lower = Array(raw[cursor..<cursor + arenaBytes])
            table.deleted = Int(deleted)
            return (table, FSEventStreamEventId(event), Date(timeIntervalSince1970: time))
        }
    }

    /// Whether the links can be followed safely. Entries are only ever appended, so a parent and an older sibling
    /// (`next`) come before an entry and its newest child after it; holding to that order also rules out cycles, which
    /// would hang the walks up the tree and along a folder's children. One pass, cheap next to reading the file.
    static func consistent(_ entries: ContiguousArray<Entry>, arena: Int) -> Bool {
        entries.withUnsafeBufferPointer { entries in
            let count = Int32(entries.count)
            for index in 0..<Int32(entries.count) {
                let entry = entries[Int(index)]
                guard entry.parent >= -1, entry.parent < index, entry.next >= -1, entry.next < index,
                      entry.firstChild == -1 || (entry.firstChild > index && entry.firstChild < count),
                      Int(entry.offset) + Int(entry.length) <= arena else { return false }
            }
            return true
        }
    }

    // MARK: Searching

    struct Hit: Identifiable, Hashable {
        let id: String
        let name: String
        /// The folder it is in.
        let folder: String
        let kind: FileKind
        var path: String { id }
    }

    struct Results: Equatable {
        var hits: [Hit] = []
        /// Matches of the chosen kind, of which `hits` are the best.
        var total = 0
        /// Matches of every kind.
        var counts: [FileKind: Int] = [:]
        var milliseconds = 0.0
        var query = ""
    }

    /// Searches on the index's queue and answers on the main one. Words are all matched, in any order; a word with a
    /// slash is matched against the whole path.
    func search(_ text: String, kind: FileKind?, limit: Int = 200, completion: @escaping @MainActor (Results) -> Void) {
        queue.async { [self] in
            let results = search(text, kind: kind, limit: limit)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(results) } }
        }
    }

    /// Searches and waits for the answer; for tests and measurements.
    func searchNow(_ text: String, kind: FileKind? = nil, limit: Int = 200) -> Results {
        queue.sync { search(text, kind: kind, limit: limit) }
    }

    /// Ready, with no walk running and no changes waiting; for tests.
    var settled: Bool { queue.sync { state == .ready && walk == nil } }
    var entryCount: Int { queue.sync { table.live } }

    /// The search itself; on the queue.
    func search(_ text: String, kind: FileKind?, limit: Int) -> Results {
        let started = Date()
        let words = FileIndex.fold(text).split(whereSeparator: \.isWhitespace).map { Array($0.utf8) }
        guard !words.isEmpty, state == .ready else { return Results(query: text) }
        let nameWords = words.filter { !$0.contains(0x2F) }.sorted { $0.count > $1.count }
        let pathWords = words.filter { $0.contains(0x2F) }
        var candidates = nameWords.first.map(matches) ?? table.entries.indices.compactMap { index in
            table.entries[index].flags & (Flag.deleted | Flag.root) == 0 ? Int32(index) : nil
        }
        if nameWords.count > 1 {
            let rest = nameWords.dropFirst()
            candidates = table.lower.withUnsafeBytes { lower in
                candidates.filter { id in
                    let entry = table.entries[Int(id)]
                    return rest.allSatisfy { word in
                        word.withUnsafeBytes { memmem(lower.baseAddress! + Int(entry.offset), Int(entry.length), $0.baseAddress!, word.count) != nil }
                    }
                }
            }
        }
        var paths: [Int32: String] = [:]
        if !pathWords.isEmpty {
            var folders: [Int32: [UInt8]] = [:]
            candidates = candidates.filter { id in
                let entry = table.entries[Int(id)]
                guard entry.parent >= 0 else { return false }
                let folder = lowerPath(entry.parent, cache: &folders)
                let name = table.lower[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)]
                return pathWords.allSatisfy { word in
                    // In the folder's path, or across its end into the name.
                    if Self.contains(folder[...], word) { return true }
                    let tail = folder.suffix(word.count - 1) + (folder.last == 0x2F ? [] : [0x2F]) + name
                    return Self.contains(tail[...], word)
                }
            }
        }
        var counts: [FileKind: Int] = [:]
        var ranked: [Int64] = []
        ranked.reserveCapacity(candidates.count)
        let primary = nameWords.first ?? []
        table.lower.withUnsafeBytes { lower in
            for id in candidates {
                let entryKind = self.kind(id, lower: lower)
                counts[entryKind, default: 0] += 1
                guard kind == nil || entryKind == kind else { continue }
                ranked.append(Int64(score(id, word: primary, single: words.count == 1, kind: entryKind, lower: lower)) << 32 | Int64(Int32.max - id))
            }
        }
        let top = ranked.count > limit ? Self.largest(ranked, limit) : ranked.sorted(by: >)[...]
        let hits = top.map { key -> Hit in
            let id = Int32.max - Int32(truncatingIfNeeded: key & 0xFFFF_FFFF)
            let entry = table.entries[Int(id)]
            let folder = entry.parent >= 0 ? table.path(entry.parent, cache: &paths) : ""
            let name = table.name(id)
            return Hit(id: (folder.hasSuffix("/") ? folder : folder + "/") + name, name: name, folder: folder, kind: self.kind(id))
        }
        return Results(hits: hits, total: ranked.count, counts: counts, milliseconds: Date().timeIntervalSince(started) * 1000, query: text)
    }

    private static func contains(_ haystack: ArraySlice<UInt8>, _ needle: [UInt8]) -> Bool {
        haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { memmem(hay.baseAddress!, hay.count, $0.baseAddress!, needle.count) != nil }
        }
    }

    /// A folder's path, lowercased, kept for the rest of a search.
    private func lowerPath(_ id: Int32, cache: inout [Int32: [UInt8]]) -> [UInt8] {
        if let known = cache[id] { return known }
        let entry = table.entries[Int(id)]
        var path: [UInt8] = []
        if entry.parent >= 0 {
            path = lowerPath(entry.parent, cache: &cache)
            if path.last != 0x2F { path.append(0x2F) }
        }
        path += table.lower[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)]
        cache[id] = path
        return path
    }

    /// The `count` largest keys, largest first, without sorting them all (a one-letter search matches most of the disk).
    static func largest(_ keys: [Int64], _ count: Int) -> ArraySlice<Int64> {
        var heap: [Int64] = []
        heap.reserveCapacity(count)
        for key in keys {
            if heap.count < count {
                heap.append(key)
                var child = heap.count - 1
                while child > 0, heap[(child - 1) / 2] > heap[child] {
                    heap.swapAt(child, (child - 1) / 2)
                    child = (child - 1) / 2
                }
            } else if key > heap[0] {
                heap[0] = key
                var parent = 0
                while true {
                    let left = parent * 2 + 1, right = left + 1
                    var smallest = parent
                    if left < heap.count, heap[left] < heap[smallest] { smallest = left }
                    if right < heap.count, heap[right] < heap[smallest] { smallest = right }
                    if smallest == parent { break }
                    heap.swapAt(parent, smallest)
                    parent = smallest
                }
            }
        }
        return heap.sorted(by: >)[...]
    }

    /// Entries whose name holds `word`, found with `memmem` over the lowercased names, a slice per core.
    private func matches(_ word: [UInt8]) -> [Int32] {
        let size = table.lower.count
        guard size > 0, !word.isEmpty else { return [] }
        let parts = max(1, min(ProcessInfo.processInfo.activeProcessorCount, size / (1 << 20)))
        var bounds = [0]
        for part in 1..<parts {
            var bound = size * part / parts
            while bound < size, table.lower[bound] != 0 { bound += 1 }
            bounds.append(min(bound + 1, size))
        }
        bounds.append(size)
        var found = [[Int32]](repeating: [], count: parts)
        table.lower.withUnsafeBytes { lower in
            table.entries.withUnsafeBufferPointer { entries in
                word.withUnsafeBytes { needle in
                    found.withUnsafeMutableBufferPointer { found in
                        let table = self.table
                        DispatchQueue.concurrentPerform(iterations: parts) { part in
                            var ids: [Int32] = []
                            var start = bounds[part]
                            let end = bounds[part + 1]
                            while start < end, let hit = memmem(lower.baseAddress! + start, end - start, needle.baseAddress!, needle.count) {
                                let index = table.entry(at: UnsafeRawPointer(hit) - lower.baseAddress!, in: entries)
                                let entry = entries[index]
                                if entry.flags & (Flag.deleted | Flag.root) == 0 { ids.append(Int32(index)) }
                                start = Int(entry.offset) + Int(entry.length) + 1
                            }
                            found[part] = ids
                        }
                    }
                }
            }
        }
        return found.flatMap { $0 }
    }

    /// Higher first: the whole name, then its start or a word in it; apps and folders before files; nearer the root
    /// and shorter before deeper and longer; hidden things and libraries last.
    private func score(_ id: Int32, word: [UInt8], single: Bool, kind: FileKind, lower: UnsafeRawBufferPointer) -> Int {
        let entry = table.entries[Int(id)]
        let name = UnsafeRawBufferPointer(rebasing: lower[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)])
        var score = 10_000 - Int(entry.length)
        if !word.isEmpty, let hit = word.withUnsafeBytes({ memmem(name.baseAddress!, name.count, $0.baseAddress!, word.count) }) {
            let at = UnsafeRawPointer(hit) - name.baseAddress!
            if single, word.count == name.count { score += 1000 }
            if single, at == 0, let dot = name.lastIndex(of: 0x2E), dot == word.count { score += 700 }
            if at == 0 {
                score += 300
            } else {
                let before = name[at - 1]
                let original = table.names[Int(entry.offset) + at]
                if !(before >= 0x30 && before <= 0x39 || before >= 0x61 && before <= 0x7A) || (original >= 0x41 && original <= 0x5A) { score += 150 }
            }
        }
        if kind == .app { score += 250 } else if kind == .folder { score += 40 }
        if name.first == 0x2E { score -= 300 }
        var depth = 0
        var parent = entry.parent
        while parent >= 0 {
            let up = table.entries[Int(parent)]
            if up.flags & Flag.root == 0 {
                depth += 1
                if lower[Int(up.offset)] == 0x2E { score -= 300 }
                if up.length == 7, lower[Int(up.offset)..<Int(up.offset) + 7].elementsEqual("library".utf8) { score -= 150 }
            }
            parent = up.parent
        }
        return score - depth * 4
    }

    private func kind(_ id: Int32) -> FileKind {
        table.lower.withUnsafeBytes { kind(id, lower: $0) }
    }

    private func kind(_ id: Int32, lower: UnsafeRawBufferPointer) -> FileKind {
        let entry = table.entries[Int(id)]
        let name = UnsafeRawBufferPointer(rebasing: lower[Int(entry.offset)..<Int(entry.offset) + Int(entry.length)])
        var key: UInt64 = 0
        if let dot = name.lastIndex(of: 0x2E), dot > 0, name.count - dot - 1 <= 8 {
            for byte in name[(dot + 1)...] { key = key << 8 | UInt64(byte) }
        }
        if entry.flags & Flag.folder != 0 {
            if let found = FileKind.byExtension[key], found == .app || found == .document { return found }
            return .folder
        }
        return FileKind.byExtension[key] ?? .other
    }
}

/// What a file is, for the filter above the results.
enum FileKind: String, CaseIterable, Sendable {
    case folder, app, document, image, media, code, archive, other

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .app: "应用"
        case .document: "文档"
        case .image: "图片"
        case .media: "音视频"
        case .code: "代码"
        case .archive: "压缩包"
        case .other: "其他"
        }
    }

    private static let extensions: [FileKind: [String]] = [
        .app: ["app", "prefpane"],
        .document: ["pdf", "doc", "docx", "pages", "txt", "md", "markdown", "rtf", "rtfd", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv",
                    "tsv", "epub", "odt", "ods", "odp", "tex", "log"],
        .image: ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "psd", "ai", "sketch", "fig", "ico", "icns",
                 "raw", "cr2", "nef", "arw", "dng", "avif"],
        .media: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "flv", "wmv", "mp3", "m4a", "wav", "flac", "aac", "aiff", "aif", "ogg", "opus", "caf"],
        .code: ["swift", "m", "mm", "h", "hpp", "c", "cc", "cpp", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "kts",
                "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss", "sass", "less", "sh", "zsh", "bash", "fish", "plist", "sql",
                "lua", "php", "cs", "dart", "vue", "svelte", "ipynb", "gradle", "cmake", "proto", "graphql", "ini", "conf", "env", "zig", "ex",
                "exs", "erl", "hs", "scala", "clj", "r", "jl", "pl", "nim"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "dmg", "pkg", "iso", "jar", "war", "xip"],
    ]

    /// Extensions of up to eight letters packed into an integer, so a search need not make strings.
    static let byExtension: [UInt64: FileKind] = {
        var table: [UInt64: FileKind] = [:]
        for (kind, list) in extensions {
            for ext in list { table[ext.utf8.reduce(0) { $0 << 8 | UInt64($1) }] = kind }
        }
        return table
    }()
}
