import Foundation
import Darwin

private struct AltBuildBuffer {
    var owners: [UInt32] = []
    var lengths: [UInt32] = []
    var bytes: [UInt8] = []
    mutating func append(owner: UInt32, key: [UInt8]) {
        owners.append(owner)
        lengths.append(UInt32(key.count))
        bytes.append(contentsOf: key)
    }
}

private struct AltReference {
    var owner: UInt32
    var worker: Int
    var ordinal: Int
    var offset: Int
    var length: Int
}

extension IndexStore {
    public convenience init(scan: ScanOutput, config: IndexConfig) {
        let workerCount = scan.buffers.count
        var lengths = [UInt32](repeating: 0, count: scan.count)
        lengths.withUnsafeMutableBufferPointer { lengthPointer in
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                let buffer = scan.buffers[worker]
                for j in buffer.ids.indices { lengthPointer[Int(buffer.ids[j])] = buffer.nameLens[j] }
            }
        }
        var off = [UInt32](repeating: 0, count: scan.count + 1)
        for i in 0..<scan.count { off[i+1] = off[i] + lengths[i] }
        let rawLen = Int(off[scan.count])

        _ = Pinyin.shared
        var altBuffers = Array(repeating: AltBuildBuffer(), count: workerCount)
        altBuffers.withUnsafeMutableBufferPointer { outputs in
            DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
                let buffer = scan.buffers[worker]
                var output = AltBuildBuffer()
                var full: [UInt8] = [], initials: [UInt8] = []
                full.reserveCapacity(2048); initials.reserveCapacity(2048)
                buffer.nameBytes.withUnsafeBufferPointer { allNames in
                    var offset = 0
                    for j in buffer.ids.indices {
                        let len = Int(buffer.nameLens[j])
                        let name = UnsafeBufferPointer(start: allNames.baseAddress!.advanced(by: offset), count: len)
                        offset += len
                        if !name.contains(where: { $0 >= 128 }) { continue }
                        if Pinyin.shared.keys(for: name, full: &full, initials: &initials) {
                            output.append(owner: buffer.ids[j], key: full)
                            output.append(owner: buffer.ids[j], key: initials)
                        } else {
                            full.removeAll(keepingCapacity: true)
                            full.append(contentsOf: String(decoding: name, as: UTF8.self).lowercased().utf8)
                            var differs = full.count != name.count
                            if !differs {
                                for k in name.indices {
                                    let byte = name[k]
                                    if full[k] != (byte >= 65 && byte <= 90 ? byte | 32 : byte) { differs = true; break }
                                }
                            }
                            if differs { output.append(owner: buffer.ids[j], key: full) }
                        }
                    }
                }
                outputs[worker] = output
            }
        }
        var refs: [AltReference] = []
        for worker in altBuffers.indices {
            let buffer = altBuffers[worker]
            var offset = 0
            for ordinal in buffer.owners.indices {
                let len = Int(buffer.lengths[ordinal])
                refs.append(AltReference(owner: buffer.owners[ordinal], worker: worker, ordinal: ordinal, offset: offset, length: len))
                offset += len
            }
        }
        refs.sort { $0.owner == $1.owner ? ($0.worker == $1.worker ? $0.ordinal < $1.ordinal : $0.worker < $1.worker) : $0.owner < $1.owner }
        let altLen = refs.reduce(0) { $0 + $1.length }
        let caseSensitiveNames = config.rootPath.withCString { pathconf($0, _PC_CASE_SENSITIVE) == 1 }
        self.init(rootPath: config.rootPath, count: scan.count, namesLen: rawLen, altCount: refs.count, altLen: altLen, fingerprint: config.fingerprint, homeIndex: scan.homeIndex, finishedAt: scan.finishedAt, caseSensitiveNames: caseSensitiveNames)
        coverage = scan.coverage
        nameOff.update(from: off, count: off.count)
        parent[0] = 0; sizeC[0] = 0; mtime[0] = 0; flags[0] = SiftFlag.dir
        depth[0] = UInt8(min(config.rootPath.split(separator: "/").count, 255)); kind[0] = 1
        DispatchQueue.concurrentPerform(iterations: workerCount) { worker in
            let buffer = scan.buffers[worker]
            buffer.nameBytes.withUnsafeBufferPointer { raw in
                var position = 0
                for j in buffer.ids.indices {
                    let i = Int(buffer.ids[j]), len = Int(buffer.nameLens[j])
                    parent[i] = buffer.parents[j]; sizeC[i] = buffer.sizes[j]; mtime[i] = buffer.mtimes[j]
                    flags[i] = buffer.flags[j]; depth[i] = buffer.depths[j]; kind[i] = buffer.kinds[j]
                    if len > 0 { names.advanced(by: Int(off[i])).update(from: raw.baseAddress!.advanced(by: position), count: len) }
                    position += len
                }
            }
        }
        var altPosition = 0
        for (j, ref) in refs.enumerated() {
            altOff[j] = UInt32(altPosition)
            altOwner[j] = ref.owner
            altBuffers[ref.worker].bytes.withUnsafeBufferPointer { bytes in
                if ref.length > 0 { altNames.advanced(by: altPosition).update(from: bytes.baseAddress!.advanced(by: ref.offset), count: ref.length) }
            }
            altPosition += ref.length
        }
        altOff[refs.count] = UInt32(altPosition)
    }
}
