import Foundation

/// Speaker clustering using cosine similarity of speaker embeddings.
/// Supports both online (streaming) and batch (agglomerative) clustering.
final class SpeakerClusterer: @unchecked Sendable {
    /// Cosine similarity threshold for assigning to an existing speaker.
    /// Lower = more sensitive to speaker differences.
    private let similarityThreshold: Float
    /// Maximum number of distinct speakers to track.
    private let maxSpeakers: Int
    /// Maximum samples contributing to a centroid before it freezes.
    /// Prevents centroid from drifting to "generic speech" over many segments.
    private let maxCentroidSamples: Int

    private let lock = NSLock()
    private var _centroids: [[Float]] = []
    private var _counts: [Int] = []

    init(similarityThreshold: Float = 0.65, maxSpeakers: Int = 6, maxCentroidSamples: Int = 30) {
        self.similarityThreshold = similarityThreshold
        self.maxSpeakers = maxSpeakers
        self.maxCentroidSamples = maxCentroidSamples
    }

    // MARK: - Online Clustering (streaming)

    /// Assign a speaker label for the given embedding.
    /// Returns (label, confidence) where confidence is the cosine similarity to the matched centroid.
    func assignSpeaker(embedding: [Float]) -> (label: String, confidence: Double) {
        lock.lock()
        defer { lock.unlock() }

        // First segment → create first speaker
        if _centroids.isEmpty {
            _centroids.append(embedding)
            _counts.append(1)
            return ("Speaker 1", 1.0)
        }

        // Find most similar existing centroid
        var bestIndex = 0
        var bestSimilarity: Float = -1
        for (i, centroid) in _centroids.enumerated() {
            let sim = Self.cosineSimilarity(embedding, centroid)
            if sim > bestSimilarity {
                bestSimilarity = sim
                bestIndex = i
            }
        }

        if bestSimilarity >= similarityThreshold {
            // Match: update centroid (capped to prevent drift)
            updateCentroid(at: bestIndex, with: embedding)
            return ("Speaker \(bestIndex + 1)", Double(bestSimilarity))
        } else if _centroids.count < maxSpeakers {
            // New speaker
            let newIndex = _centroids.count
            _centroids.append(embedding)
            _counts.append(1)
            return ("Speaker \(newIndex + 1)", 1.0)
        } else {
            // At max speakers, assign to closest
            updateCentroid(at: bestIndex, with: embedding)
            return ("Speaker \(bestIndex + 1)", Double(bestSimilarity))
        }
    }

    /// Reset all speaker clusters.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        _centroids = []
        _counts = []
    }

    /// Number of currently tracked speakers.
    var speakerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _centroids.count
    }

    // MARK: - Batch Agglomerative Clustering

    /// Cluster all embeddings at once using agglomerative clustering with average linkage.
    ///
    /// Algorithm:
    /// 1. Start: each embedding is its own cluster
    /// 2. Compute pairwise cosine distance matrix
    /// 3. Merge the two closest clusters (average linkage)
    /// 4. Stop when: distance > threshold, OR elbow detected (distance jump >2x), OR cluster count = 1
    /// 5. Return cluster assignments (0-indexed)
    ///
    /// - Parameters:
    ///   - embeddings: Array of speaker embeddings
    ///   - maxSpeakers: Maximum clusters to allow (default 6)
    ///   - distanceThreshold: Cosine distance threshold for merging (default 0.35)
    /// - Returns: Array of cluster labels (0-indexed), same length as embeddings
    static func clusterBatch(
        embeddings: [[Float]],
        maxSpeakers: Int = 6,
        distanceThreshold: Float = 0.35
    ) -> [Int] {
        let n = embeddings.count
        guard n > 0 else { return [] }
        if n == 1 { return [0] }

        // Initialize: each embedding is its own cluster
        var clusterAssignment = Array(0..<n)
        var activeClusters = Set(0..<n)

        // Precompute pairwise cosine distance matrix (upper triangle)
        // distance = 1 - cosineSimilarity
        var distMatrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let sim = cosineSimilarity(embeddings[i], embeddings[j])
                let dist = 1.0 - sim
                distMatrix[i][j] = dist
                distMatrix[j][i] = dist
            }
        }

        // Track which cluster each item belongs to (cluster ID → member indices)
        var clusterMembers: [Int: [Int]] = [:]
        for i in 0..<n {
            clusterMembers[i] = [i]
        }

        // Track merge distances for elbow detection
        var previousMergeDist: Float = 0

        // Agglomerative merging
        while activeClusters.count > 1 {
            // Find the two closest clusters (average linkage)
            var bestDist: Float = Float.greatestFiniteMagnitude
            var bestI = -1
            var bestJ = -1

            let sorted = activeClusters.sorted()
            for ai in 0..<sorted.count {
                for aj in (ai + 1)..<sorted.count {
                    let ci = sorted[ai]
                    let cj = sorted[aj]
                    let dist = averageLinkageDistance(
                        clusterA: clusterMembers[ci]!,
                        clusterB: clusterMembers[cj]!,
                        distMatrix: distMatrix
                    )
                    if dist < bestDist {
                        bestDist = dist
                        bestI = ci
                        bestJ = cj
                    }
                }
            }

            // Stop if closest clusters are too far apart
            if bestDist > distanceThreshold {
                break
            }

            // Elbow detection: stop when merge distance jumps >2x from previous
            // (indicates a natural cluster boundary)
            if previousMergeDist > 0.01 && bestDist > previousMergeDist * 2.0 && activeClusters.count <= maxSpeakers {
                break
            }

            previousMergeDist = bestDist

            // Merge cluster bestJ into bestI
            let membersJ = clusterMembers[bestJ]!
            clusterMembers[bestI]!.append(contentsOf: membersJ)
            clusterMembers.removeValue(forKey: bestJ)
            activeClusters.remove(bestJ)

            // Update assignments
            for idx in membersJ {
                clusterAssignment[idx] = bestI
            }
        }

        // Renumber clusters to 0, 1, 2, ...
        let uniqueClusters = Array(Set(clusterAssignment)).sorted()
        let remap = Dictionary(uniqueValues: uniqueClusters.enumerated().map { ($1, $0) })
        return clusterAssignment.map { remap[$0]! }
    }

    // MARK: - K-Means Cosine Clustering

    /// Cluster embeddings into `k` groups using K-means with cosine similarity.
    /// Uses K-means++ initialization and L2-normalized centroids.
    static func kMeansCosine(embeddings: [[Float]], k: Int, maxIterations: Int = 20) -> [Int] {
        let n = embeddings.count
        guard n > 0, k > 0 else { return [] }
        if k >= n { return Array(0..<n) }
        if k == 1 { return [Int](repeating: 0, count: n) }

        // K-means++ initialization
        var centroids = [l2Normalize(embeddings[0])]

        for _ in 1..<k {
            var distances = [Float](repeating: Float.greatestFiniteMagnitude, count: n)
            for i in 0..<n {
                for centroid in centroids {
                    let dist = 1.0 - cosineSimilarity(embeddings[i], centroid)
                    distances[i] = min(distances[i], dist)
                }
            }
            let totalDist = distances.reduce(Float(0), +)
            if totalDist <= 0 {
                centroids.append(l2Normalize(embeddings[centroids.count]))
                continue
            }
            var threshold = Float.random(in: 0..<totalDist)
            var chosen = 0
            for i in 0..<n {
                threshold -= distances[i]
                if threshold <= 0 {
                    chosen = i
                    break
                }
            }
            centroids.append(l2Normalize(embeddings[chosen]))
        }

        // Iterative assignment + update
        var assignments = [Int](repeating: 0, count: n)
        for _ in 0..<maxIterations {
            var changed = false
            for i in 0..<n {
                var bestCluster = 0
                var bestSim: Float = -1
                for c in 0..<k {
                    let sim = cosineSimilarity(embeddings[i], centroids[c])
                    if sim > bestSim {
                        bestSim = sim
                        bestCluster = c
                    }
                }
                if assignments[i] != bestCluster {
                    assignments[i] = bestCluster
                    changed = true
                }
            }
            if !changed { break }

            // Update centroids: mean of members, then L2-normalize
            let dim = embeddings[0].count
            for c in 0..<k {
                var sum = [Float](repeating: 0, count: dim)
                var count = 0
                for i in 0..<n where assignments[i] == c {
                    for d in 0..<dim { sum[d] += embeddings[i][d] }
                    count += 1
                }
                if count > 0 { centroids[c] = l2Normalize(sum) }
            }
        }
        return assignments
    }

    /// L2-normalize a vector. Returns the original if norm is zero.
    static func l2Normalize(_ v: [Float]) -> [Float] {
        let norm = sqrt(v.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - Private

    private func updateCentroid(at index: Int, with embedding: [Float]) {
        // Stop updating once we have enough samples — centroid is stable
        guard _counts[index] < maxCentroidSamples else { return }

        let count = Float(_counts[index])
        let newCount = count + 1
        for i in 0..<_centroids[index].count {
            _centroids[index][i] = (_centroids[index][i] * count + embedding[i]) / newCount
        }
        _counts[index] += 1
    }

    /// Average linkage distance between two clusters.
    private static func averageLinkageDistance(
        clusterA: [Int],
        clusterB: [Int],
        distMatrix: [[Float]]
    ) -> Float {
        var totalDist: Float = 0
        var count = 0
        for a in clusterA {
            for b in clusterB {
                totalDist += distMatrix[a][b]
                count += 1
            }
        }
        return count > 0 ? totalDist / Float(count) : Float.greatestFiniteMagnitude
    }

    /// Cosine similarity between two vectors. Returns value in [-1, 1].
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return dotProduct / denominator
    }
}

// Helper to build a dictionary from a sequence of unique key-value pairs
private extension Dictionary {
    init(uniqueValues pairs: [(Key, Value)]) {
        self.init(minimumCapacity: pairs.count)
        for (k, v) in pairs {
            self[k] = v
        }
    }
}
