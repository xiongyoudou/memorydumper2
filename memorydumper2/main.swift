
import AppKit


struct Pointer {
    var address: UInt
    
    init(_ address: UInt) {
        self.address = address
    }
    
    init(_ ptr: UnsafeRawPointer) {
        address = UInt(bitPattern: ptr)
    }
    
    var voidPtr: UnsafeRawPointer? {
        return UnsafeRawPointer(bitPattern: address)
    }
}

extension Pointer: CustomStringConvertible {
    var description: String {
        return String(format: "%p", address)
    }
}

extension Pointer: Hashable {
    var hashValue: Int {
        return address.hashValue
    }
    
    static func ==(lhs: Pointer, rhs: Pointer) -> Bool {
        return lhs.address == rhs.address
    }
    
    static func +(lhs: Pointer, rhs: UInt) -> Pointer {
        return Pointer(lhs.address + rhs)
    }
    
    static func -(lhs: Pointer, rhs: Pointer) -> UInt {
        return lhs.address - rhs.address
    }
}

func symbolInfo(_ ptr: Pointer) -> Dl_info? {
    var info = Dl_info()
    let result = dladdr(ptr.voidPtr, &info)
    return result == 0 ? nil : info
}

func symbolName(_ ptr: Pointer) -> String? {
    if let info = symbolInfo(ptr) {
        if let symbolAddr = info.dli_saddr, Pointer(symbolAddr) == ptr {
            return String(cString: info.dli_sname)
        }
    }
    return nil
}

func nextSymbol(ptr: Pointer, limit: UInt) -> Pointer? {
    if let info = symbolInfo(ptr) {
        for i in 1..<limit {
            let candidate = ptr + i
            guard let candidateInfo = symbolInfo(candidate) else { return nil }
            if info.dli_saddr != candidateInfo.dli_saddr {
                return candidate
            }
        }
    }
    return nil
}

func symbolLength(ptr: Pointer, limit: UInt) -> UInt? {
    return nextSymbol(ptr: ptr, limit: limit).map({ $0 - ptr })
}

func demangle(_ string: String) -> String {
    return demangleCpp(demangleSwift(string))
}

func demangleSwift(_ string: String) -> String {
    return demangle(string, tool: ["swift-demangle"])
}

func demangleCpp(_ string: String) -> String {
//    return demangle(string, tool: ["c++filt", "-n"])
    // 注意，此处上面注释的代码会报错：Too many levels of symbolic links
    // 最终发现：c++filt -> llvm-cxxfilt
    // 所以直接将命令改成源文件，则解决该问题
    return demangle(string, tool: ["llvm-cxxfilt", "-n"])
}

func demangle(_ string: String, tool: [String]) -> String {
    let task = Process()
    task.launchPath = "/usr/bin/xcrun"
    task.arguments = tool
    
    let inPipe = Pipe()
    let outPipe = Pipe()
    task.standardInput = inPipe
    task.standardOutput = outPipe
    
    task.launch()
    DispatchQueue.global().async(execute: {
        inPipe.fileHandleForWriting.write(string.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
    })
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)!
}

extension mach_vm_address_t {
    init(_ ptr: UnsafeRawPointer?) {
        self.init(UInt(bitPattern: ptr))
    }
    
    init(_ ptr: Pointer) {
        self.init(ptr.address)
    }
}

func safeRead(ptr: Pointer, into: inout [UInt8]) -> Bool {
    let result = into.withUnsafeMutableBufferPointer({ bufferPointer -> kern_return_t in
        var outSize: mach_vm_size_t = 0
        return mach_vm_read_overwrite(
            mach_task_self_,
            mach_vm_address_t(ptr),
            mach_vm_size_t(bufferPointer.count),
            mach_vm_address_t(bufferPointer.baseAddress),
            &outSize)
    })
    return result == KERN_SUCCESS
}

func safeRead(ptr: Pointer, limit: Int) -> [UInt8] {
    var buffer: [UInt8] = []
    var eightBytes: [UInt8] = Array(repeating: 0, count: 8)
    while buffer.count < limit {
        let success = safeRead(ptr: ptr + UInt(buffer.count), into: &eightBytes)
        if !success {
            break
        }
        buffer.append(contentsOf: eightBytes)
    }
    return buffer
}

func hexString<Seq: Sequence>(bytes: Seq, limit: Int? = nil, separator: String = " ") -> String where Seq.Iterator.Element == UInt8 {
    let spacesInterval = 8
    var result = ""
    for (index, byte) in bytes.enumerated() {
        if let limit = limit, index >= limit {
            result.append("...")
            break
        }
        if index > 0 && index % spacesInterval == 0 {
            result.append(separator)
        }
        result.append(String(format: "%02x", byte))
    }
    return result
}

func objcClassName(ptr: Pointer) -> String? {
    struct Static {
        static let classMap: [Pointer: AnyClass] = {
            var classCount: UInt32 = 0
            let list = objc_copyClassList(&classCount)!
            
            // 此处加了这一句代码，否则将会在下面for循环中 newList[Int(i)]语句处崩溃
            // 原因是因为新系统下objc_copyClassList函数的返回类型有变化
            // 所以通过下面的语句，做一个类型转换
            // 参考链接https://stackoverflow.com/questions/60853427/objc-copyclasslist-crash-exc-bad-instruction-after-update-to-ios-13-4-xcode-1
            var newList = UnsafeBufferPointer(start: list, count: Int(classCount))
            
            var map: [Pointer: AnyClass] = [:]
            for i in 0 ..< classCount {
                let classObj: AnyClass = newList[Int(i)]
                let classPtr = unsafeBitCast(classObj, to: Pointer.self)
                map[classPtr] = classObj
            }
            return map
        }()
    }
    
    return Static.classMap[ptr].map({ NSStringFromClass($0) })
}

func objcInstanceClassName(ptr: Pointer) -> String? {
    let isaBytes = safeRead(ptr: ptr, limit: MemoryLayout<Pointer>.size)
    guard isaBytes.count >= MemoryLayout<Pointer>.size else { return nil }
    
    let isa = isaBytes.withUnsafeBufferPointer({ buffer -> Pointer in
        return buffer.baseAddress!.withMemoryRebound(to: Pointer.self, capacity: 1, { $0.pointee })
    })
    return objcClassName(ptr: isa)
}

struct PointerAndOffset {
    var pointer: Pointer
    var offset: Int
}

struct Memory {
    var buffer: [UInt8]
    var isMalloc: Bool
    var symbolName: String?
    
    init(buffer: [UInt8]) {
        self.buffer = buffer
        self.isMalloc = false
    }
    
    init?(ptr: Pointer, knownSize: UInt? = nil) {
        let mallocLength = UInt(malloc_size(ptr.voidPtr))
        
        isMalloc = mallocLength > 0
        symbolName = symbolInfo(ptr).flatMap({
            if let name = $0.dli_sname {
                return demangle(String(cString: name))
            } else {
                return nil
            }
        })
        
        let length = knownSize ?? symbolLength(ptr: ptr, limit: 4096) ?? mallocLength
        if length > 0 || knownSize == 0 {
            buffer = Array(repeating: 0, count: Int(length))
            let success = safeRead(ptr: ptr, into: &buffer)
            if !success {
                return nil
            }
        } else {
            buffer = safeRead(ptr: ptr, limit: 128)
            if buffer.isEmpty {
                return nil
            }
        }
    }
    
    func scanPointers() -> [PointerAndOffset] {
        return buffer.withUnsafeBufferPointer({ bufferPointer in
            return bufferPointer.baseAddress?.withMemoryRebound(to: Pointer.self, capacity: bufferPointer.count / MemoryLayout<Pointer>.size, {
                let castBufferPointer = UnsafeBufferPointer(start: $0, count: bufferPointer.count / MemoryLayout<Pointer>.size)
                return castBufferPointer.enumerated().map({ PointerAndOffset(pointer: $1, offset: $0 * MemoryLayout<Pointer>.size) })
            }) ?? []
        })
    }
    
    func scanStrings() -> [String] {
        let lowerBound: UInt8 = 32
        let upperBound: UInt8 = 126
        
        let pieces = buffer.split(whereSeparator: { !(lowerBound ... upperBound ~= $0) })
        let sufficientlyLongPieces = pieces.filter({ $0.count >= 4 })
        return sufficientlyLongPieces.map({ String(bytes: $0, encoding: .utf8)! })
    }
}

class MemoryRegion {
    var depth: Int
    let pointer: Pointer
    let memory: Memory
    var children: [Child] = []
    var didScan = false
    
    init(depth: Int, pointer: Pointer, memory: Memory) {
        self.depth = depth
        self.pointer = pointer
        self.memory = memory
    }
    
    struct Child {
        var offset: Int
        var region: MemoryRegion
    }
}

extension MemoryRegion: Hashable {
    var hashValue: Int {
        return pointer.hashValue
    }
}

func ==(lhs: MemoryRegion, rhs: MemoryRegion) -> Bool {
    return lhs.pointer == rhs.pointer
}

func buildMemoryRegionTree(ptr: UnsafeRawPointer, knownSize: UInt?, maxDepth: Int) -> [MemoryRegion] {
    let memory = Memory(ptr: Pointer(ptr), knownSize: knownSize)
    let maybeRootRegion = memory.map({ MemoryRegion(depth: 1, pointer: Pointer(ptr), memory: $0) })
    guard let rootRegion = maybeRootRegion else { return [] }
    
    var allRegions: [Pointer: MemoryRegion] = [rootRegion.pointer: rootRegion]
    
    var toScan: Set = [rootRegion]
    while let region = toScan.popFirst() {
        if region.didScan || region.depth >= maxDepth { continue }
        
        let childPointers = region.memory.scanPointers()
        for pointerAndOffset in childPointers {
            let pointer = pointerAndOffset.pointer
            if let existingRegion = allRegions[pointer] {
                existingRegion.depth = min(existingRegion.depth, region.depth + 1)
                region.children.append(.init(offset: pointerAndOffset.offset, region: existingRegion))
                toScan.insert(existingRegion)
            } else if let memory = Memory(ptr: pointer) {
                let childRegion = MemoryRegion(depth: region.depth + 1, pointer: pointer, memory: memory)
                allRegions[pointer] = childRegion
                region.children.append(.init(offset: pointerAndOffset.offset, region: childRegion))
                toScan.insert(childRegion)
            }
        }
        region.didScan = true
    }
    
    return Array(allRegions.values)
}

enum DumpOptions {
    case all
    case some(Set<String>)
    case getAvailable((String) -> Void)
    
    // 此处参考autoclosure章节内容
    // https://docs.swift.org/swift-book/LanguageGuide/Closures.html
    // 开始不理解下面定义的属性processOptions的意义，即 = {}()这种形式
    // 后面发觉这其实就是先利用{}定义一个autoclosure，而后直接利用()调用closure
    
    // 针对这种语法形式在Swift官方文档『Initializaton』这一节最后面
    // 的内容「Setting a Default Property Value with a Closure or Function」有描述
    static let processOptions: DumpOptions = {
        // 先统一返回此选项，方便调试
        return .all
        
        /*
        let parameters = CommandLine.arguments.dropFirst()
        if parameters.count == 0 {
            print("Available dumps are listed here. Pass the desired dumps as arguments, or pass \"all\" to dump all available:")
            return .getAvailable({ print($0) })
        } else if parameters == ["all"] {
            return .all
        } else if parameters == ["prompt"] {
            print("Enter the dump to run:")
            guard let line = readLine(), !line.isEmpty else {
                print("You must enter something. Available dumps:")
                return .getAvailable({ print($0) })
            }
            return line == "all" ? .all : .some([line])
        } else {
            return .some(Set(parameters))
        }
        */
    }()
}

func dumpAndOpenGraph(dumping ptr: UnsafeRawPointer, knownSize: UInt?, maxDepth: Int, filename: String) {
    switch DumpOptions.processOptions {
    case .all:
        break
    case .some(let selected):
        if !selected.contains(filename) {
            return
        }
    case .getAvailable(let callback):
        callback(filename)
        return
    }
    var result = ""
    func line(_ string: String) {
        result += string
        result += "\n"
    }
    
    func graphvizNodeName(region: MemoryRegion) -> String {
        let s = String(describing: region.pointer)
        return "_" + s[ s.index(s.startIndex, offsetBy: 2)...]
    }
    
    let regions = buildMemoryRegionTree(ptr: ptr, knownSize: knownSize, maxDepth: maxDepth)
    
    line("digraph memory_dump_graph {")
    line("graph [bgcolor=black]")
    for region in regions {
        let memoryString = hexString(bytes: region.memory.buffer, limit: 64, separator: "\n")
        let labelName: String
        if let className = objcClassName(ptr: region.pointer) {
            labelName = "ObjC class \(demangle(className))"
        } else if let className = objcInstanceClassName(ptr: region.pointer) {
            labelName = "Instance of \(demangle(className))"
        } else if let symbolName = region.memory.symbolName {
            labelName = symbolName
        } else if region.memory.isMalloc {
            labelName = "malloc"
        } else {
            labelName = "unknown"
        }
        
        var label = "\(labelName) \(region.pointer) (\(region.memory.buffer.count) bytes)\n\(memoryString)"
        
        let strings = region.memory.scanStrings()
        if strings.count > 0 {
            label += "\nStrings:\n"
            label += strings.joined(separator: "\n")
        }
        
        let escaped = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        
        line("\(graphvizNodeName(region: region)) [style=filled] [fillcolor=white] [label=\"\(escaped)\"]")
        
        for child in region.children {
            line("\(graphvizNodeName(region: region)) -> \(graphvizNodeName(region: child.region)) [color=white] [fontcolor=white] [label=\"@\(child.offset)\"]")
        }
    }
    line("}")
    
    let path = "\(filename).dot"

    try! result.write(toFile: path, atomically: false, encoding: .utf8)
    
//    NSWorkspace.shared.openFile(path, withApplication: "Graphviz")
    // 此处的改动参考链接：https://www.jianshu.com/p/c80994019053
    runScript(fileName: filename);
    print("执行结束：", "dot -T png \(filename).dot -o \(filename).png")
}

// 执行脚本
func runScript(fileName: String) {
    // 初始化并设置shell 执行命令的路径(命令解释器)
    let task = Process()
    task.launchPath = "/bin/sh";
    
    // -c 用来执行string-commands（命令字符串），
    // 也就说不管后面的字符串里是什么都会被当做shellcode来执行
    // dot command
    let dotCmd = "/usr/local/bin/dot"
    task.arguments = ["-c", "\(dotCmd) -T png \(fileName).dot -o \(fileName).png"]
    
    // 开始 task
    task.launch()
}

func dumpAndOpenGraph<T>(dumping value: T, maxDepth: Int, filename: String) {
    var value = value
    dumpAndOpenGraph(dumping: &value, knownSize: UInt(MemoryLayout<T>.size), maxDepth: maxDepth, filename: filename)
}

func dumpAndOpenGraph(dumping object: AnyObject, maxDepth: Int, filename: String) {
    dumpAndOpenGraph(dumping: unsafeBitCast(object, to: UnsafeRawPointer.self), knownSize: nil, maxDepth: maxDepth, filename: filename)
}


// Dumping of sample objects follows from here.

protocol P {
    func f()
    func g()
    func h()
}

/**
 注意，开始下面的filename有空格（比如Simple struct），导致生成报错，故都改成无空格形式（比如SimpleStruct）
 */

/**
 另外，注意，下面所有的class定义，必须得显式的继承自NSObject，方才能正确执行完
 否则会造成死循环，并最终报错：Failed to set posix_spawn_file_actions for fd 2 at index 2 with errno 9
 该问题参考链接https://www.jianshu.com/p/c80994019053下方的评论
 */

struct EmptyStruct {}
dumpAndOpenGraph(dumping: EmptyStruct(), maxDepth: 60, filename: "EmptyStruct")

class EmptyClass: NSObject {}
dumpAndOpenGraph(dumping: EmptyClass(), maxDepth: 60, filename: "EmptyClass")

class EmptyObjCClass: NSObject {}
dumpAndOpenGraph(dumping: EmptyObjCClass(), maxDepth: 60, filename: "EmptyObjCClass")

struct SimpleStruct {
    var x: Int = 1
    var y: Int = 2
    var z: Int = 3
}
dumpAndOpenGraph(dumping: SimpleStruct(), maxDepth: 60, filename: "SimpleStruct")

class SimpleClass {
    var x: Int = 1
    var y: Int = 2
    var z: Int = 3
}
dumpAndOpenGraph(dumping: SimpleClass(), maxDepth: 6, filename: "SimpleClass")

struct StructWithPadding {
    var a: UInt8 = 1
    var b: UInt8 = 2
    var c: UInt8 = 3
    var d: UInt16 = 4
    var e: UInt8 = 5
    var f: UInt32 = 6
    var g: UInt8 = 7
    var h: UInt64 = 8
}
dumpAndOpenGraph(dumping: StructWithPadding(), maxDepth: 60, filename: "StructWithPadding")


class ClassWithPadding: NSObject {
    var a: UInt8 = 1
    var b: UInt8 = 2
    var c: UInt8 = 3
    var d: UInt16 = 4
    var e: UInt8 = 5
    var f: UInt32 = 6
    var g: UInt8 = 7
    var h: UInt64 = 8
}
dumpAndOpenGraph(dumping: ClassWithPadding(), maxDepth: 60, filename: "ClassWithPadding")

class DeepClassSuper1: NSObject {
    var a = 1
}
class DeepClassSuper2: DeepClassSuper1 {
    var b = 2
}
class DeepClassSuper3: DeepClassSuper2 {
    var c = 3
}
class DeepClass: DeepClassSuper3 {
    var d = 4
}
dumpAndOpenGraph(dumping: DeepClass(), maxDepth: 60, filename: "DeepClass")

dumpAndOpenGraph(dumping: [1, 2, 3, 4, 5], maxDepth: 4, filename: "IntegerArray")

struct StructSmallP: P {
    func f() {}
    func g() {}
    func h() {}
    var a = 0x6c6c616d73
}
struct StructBigP: P {
    func f() {}
    func g() {}
    func h() {}
    var a = 0x656772616c
    var b = 0x1010101010101010
    var c = 0x2020202020202020
    var d = 0x3030303030303030
}
struct ClassP: P {
    func f() {}
    func g() {}
    func h() {}
    var a = 0x7373616c63
    var b = 0x4040404040404040
    var c = 0x5050505050505050
    var d = 0x6060606060606060
}
struct ProtocolHolder {
    var a: P
    var b: P
    var c: P
}
let holder = ProtocolHolder(a: StructSmallP(), b: StructBigP(), c: ClassP())
dumpAndOpenGraph(dumping: holder, maxDepth: 4, filename: "ProtocolTypes")

enum SimpleEnum {
    case A, B, C, D, E
}
struct SimpleEnumHolder {
    var a: SimpleEnum
    var b: SimpleEnum
    var c: SimpleEnum
    var d: SimpleEnum
    var e: SimpleEnum
}
dumpAndOpenGraph(dumping: SimpleEnumHolder(a: .A, b: .B, c: .C, d: .D, e: .E), maxDepth: 5, filename: "SimpleEnum")

enum IntRawValueEnum: Int {
    case A = 1, B, C, D, E
}
struct IntRawValueEnumHolder {
    var a: IntRawValueEnum
    var b: IntRawValueEnum
    var c: IntRawValueEnum
    var d: IntRawValueEnum
    var e: IntRawValueEnum
}
dumpAndOpenGraph(dumping: IntRawValueEnumHolder(a: .A, b: .B, c: .C, d: .D, e: .E), maxDepth: 5, filename: "IntRawValueEnum")

enum StringRawValueEnum: String {
    case A = "whatever", B, C, D, E
}
struct StringRawValueEnumHolder {
    var a: StringRawValueEnum
    var b: StringRawValueEnum
    var c: StringRawValueEnum
    var d: StringRawValueEnum
    var e: StringRawValueEnum
}
dumpAndOpenGraph(dumping: StringRawValueEnumHolder(a: .A, b: .B, c: .C, d: .D, e: .E), maxDepth: 5, filename: "StringRawValueEnum")

enum OneAssociatedObjectEnum {
    case A(AnyObject)
    case B, C, D, E
}
struct OneAssociatedObjectEnumHolder {
    var a: OneAssociatedObjectEnum
    var b: OneAssociatedObjectEnum
    var c: OneAssociatedObjectEnum
    var d: OneAssociatedObjectEnum
    var e: OneAssociatedObjectEnum
}
dumpAndOpenGraph(dumping: OneAssociatedObjectEnumHolder(a: .A(NSObject()), b: .B, c: .C, d: .D, e: .E), maxDepth: 5, filename: "OneSssociatedObjectEnum")

enum ManyAssociatedObjectsEnum {
    case A(AnyObject)
    case B(AnyObject)
    case C(AnyObject)
    case D(AnyObject)
    case E(AnyObject)
}
struct ManyAssociatedObjectsEnumHolder {
    var a: ManyAssociatedObjectsEnum
    var b: ManyAssociatedObjectsEnum
    var c: ManyAssociatedObjectsEnum
    var d: ManyAssociatedObjectsEnum
    var e: ManyAssociatedObjectsEnum
}
dumpAndOpenGraph(dumping: ManyAssociatedObjectsEnumHolder(a: .A(NSObject()), b: .B(NSObject()), c: .C(NSObject()), d: .D(NSObject()), e: .E(NSObject())), maxDepth: 5, filename: "ManySssociatedObjectsEnum")

DumpCMemory({ (pointer: UnsafeRawPointer?, knownSize: Int, maxDepth: Int, name: UnsafePointer<Int8>?) in
    dumpAndOpenGraph(dumping: pointer!, knownSize: UInt(knownSize), maxDepth: maxDepth, filename: String(cString: name!))
})
