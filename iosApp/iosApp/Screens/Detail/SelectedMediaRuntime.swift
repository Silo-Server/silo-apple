import Foundation

enum SelectedMediaRuntime {
    static func minutes(
        detail: ItemDetail,
        selectedVersion: FileVersion?
    ) -> Int? {
        let selectedVariant = selectedVersion.flatMap { selected in
            detail.playbackVariants?.first { variant in
                variant.parts.contains { part in
                    part.versions.contains { $0.fileId == selected.fileId }
                }
            }
        }
        let isMultipart = selectedVariant.map {
            $0.partCount > 1 || $0.parts.count > 1
        } ?? false
        let seconds = isMultipart
            ? selectedVariant?.totalDuration
            : selectedVersion?.duration

        if let seconds, seconds.isFinite, seconds > 0,
           let minutes = Int(exactly: (seconds / 60).rounded()) {
            return minutes
        }
        return detail.runtime
    }
}
