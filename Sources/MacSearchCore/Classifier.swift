import Foundation
import Darwin

public enum SiftFlag {
    public static let dir: UInt8 = 0x01, symlink: UInt8 = 0x02, hidden: UInt8 = 0x04
    public static let deleted: UInt8 = 0x08, noise: UInt8 = 0x10, inPackage: UInt8 = 0x20
    public static let package: UInt8 = 0x40, userArea: UInt8 = 0x80
}

public enum Classifier {
    static let packages: Set<String> = Set("app bundle framework plugin kext appex xpc prefpane qlgenerator mdimporter saver component vst vst3 photoslibrary musiclibrary tvlibrary fcpbundle imovielibrary xcodeproj xcworkspace playground xcarchive dsym rtfd scptd lproj logicx band screenstudio pages numbers key".split(separator: " ").map(String.init))
    static let noiseNames: Set<String> = Set("node_modules .git .svn .hg __pycache__ .venv venv site-packages Pods DerivedData .gradle .npm .pnpm-store .yarn .cache .cargo .rustup .Trash Caches Cache .next .nuxt bower_components .idea .build .swiftpm CMakeFiles .tox .mypy_cache .pytest_cache .terraform".split(separator: " ").map(String.init))
    static let topNoise: Set<String> = Set("System private usr bin sbin opt Library cores".split(separator: " ").map(String.init))
    static let extGroups: [(UInt8, Set<String>)] = [
        (3, Set("pdf doc docx xls xlsx ppt pptx pages numbers key txt md markdown rtf rtfd csv tsv epub mobi odt ods odp tex log".split(separator: " ").map(String.init))),
        (4, Set("png jpg jpeg gif heic heif webp bmp tiff tif svg psd ai sketch fig raw cr2 cr3 nef arw dng ico icns avif".split(separator: " ").map(String.init))),
        (5, Set("mp4 mov mkv avi wmv flv webm m4v mpg mpeg 3gp rmvb".split(separator: " ").map(String.init))),
        (6, Set("mp3 wav flac aac m4a ogg wma aiff aif opus mid midi caf".split(separator: " ").map(String.init))),
        (7, Set("swift c h m mm cpp hpp cc js jsx mjs cjs ts tsx py rb go rs java kt php html htm css scss less vue svelte astro sh zsh bash json yaml yml toml xml sql lua dart cs r pl gradle plist ipynb".split(separator: " ").map(String.init))),
        (8, Set("zip rar 7z tar gz bz2 xz tgz zst dmg iso pkg jar war apk ipa".split(separator: " ").map(String.init)))
    ]
    private static func pack(_ s: String) -> UInt64 {
        let bytes = Array(s.utf8)
        guard !bytes.isEmpty, bytes.count <= 8, bytes.allSatisfy({ $0 < 128 }) else { return 0 }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1 >= 65 && $1 <= 90 ? $1 + 32 : $1) }
    }
    private static let packageBytesByLength: [Int: [[UInt8]]] = Dictionary(grouping: packages.map { Array($0.utf8) }, by: \.count)
    private static let kindKeys: [UInt64: UInt8] = {
        var table: [UInt64: UInt8] = [:]
        for (kind, exts) in extGroups { for ext in exts { table[pack(ext)] = kind } }
        return table
    }()
    private static let noiseBytes = noiseNames.map { Array($0.utf8) }
    private static let topNoiseBytes = topNoise.map { Array($0.utf8) }
    private static func lowerASCII(_ byte: UInt8) -> UInt8 {
        byte >= 65 && byte <= 90 ? byte + 32 : byte
    }
    public static func extensionKey(_ name: UnsafeBufferPointer<UInt8>) -> UInt64 {
        guard let dot = name.lastIndex(of: 46), dot + 1 < name.count, name.count - dot - 1 <= 8 else { return 0 }
        var key: UInt64 = 0
        for i in (dot + 1)..<name.count {
            let c = name[i]
            guard c < 128 else { return 0 }
            key = (key << 8) | UInt64(lowerASCII(c))
        }
        return key
    }
    static func isPackageExtension(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let dot = name.lastIndex(of: 46) else { return false }
        let start = dot + 1, length = name.count - start
        guard length > 0, let candidates = packageBytesByLength[length] else { return false }
        for candidate in candidates {
            var matches = true
            for offset in 0..<length {
                if lowerASCII(name[start + offset]) != candidate[offset] { matches = false; break }
            }
            if matches { return true }
        }
        return false
    }
    private static func isAppExtension(_ name: UnsafeBufferPointer<UInt8>) -> Bool {
        guard let dot = name.lastIndex(of: 46), name.count - dot - 1 == 3 else { return false }
        return lowerASCII(name[dot + 1]) == 97 && lowerASCII(name[dot + 2]) == 112 && lowerASCII(name[dot + 3]) == 112
    }
    static func extString(_ name: UnsafeBufferPointer<UInt8>) -> String {
        guard let dot = name.lastIndex(of: 46), dot + 1 < name.count, name.count - dot - 1 <= 8 else { return "" }
        return String(decoding: name[(dot + 1)...], as: UTF8.self).lowercased()
    }
    public static func flags(name: UnsafeBufferPointer<UInt8>, type: UInt32, bsdFlags: UInt32, inherited: UInt8) -> UInt8 {
        var f = inherited & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.userArea)
        if type == 1 { f |= SiftFlag.dir }
        if type == 2 { f |= SiftFlag.symlink }
        if name.first == 46 || bsdFlags & UInt32(UF_HIDDEN) != 0 { f |= SiftFlag.hidden }
        if type == 1 && isPackageExtension(name) { f |= SiftFlag.package }
        return f
    }
    public static func inheritedForChildren(dirFlags: UInt8, dirName: UnsafeBufferPointer<UInt8>, dirDepth: UInt8, parentName: UnsafeBufferPointer<UInt8>, isHome: Bool) -> UInt8 {
        var f = dirFlags & (SiftFlag.noise | SiftFlag.inPackage | SiftFlag.userArea)
        let isNoise = noiseBytes.contains { dirName.elementsEqual($0) }
        let isTopNoise = dirDepth == 1 && topNoiseBytes.contains { dirName.elementsEqual($0) }
        let isUserLibrary = dirDepth == 3 && dirName.elementsEqual("Library".utf8) && parentName.elementsEqual("Users".utf8)
        if isNoise || dirFlags & SiftFlag.hidden != 0 || isTopNoise || isUserLibrary { f |= SiftFlag.noise }
        if dirFlags & SiftFlag.package != 0 { f |= SiftFlag.inPackage }
        if isHome { f |= SiftFlag.userArea }
        return f
    }
    static func kind(forExtension key: UInt64) -> UInt8 { kindKeys[key] ?? 0 }
    public static func kind(name: UnsafeBufferPointer<UInt8>, flags: UInt8) -> UInt8 {
        let ext = extensionKey(name)
        if flags & SiftFlag.package != 0 && isAppExtension(name) { return 2 }
        if flags & SiftFlag.dir != 0 && flags & SiftFlag.package == 0 { return 1 }
        return kindKeys[ext] ?? 0
    }
}
