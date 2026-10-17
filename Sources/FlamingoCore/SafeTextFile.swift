import Foundation
import Darwin

/// Coordinated compare-and-replace. The expected bytes are checked again immediately before
/// committing, and the replacement retains the source's permissions, ACLs and extended attributes.
public enum SafeTextFile {
    public static let byteLimit = 5 * 1024 * 1024

    public static func read(_ url: URL) throws -> (text: String, data: Data) {
        try DocumentFileIO.requireRegularPath(url)
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                let fd = try DocumentFileIO.openRegular(coordinated, writable: false)
                defer { close(fd) }
                let before = try DocumentFileIO.info(fd, path: coordinated.path)
                let data = try DocumentFileIO.read(fd, path: coordinated.path, limit: byteLimit)
                let after = try DocumentFileIO.info(fd, path: coordinated.path)
                var current = stat()
                guard lstat(coordinated.path, &current) == 0, current.st_dev == before.st_dev, current.st_ino == before.st_ino,
                      DocumentFileIO.sameVersion(before, after) else { throw DocumentError.changedOnDisk }
                return data
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        let data = try result.get()
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw DocumentError.unsupportedText }
        return (text, data)
    }

    public static func save(_ text: String, to url: URL, replacing expected: Data) throws -> Data {
        try DocumentFileIO.requireRegularPath(url)
        let next = Data(text.utf8)
        guard next.count <= byteLimit, expected.count <= byteLimit else { throw DocumentError.tooLarge }
        guard !next.contains(0) else { throw DocumentError.unsupportedText }
        let coordinator = NSFileCoordinator()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result { try replace(next, at: coordinated, expected: expected) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
        return next
    }

    private static func replace(_ next: Data, at url: URL, expected: Data) throws {
        let directory = try DocumentFileIO.openDirectory(url.deletingLastPathComponent())
        defer { close(directory) }
        let name = url.lastPathComponent
        // O_RDWR respects a source file's write permissions even when its directory is writable.
        let source = openat(directory, name, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard source >= 0 else { throw DocumentFileIO.error(path: url.path) }
        defer { close(source) }
        let original = try DocumentFileIO.info(source, path: url.path)
        guard original.st_mode & S_IFMT == S_IFREG else { throw DocumentError.unsupportedText }
        guard try DocumentFileIO.read(source, path: url.path, limit: byteLimit) == expected else { throw DocumentError.changedOnDisk }
        let temporary = try DocumentFileIO.temporary(in: directory, path: url.path)
        defer { close(temporary.fd); unlinkat(directory, temporary.name, 0) }
        try DocumentFileIO.write(next, to: temporary.fd, path: url.path)
        // COPYFILE_METADATA includes STAT, ACL and XATTR: com.flamingo.id, Finder tags,
        // resource forks, creation date and custom modes survive the atomic inode replacement.
        guard fcopyfile(source, temporary.fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw DocumentFileIO.error(path: url.path)
        }
        // A new edit should have a new modification time, while retaining the original birth time.
        var times = [timeval(tv_sec: 0, tv_usec: 0), timeval(tv_sec: 0, tv_usec: 0)]
        gettimeofday(&times[1], nil)
        times[0] = timeval(tv_sec: original.st_atimespec.tv_sec, tv_usec: Int32(original.st_atimespec.tv_nsec / 1000))
        guard futimes(temporary.fd, &times) == 0, fsync(temporary.fd) == 0 else { throw DocumentFileIO.error(path: url.path) }
        var current = stat()
        guard fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == original.st_dev, current.st_ino == original.st_ino,
              DocumentFileIO.sameVersion(original, try DocumentFileIO.info(source, path: url.path)),
              try DocumentFileIO.read(source, path: url.path, limit: byteLimit) == expected else {
            throw DocumentError.changedOnDisk
        }
        guard renameat(directory, temporary.name, directory, name) == 0 else { throw DocumentFileIO.error(path: url.path) }
        // A successful rename is the commit point. Directory fsync is best effort because
        // some volumes don't support it; a post-commit sync failure must not report "unsaved".
        _ = fsync(directory)
    }
}

/// Descriptor-based operations keep reads bounded and pin the selected parent directory.
/// Neither the editor nor document creation follows a final-component symlink.
enum DocumentFileIO {
    static func error(path: String, code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    static func requireRegularPath(_ url: URL) throws {
        guard url.isFileURL else { throw DocumentError.unsupportedText }
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw error(path: url.path) }
        guard value.st_mode & S_IFMT == S_IFREG else { throw DocumentError.unsupportedText }
    }

    static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw DocumentError.invalidName }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw error(path: url.path) }
        return fd
    }

    static func openRegular(_ url: URL, writable: Bool) throws -> Int32 {
        guard url.isFileURL else { throw DocumentError.unsupportedText }
        let fd = open(url.path, (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw error(path: url.path) }
        do {
            guard try info(fd, path: url.path).st_mode & S_IFMT == S_IFREG else { throw DocumentError.unsupportedText }
            return fd
        } catch { close(fd); throw error }
    }

    static func info(_ fd: Int32, path: String) throws -> stat {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw error(path: path) }
        return value
    }

    static func sameVersion(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size
            && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    static func read(_ fd: Int32, path: String, limit: Int) throws -> Data {
        guard try info(fd, path: path).st_size <= limit else { throw DocumentError.tooLarge }
        guard lseek(fd, 0, SEEK_SET) >= 0 else { throw error(path: path) }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= limit {
            let length = min(bytes.count, limit + 1 - data.count)
            let count = Darwin.read(fd, &bytes, length)
            if count == 0 { return data }
            if count < 0 { if errno == EINTR { continue }; throw error(path: path) }
            data.append(contentsOf: bytes.prefix(count))
        }
        throw DocumentError.tooLarge
    }

    static func write(_ data: Data, to fd: Int32, path: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 { if errno == EINTR { continue }; throw error(path: path) }
                guard count > 0 else { throw error(path: path, code: EIO) }
                offset += count
            }
        }
    }

    static func temporary(in directory: Int32, path: String, mode: mode_t = 0o600) throws -> (fd: Int32, name: String) {
        for _ in 0..<8 {
            let name = ".flamingo-" + UUID().uuidString + ".tmp"
            let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
            if fd >= 0 { return (fd, name) }
            if errno != EEXIST { throw error(path: path) }
        }
        throw error(path: path, code: EEXIST)
    }
}
