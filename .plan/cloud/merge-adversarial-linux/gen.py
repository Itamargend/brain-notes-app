# Builds a Linux shadow of Packages/BrainNotesKit inside the chroot. Real sources are copied with
# mechanical patches for Apple-only imports; rerun after every edit to the repo.
import os, re, shutil, sys
REPO="/home/user/brain-notes-app"
ROOT="/tmp/claude-0/-home-user-brain-notes-app/b73f4df5-2b79-566c-9e92-7d7276832429/scratchpad/swift/root"
OUT=ROOT+"/lk"
HERE=os.path.dirname(os.path.abspath(__file__))
skip_tests=set(sys.argv[1].split(",")) if len(sys.argv)>1 and sys.argv[1] else set()
src=OUT+"/Sources/BrainNotesKit"; tst=OUT+"/Tests/BrainNotesKitTests"
for d in (src,tst):
    if os.path.isdir(d): shutil.rmtree(d)
    os.makedirs(d)
os.makedirs(OUT+"/Sources/CZlib",exist_ok=True)
open(OUT+"/Sources/CZlib/module.modulemap","w").write('module CZlib [system] {\n header "shim.h"\n link "z"\n export *\n}\n')
open(OUT+"/Sources/CZlib/shim.h","w").write('#include <zlib.h>\n')
NET="import Foundation\n#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n"
def patch(name,t):
    t=re.sub(r'^import (CryptoKit|os|Network|Security)\n','',t,flags=re.M)
    t=t.replace("import Compression\n","import CZlib\n")
    t=t.replace("import Foundation\n",NET,1)
    if name=="Auth.swift":
        a=t.index("public struct KeychainTokenStore"); b=t.index("public final class InMemoryTokenStore")
        t=t[:a]+t[b:]
        t=t.replace("extension URLSession: HTTPTransport {","extension URLSession: HTTPTransport {",1)
    if name=="Session.swift":
        a=t.index("public final class NetworkMonitor"); b=t.index("public enum DemoBrain")
        t=t[:a]+"public final class NetworkMonitor: Sendable {\n    public init(onChange: @escaping @Sendable (Bool) -> Void) {}\n}\n\n"+t[b:]
    if name=="Tarball.swift":
        t=t.replace("try (deflated as NSData).decompressed(using: .zlib) as Data","try LinuxZlib.inflate(deflated)")
        t=t.replace("try (data as NSData).compressed(using: .zlib) as Data","try LinuxZlib.deflate(data)")
    if name=="GitHubHTTPClient.swift":
        t=t.replace("        config.waitsForConnectivity = false\n","")
    if name=="MarkdownEdits.swift":
        t=t.replace("[.byWords, .substringNotRequired]","[.byComposedCharacterSequences, .substringNotRequired]")  # LINUX: no word enumeration
    if name=="NoteText.swift":
        a=t.index("        let escaped = text.replacingOccurrences(of: \"<\""); b=t.index("        return out\n    }\n}",a)
        t=t[:a]+"        return AttributedString(text)  // LINUX: no Markdown parser\n    }\n}"+t[b+len("        return out\n    }\n}"):]
    if name=="SyncEngine.swift":
        t=t.replace("            Task { await self?.tick() }","            Task { [weak self] in await self?.tick() }  // LINUX: older region checker")
    return t
base=REPO+"/Packages/BrainNotesKit"
for f in sorted(os.listdir(base+"/Sources/BrainNotesKit")):
    open(src+"/"+f,"w").write(patch(f,open(base+"/Sources/BrainNotesKit/"+f).read()))
shutil.copy(HERE+"/Shims.swift",src+"/LinuxShims.swift")
for f in sorted(os.listdir(base+"/Tests/BrainNotesKitTests")):
    if f in skip_tests: continue
    t=open(base+"/Tests/BrainNotesKitTests/"+f).read()
    open(tst+"/"+f,"w").write(patch(f,t))
# Package: BrainMerge from the repo root (bind-mounted at /work), GRDB from the pinned local clone.
open(OUT+"/Package.swift","w").write('''// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "BrainNotesKit",
    products: [.library(name: "BrainNotesKit", targets: ["BrainNotesKit"])],
    dependencies: [.package(path: "/work"), .package(path: "/deps/GRDB.swift")],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "BrainNotesKit", dependencies: ["CZlib", .product(name: "BrainMerge", package: "work"), .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "BrainNotesKitTests", dependencies: ["BrainNotesKit", .product(name: "BrainMerge", package: "work")]),
    ]
)
''')
print("ok")
