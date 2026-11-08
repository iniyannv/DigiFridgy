import Foundation
import Observation

/// Recipes the user hearted, kept on this device (UserDefaults) so they work offline.
@Observable
final class SavedRecipeStore {
    static let shared = SavedRecipeStore()

    private static let defaultsKey = "savedRecipes.v1"
    private let defaults: UserDefaults

    /// Most recently saved first.
    private(set) var recipes: [Recipe] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Recipe].self, from: data) {
            recipes = saved
        }
    }

    func isSaved(_ recipe: Recipe) -> Bool { recipes.contains { $0.id == recipe.id } }

    /// Saves or un-saves; returns whether the recipe is now saved.
    @discardableResult
    func toggle(_ recipe: Recipe) -> Bool {
        if let index = recipes.firstIndex(where: { $0.id == recipe.id }) {
            recipes.remove(at: index)
            persist()
            return false
        }
        recipes.insert(recipe, at: 0)
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(recipes) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
