#if os(macOS)
import SwiftUI

struct ModelsSettingsPane: View {
    @ObservedObject var model: AppModel
    @State private var providerEditorMode: ProviderEditorMode?

    init(model: AppModel, initialSection: ModelProviderSection? = nil) {
        self.model = model
        let previewMode = model.isPreviewMode ? initialSection.map(ProviderEditorMode.preview) : nil
        _providerEditorMode = State(initialValue: previewMode)
    }

    var body: some View {
        ModelProviderListView(
            providers: model.configuration.providers,
            defaultProviderID: model.configuration.selectedProviderID,
            onEdit: { provider in providerEditorMode = .edit(provider.id) },
            onAdd: { providerEditorMode = .add }
        )
        .sheet(item: $providerEditorMode) { mode in
            ProviderEditorSheet(model: model, mode: mode)
        }
    }
}
#endif
