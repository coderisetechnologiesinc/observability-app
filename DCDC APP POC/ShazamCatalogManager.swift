import ShazamKit

class ShazamCatalogManager {
    private var catalog = SHCustomCatalog()
    
    func loadCatalog() async throws {
        guard let signatureURL = Bundle.main.url(
            forResource: "test_signature", // Your filename without extension
            withExtension: "shazamsignature"
        ) else {
            throw NSError(domain: "FileNotFound", code: 404)
        }
        
        do {
            // ✅ Critical fix: Load signature data first
            let signatureData = try Data(contentsOf: signatureURL)
            let signature = try SHSignature(dataRepresentation: signatureData)
            
            // Create a media item (metadata)
            let mediaItem = SHMediaItem(properties: [
                SHMediaItemProperty.title: "Your Audio Title",
                SHMediaItemProperty.artist: "Artist Name"
            ])
            
            // Add to catalog
            try catalog.addReferenceSignature(signature, representing: [mediaItem])
            print("✅ Catalog loaded with 1 signature")
            
        } catch {
            print("❌ Failed to load catalog: \(error.localizedDescription)")
            throw error
        }
    }
    
    func getCatalog() -> SHCustomCatalog {
        return catalog
    }
}
