import Darwin
import Foundation

/// One entry read from a directory with `getattrlistbulk`.
struct BulkEntry: Sendable {
    enum ObjectType: Sendable { case file, directory, symlink, other }

    var name: String
    var type: ObjectType
    var device: Int32
    var created: Double?
    var modified: Double?
    var accessed: Double?
    var flags: UInt32
    var fileID: UInt64
    var isMountPoint: Bool
    var logicalSize: Int64
    var allocatedSize: Int64
    var linkCount: UInt32 = 1

    var isHiddenFlag: Bool { flags & UInt32(UF_HIDDEN) != 0 }
}

enum BulkReadError: Error, Sendable {
    case noAccess(Int32)
    case failed(Int32)
}

/// Fast directory listing using `getattrlistbulk(2)`.
///
/// The attribute buffer layout is fixed because we pass `FSOPT_PACK_INVAL_ATTRS`:
/// every requested attribute is present for every entry, and the returned
/// bitmap tells us which ones are valid.
enum BulkDirectoryReader {
    // Common attributes (bit order is the packing order).
    private static let cmnName: UInt32 = 0x0000_0001
    private static let cmnDevID: UInt32 = 0x0000_0002
    private static let cmnObjType: UInt32 = 0x0000_0008
    private static let cmnCrTime: UInt32 = 0x0000_0200
    private static let cmnModTime: UInt32 = 0x0000_0400
    private static let cmnAccTime: UInt32 = 0x0000_1000
    private static let cmnFlags: UInt32 = 0x0004_0000
    private static let cmnFileID: UInt32 = 0x0200_0000
    private static let cmnError: UInt32 = 0x2000_0000
    private static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    // Directory attributes.
    private static let dirMountStatus: UInt32 = 0x0000_0008
    // File attributes.
    private static let fileLinkCount: UInt32 = 0x0000_0001
    private static let fileTotalSize: UInt32 = 0x0000_0002
    private static let fileAllocSize: UInt32 = 0x0000_0004

    private static let optNoFollow: UInt64 = 0x1
    private static let optPackInval: UInt64 = 0x8

    private static let bufferSize = 256 * 1024

    /// Lists `path`. Throws `.noAccess` for permission errors so callers can mark the folder.
    static func read(directory path: String) throws(BulkReadError) -> [BulkEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == EACCES || err == EPERM { throw .noAccess(err) }
            throw .failed(err)
        }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnCrTime | cmnModTime
            | cmnAccTime | cmnFlags | cmnFileID | cmnError
        list.dirattr = dirMountStatus
        list.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        var entries: [BulkEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, optPackInval | optNoFollow)
            if count < 0 {
                let err = errno
                if err == EACCES || err == EPERM { throw .noAccess(err) }
                if entries.isEmpty { throw .failed(err) }
                break
            }
            if count == 0 { break }
            var entryPtr = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entryPtr.loadUnaligned(as: UInt32.self))
                if let entry = parse(entryPtr) { entries.append(entry) }
                entryPtr = entryPtr.advanced(by: length)
            }
        }
        return entries
    }

    private static func parse(_ start: UnsafeRawPointer) -> BulkEntry? {
        var p = start.advanced(by: 4)  // skip length
        let returnedCommon = p.loadUnaligned(as: UInt32.self)
        let returnedDir = p.advanced(by: 8).loadUnaligned(as: UInt32.self)
        let returnedFile = p.advanced(by: 12).loadUnaligned(as: UInt32.self)
        p = p.advanced(by: MemoryLayout<attribute_set_t>.size)

        // ATTR_CMN_ERROR is packed right after the returned-attributes set.
        let error = p.loadUnaligned(as: UInt32.self)
        p = p.advanced(by: 4)
        if returnedCommon & cmnError != 0, error != 0 { return nil }

        // Name (attrreference_t, offset relative to the reference itself).
        let nameOffset = p.loadUnaligned(as: Int32.self)
        let nameLength = p.advanced(by: 4).loadUnaligned(as: UInt32.self)
        let namePtr = p.advanced(by: Int(nameOffset)).assumingMemoryBound(to: CChar.self)
        let name = nameLength > 0 ? String(cString: namePtr) : ""
        p = p.advanced(by: 8)

        let device = p.loadUnaligned(as: Int32.self)
        p = p.advanced(by: 4)

        let objType = p.loadUnaligned(as: UInt32.self)
        p = p.advanced(by: 4)

        func readTime(_ bit: UInt32) -> Double? {
            let ts = p.loadUnaligned(as: timespec.self)
            p = p.advanced(by: MemoryLayout<timespec>.size)
            guard returnedCommon & bit != 0 else { return nil }
            return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
        }
        let created = readTime(cmnCrTime)
        let modified = readTime(cmnModTime)
        let accessed = readTime(cmnAccTime)

        let flags = p.loadUnaligned(as: UInt32.self)
        p = p.advanced(by: 4)
        let fileID = p.loadUnaligned(as: UInt64.self)
        p = p.advanced(by: 8)

        // Directory attributes are only packed for directories, file attributes only for
        // non-directories (verified empirically on APFS, even with FSOPT_PACK_INVAL_ATTRS).
        var mountStatus: UInt32 = 0
        if objType == UInt32(VDIR.rawValue) {
            mountStatus = p.loadUnaligned(as: UInt32.self)
            p = p.advanced(by: 4)
        }

        let linkCount = p.loadUnaligned(as: UInt32.self)
        p = p.advanced(by: 4)
        let totalSize = p.loadUnaligned(as: Int64.self)
        p = p.advanced(by: 8)
        let allocSize = p.loadUnaligned(as: Int64.self)

        let type: BulkEntry.ObjectType
        switch objType {
        case UInt32(VREG.rawValue): type = .file
        case UInt32(VDIR.rawValue): type = .directory
        case UInt32(VLNK.rawValue): type = .symlink
        default: type = .other
        }
        let isFileish = type != .directory
        return BulkEntry(
            name: name,
            type: type,
            device: device,
            created: created,
            modified: modified,
            accessed: accessed,
            flags: flags,
            fileID: fileID,
            isMountPoint: returnedDir & dirMountStatus != 0 && (mountStatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0,
            logicalSize: isFileish && returnedFile & fileTotalSize != 0 ? max(0, totalSize) : 0,
            allocatedSize: isFileish && returnedFile & fileAllocSize != 0 ? max(0, allocSize) : 0,
            linkCount: isFileish && returnedFile & fileLinkCount != 0 ? linkCount : 1
        )
    }
}
