import Foundation

/// The commit this build was made from, stamped by `Tools/stamp-build.sh` into
/// `Sources/Resources/BuildInfo.json` through a preBuildScript. This is what makes it
/// possible to tell which build is on the headset instead of guessing.
struct BuildInfo: Decodable {
    let commit: String
    let dirty: Bool
    let builtAt: String

    /// Read once and cached — the file cannot change for the life of a running process.
    /// `nil` only on a fresh checkout where `Tools/stamp-build.sh` has never run yet;
    /// see the bootstrapping note at the top of that script.
    static let current: BuildInfo? = {
        guard let url = Bundle.main.url(forResource: "BuildInfo", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(BuildInfo.self, from: data)
    }()

    /// The short commit, with a trailing `*` when the working tree had uncommitted
    /// changes at build time — the same convention `git describe --dirty` uses.
    var revision: String { dirty ? "\(commit)*" : commit }
}
