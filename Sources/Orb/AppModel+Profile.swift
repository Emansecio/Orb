import Foundation

// The user's profile photo (the text is `profile`, edited in place in Ajustes → Geral → Você).

extension AppModel {
    /// Where the photo is, when there is one (for `Thumbnails`).
    var profilePhotoPath: String? {
        profile.photo.isEmpty ? nil : ProfilePhoto(dataFolder: store.directory).url(for: profile.photo).path
    }

    /// Crops the picture at `url` to a square, shrinks it and keeps it as the user's photo, replacing the one before.
    /// Returns what to tell the user when that was not possible (a file that is not a picture, too large).
    func setProfilePhoto(fileAt url: URL) async -> String? {
        guard !isResetting else { return nil }
        profilePhotoGeneration += 1
        let generation = profilePhotoGeneration
        let photos = ProfilePhoto(dataFolder: store.directory)
        // Files from the importer or a drop may need access that lasts only while they are read.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let fileName = try await Task.detached { try photos.add(fileAt: url) }.value
            // The last thing the user did wins: after a reset, a newer choice or a removal this photo is thrown away.
            guard !isResetting, generation == profilePhotoGeneration else { photos.remove(fileName); return nil }
            let old = profile.photo
            profile.photo = fileName
            photos.remove(old)
            return nil
        } catch {
            return generation == profilePhotoGeneration ? error.localizedDescription : nil
        }
    }

    func removeProfilePhoto() {
        profilePhotoGeneration += 1 // a photo still being prepared must not come back
        ProfilePhoto(dataFolder: store.directory).remove(profile.photo)
        profile.photo = ""
    }
}
