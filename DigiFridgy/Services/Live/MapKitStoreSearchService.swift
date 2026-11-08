import Foundation
import MapKit

/// Real store locations for chains without public price APIs, via MKLocalSearch.
final class MapKitStoreSearchService: StoreSearchService {
    func stores(near: Coordinate, radiusMiles: Double, chains: [OtherChain]) async -> [Store] {
        await withTaskGroup(of: [Store].self) { group in
            for chain in chains {
                group.addTask { await self.search(chain: chain, near: near, radiusMiles: radiusMiles) }
            }
            var all: [Store] = []
            for await stores in group { all += stores }
            return all.sorted { $0.distanceMiles < $1.distanceMiles }
        }
    }

    private func search(chain: OtherChain, near: Coordinate, radiusMiles: Double) async -> [Store] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = chain.rawValue
        request.resultTypes = .pointOfInterest
        let meters = radiusMiles * 1609.344
        request.region = MKCoordinateRegion(center: near.clCoordinate, latitudinalMeters: meters * 2, longitudinalMeters: meters * 2)
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let needle = chain.rawValue.lowercased().replacingOccurrences(of: "-", with: "")
        return response.mapItems.compactMap { item -> Store? in
            let name = item.name ?? chain.rawValue
            guard name.lowercased().replacingOccurrences(of: "-", with: "").contains(needle) else { return nil }
            let loc = item.location
            let coord = Coordinate(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude)
            let distance = near.distanceMiles(to: coord)
            guard distance <= radiusMiles else { return nil }
            let address = item.address?.shortAddress ?? item.address?.fullAddress ?? ""
            return Store(id: "\(chain.rawValue)-\(coord.latitude),\(coord.longitude)", chain: chain.rawValue,
                         name: name, address: address, coordinate: coord, distanceMiles: distance, isKroger: false)
        }
        .sorted { $0.distanceMiles < $1.distanceMiles }
        .prefix(3)
        .map { $0 }
    }
}

/// One-shot location using Core Location's async updates.
final class CoreLocationService: LocationService {
    private var session: CLServiceSession?

    func currentCoordinate() async -> Coordinate? {
        session = CLServiceSession(authorization: .whenInUse)
        defer { session = nil }
        do {
            let updates = CLLocationUpdate.liveUpdates()
            let deadline = Date.now.addingTimeInterval(10)
            for try await update in updates {
                if let location = update.location {
                    return Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
                }
                if update.authorizationDenied || update.authorizationDeniedGlobally || Date.now > deadline {
                    return nil
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}
