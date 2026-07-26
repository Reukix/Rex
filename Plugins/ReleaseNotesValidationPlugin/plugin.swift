import PackagePlugin

@main
struct ReleaseNotesValidationPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let validator = try context.tool(named: "RexReleaseValidator")
        let stamp = context.pluginWorkDirectoryURL.appendingPathComponent("release-notes-validation.txt")
        return [
            .buildCommand(
                displayName: "Validate Rex release notes",
                executable: validator.url,
                arguments: [context.package.directoryURL.path, context.pluginWorkDirectoryURL.path],
                inputFiles: [
                    context.package.directoryURL.appendingPathComponent("Sources/RexApp/Application/AppVersion.swift"),
                    context.package.directoryURL.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/features.json"),
                    context.package.directoryURL.appendingPathComponent("Sources/RexApp/Resources/ReleaseNotes/releases.json"),
                    context.package.directoryURL.appendingPathComponent("CHANGELOG.md"),
                    context.package.directoryURL.appendingPathComponent("FEATURES.md"),
                    context.package.directoryURL.appendingPathComponent("ROADMAP.md")
                ],
                outputFiles: [stamp]
            )
        ]
    }
}
