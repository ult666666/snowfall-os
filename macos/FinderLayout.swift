import Foundation

/// A read-only view of the active Finder desktop layout. Only requested household
/// names are retained. Reject unfamiliar records instead of guessing hit targets.
enum FinderLayout {
    private enum Invalid: Error { case store }
    private struct Cursor {
        let data: Data
        var index: Int
        let end: Int

        mutating func take(_ count: Int) throws -> Range<Int> {
            guard count >= 0, index >= 0, end <= data.count, count <= end - index else { throw Invalid.store }
            let range = index..<(index + count)
            index += count
            return range
        }

        mutating func word() throws -> Int {
            try take(4).reduce(0) { $0 << 8 | Int(data[$1]) }
        }

        mutating func ascii(_ count: Int) throws -> String {
            let range = try take(count)
            guard let s = String(data: data[range], encoding: .ascii) else { throw Invalid.store }
            return s
        }
    }

    static func points(in data: Data, for names: Set<String>, screen: CGSize) -> [String: CGPoint] {
        guard !names.isEmpty, data.count <= 16 * 1024 * 1024 else { return [:] }
        do {
            var header = Cursor(data: data, index: 0, end: data.count)
            guard try header.word() == 1, try header.ascii(4) == "Bud1" else { throw Invalid.store }
            let offset = try header.word(), length = try header.word()
            guard try header.word() == offset, offset + 4 + length <= data.count else { throw Invalid.store }
            var table = Cursor(data: data, index: offset + 4, end: offset + 4 + length)
            let count = try table.word()
            _ = try table.take(4)
            guard count > 0, count <= 65536 else { throw Invalid.store }
            var blocks: [Int] = []
            for _ in 0..<count { blocks.append(try table.word()) }
            _ = try table.take(((256 - count % 256) % 256) * 4)
            func block(_ number: Int) throws -> Cursor {
                guard blocks.indices.contains(number) else { throw Invalid.store }
                let address = blocks[number], size = 1 << (address & 31), start = (address & ~31) + 4
                guard address != 0, size <= data.count, start + size <= data.count else { throw Invalid.store }
                return Cursor(data: data, index: start, end: start + size)
            }
            let entries = try table.word()
            guard entries <= count else { throw Invalid.store }
            var tree: Int?
            for _ in 0..<entries {
                let byte = try table.take(1).lowerBound
                let label = try table.ascii(Int(data[byte]))
                let number = try table.word()
                if label == "DSDB" { tree = number }
            }
            guard let tree else { throw Invalid.store }
            var info = try block(tree)
            var pending = [try info.word()], visited = Set<Int>(), points: [String: CGPoint] = [:]
            while let id = pending.popLast() {
                guard visited.insert(id).inserted else { throw Invalid.store }
                var node = try block(id)
                let right = try node.word(), records = try node.word()
                guard records <= (node.end - node.index) / 12 else { throw Invalid.store }
                if right != 0 { pending.append(right) }
                for _ in 0..<records {
                    if right != 0 { pending.append(try node.word()) }
                    let nameLength = try node.word()
                    let nameBytes = try node.take(nameLength * 2)
                    let key = try node.ascii(4), type = try node.ascii(4)
                    let size: Int
                    switch type {
                    case "bool": size = 1
                    case "shor", "long", "type": size = 4
                    case "comp", "dutc": size = 8
                    case "blob": size = try node.word()
                    case "ustr": size = try node.word() * 2
                    default: throw Invalid.store
                    }
                    let payload = try node.take(size)
                    guard type == "blob", key == "dilc" || key == "Iloc",
                          let name = String(data: data[nameBytes], encoding: .utf16BigEndian), names.contains(name) else { continue }
                    var value = Cursor(data: data, index: payload.lowerBound, end: payload.upperBound)
                    let center: CGPoint
                    if key == "dilc", size == 32 {
                        guard try value.word() == 0 else { continue }
                        let anchor = try value.word()
                        let dx = CGFloat(Int32(bitPattern: UInt32(try value.word())))
                        let dy = CGFloat(Int32(bitPattern: UInt32(try value.word())))
                        // Current Finder stores signed point offsets from the center or a corner.
                        // For a corner anchor the sign identifies its side of each axis.
                        if anchor == 0 {
                            center = CGPoint(x: screen.width/2 + dx, y: screen.height/2 + dy)
                        } else if [0x10000, 0x20000, 0x30000, 0x40000].contains(anchor) {
                            center = CGPoint(x: (dx < 0 ? screen.width : 0) + dx, y: (dy < 0 ? screen.height : 0) + dy)
                        } else { continue }
                    } else if key == "Iloc", size == 16 {
                        center = CGPoint(x: try value.word(), y: try value.word())
                    } else { continue }
                    if CGRect(origin: .zero, size: screen).contains(center) { points[name] = center }
                }
            }
            return points
        } catch { return [:] }
    }
}
