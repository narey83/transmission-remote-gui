import SwiftUI
import TransmissionKit

/// Shared daemon-side folder choices for Add and Move. Saved choices belong to the
/// selected server; mappings contribute their remote roots, never local Finder paths.
struct DownloadDirectoryPicker: View {
    @Environment(AppModel.self) private var model
    @Binding var directory: String
    var allowsDefault = true
    var focusOnAppear = false
    var accessibilityPrefix = "add.downloadDir"
    @FocusState private var directoryFocused: Bool

    private var directoryIsValid: Bool {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        return (allowsDefault && trimmed.isEmpty) || TorrentRowMenu.sanitizedLocation(trimmed) != nil
    }

    private var currentDirIsFavorite: Bool { model.downloadDirs.isFavorite(directory) }
    private var canFavoriteCurrentDir: Bool {
        TorrentRowMenu.sanitizedLocation(directory) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(loc("Célmappa a szerveren (abszolút útvonal)")).font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(model.defaultDownloadDir ?? "/mnt/data/…", text: $directory)
                    .textFieldStyle(.roundedBorder)
                    .focused($directoryFocused)
                    .accessibilityIdentifier(accessibilityPrefix)
                    .accessibilityLabel(loc("Célmappa a szerveren (abszolút útvonal)"))
                Button {
                    if currentDirIsFavorite {
                        model.removeFavoriteDownloadDir(directory)
                    } else {
                        model.addFavoriteDownloadDir(directory)
                    }
                } label: {
                    Image(systemName: currentDirIsFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .disabled(!canFavoriteCurrentDir)
                .help(currentDirIsFavorite ? loc("Eltávolítás a kedvencek közül") : loc("Hozzáadás a kedvencekhez"))
                .accessibilityLabel(
                    currentDirIsFavorite ? loc("Eltávolítás a kedvencek közül") : loc("Hozzáadás a kedvencekhez")
                )
                .accessibilityIdentifier("\(accessibilityPrefix).favorite")
                directoryMenu
            }
            let mapped = DownloadDirectories.mappedDestinations(model.selectedServer?.pathMappings ?? [])
            if !mapped.isEmpty {
                Picker(loc("Mentés ide:"), selection: $directory) {
                    if !mapped.contains(directory) {
                        Text(
                            directory.isEmpty
                                ? (allowsDefault ? loc("Alapértelmezett mappa") : loc("Válassz mappát"))
                                : directory
                        ).tag(directory)
                    }
                    ForEach(mapped, id: \.self) { dir in
                        Text(dir).tag(dir)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("\(accessibilityPrefix).mappings")
            }
            if directoryIsValid && allowsDefault {
                Text(loc("Csak ennél a torrentnél — a szerver alapértelmezett mappája nem változik."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !directoryIsValid && !directory.isEmpty {
                Text(
                    allowsDefault
                        ? loc("Abszolút útvonalat adj meg, vagy hagyd üresen az alapértelmezett mappához.")
                        : loc("Abszolút útvonalat adj meg.")
                )
                .font(.caption).foregroundStyle(.red)
                .accessibilityIdentifier("\(accessibilityPrefix).error")
            }
        }
        .onAppear { if focusOnAppear { directoryFocused = true } }
    }

    private var directoryMenu: some View {
        let dirs = model.downloadDirs
        return Menu {
            if let defaultDir = model.defaultDownloadDir {
                Button(loc("Alapértelmezett mappa") + ": " + defaultDir) { directory = defaultDir }
                    .accessibilityIdentifier("\(accessibilityPrefix).default")
            }
            if !dirs.favorites.isEmpty {
                Section(loc("Kedvencek")) {
                    ForEach(dirs.favorites, id: \.self) { dir in
                        Button(dir) { directory = dir }
                    }
                }
            }
            if !dirs.recent.isEmpty {
                Section(loc("Legutóbb használt")) {
                    ForEach(dirs.recent, id: \.self) { dir in
                        Button(dir) { directory = dir }
                    }
                }
            }
            Divider()
            if currentDirIsFavorite {
                Button(loc("Eltávolítás a kedvencek közül")) { model.removeFavoriteDownloadDir(directory) }
            } else {
                Button(loc("Hozzáadás a kedvencekhez")) { model.addFavoriteDownloadDir(directory) }
                    .disabled(!canFavoriteCurrentDir)
            }
            if !dirs.favorites.isEmpty {
                Menu(loc("Kedvenc eltávolítása")) {
                    ForEach(dirs.favorites, id: \.self) { dir in
                        Button(dir) { model.removeFavoriteDownloadDir(dir) }
                    }
                }
            }
            Button(loc("Előzmények törlése")) { model.clearRecentDownloadDirs() }
                .disabled(dirs.recent.isEmpty)
        } label: {
            Image(systemName: "folder.badge.gearshape")
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help(loc("Kedvenc és legutóbbi mappák"))
        .accessibilityLabel(loc("Kedvenc és legutóbbi mappák"))
        .accessibilityIdentifier("\(accessibilityPrefix).menu")
    }
}
