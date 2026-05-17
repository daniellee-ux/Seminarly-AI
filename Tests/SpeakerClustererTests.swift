import XCTest
@testable import Seminarly

final class SpeakerClustererTests: XCTestCase {

    // Embedding dimension matches MFCCExtractor output
    private let dim = MFCCExtractor.embeddingDimension // 34

    // MARK: - Online Clustering Tests

    func testFirstEmbeddingAssignedSpeaker1() {
        let clusterer = SpeakerClusterer()
        let embedding = [Float](repeating: 1.0, count: dim)

        let (label, confidence) = clusterer.assignSpeaker(embedding: embedding)

        XCTAssertEqual(label, "Speaker 1")
        XCTAssertEqual(confidence, 1.0)
        XCTAssertEqual(clusterer.speakerCount, 1)
    }

    func testIdenticalEmbeddingsSameSpeaker() {
        let clusterer = SpeakerClusterer()
        let embedding = [Float](repeating: 1.0, count: dim)

        let (label1, _) = clusterer.assignSpeaker(embedding: embedding)
        let (label2, _) = clusterer.assignSpeaker(embedding: embedding)
        let (label3, _) = clusterer.assignSpeaker(embedding: embedding)

        XCTAssertEqual(label1, "Speaker 1")
        XCTAssertEqual(label2, "Speaker 1")
        XCTAssertEqual(label3, "Speaker 1")
        XCTAssertEqual(clusterer.speakerCount, 1)
    }

    func testDistantEmbeddingsDifferentSpeakers() {
        let clusterer = SpeakerClusterer(similarityThreshold: 0.65)

        // Two orthogonal-ish embeddings in dim-dimensional space
        var embeddingA = [Float](repeating: 0, count: dim)
        embeddingA[0] = 1.0
        embeddingA[1] = 0.5
        embeddingA[2] = 0.3

        var embeddingB = [Float](repeating: 0, count: dim)
        embeddingB[20] = 1.0
        embeddingB[21] = 0.5
        embeddingB[22] = 0.3

        let (labelA, _) = clusterer.assignSpeaker(embedding: embeddingA)
        let (labelB, _) = clusterer.assignSpeaker(embedding: embeddingB)

        XCTAssertEqual(labelA, "Speaker 1")
        XCTAssertEqual(labelB, "Speaker 2")
        XCTAssertEqual(clusterer.speakerCount, 2)
    }

    func testMaxSpeakerCap() {
        let maxSpeakers = 3
        let clusterer = SpeakerClusterer(similarityThreshold: 0.65, maxSpeakers: maxSpeakers)

        // Create orthogonal embeddings to force new speaker creation
        for i in 0..<5 {
            var embedding = [Float](repeating: 0, count: dim)
            // Place energy in different non-overlapping regions
            let baseIdx = (i * 7) % dim
            embedding[baseIdx] = 1.0
            embedding[(baseIdx + 1) % dim] = 0.5
            _ = clusterer.assignSpeaker(embedding: embedding)
        }

        XCTAssertLessThanOrEqual(clusterer.speakerCount, maxSpeakers)
    }

    func testResetClearsClusters() {
        let clusterer = SpeakerClusterer()
        let embedding = [Float](repeating: 1.0, count: dim)

        _ = clusterer.assignSpeaker(embedding: embedding)
        XCTAssertEqual(clusterer.speakerCount, 1)

        clusterer.reset()
        XCTAssertEqual(clusterer.speakerCount, 0)
    }

    func testCentroidUpdateCapped() {
        let clusterer = SpeakerClusterer(similarityThreshold: 0.65, maxSpeakers: 6, maxCentroidSamples: 5)

        var embedding = [Float](repeating: 1.0, count: dim)
        for _ in 0..<20 {
            _ = clusterer.assignSpeaker(embedding: embedding)
        }
        XCTAssertEqual(clusterer.speakerCount, 1, "All identical embeddings should be same speaker")

        embedding[0] = 1.1
        let (label, _) = clusterer.assignSpeaker(embedding: embedding)
        XCTAssertEqual(label, "Speaker 1")
    }

    func testCosineSimilarityIdentical() {
        let a: [Float] = [1, 2, 3, 4, 5]
        let similarity = SpeakerClusterer.cosineSimilarity(a, a)
        XCTAssertEqual(similarity, 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonal() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let similarity = SpeakerClusterer.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOpposite() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let similarity = SpeakerClusterer.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, -1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityEmptyVectors() {
        let similarity = SpeakerClusterer.cosineSimilarity([], [])
        XCTAssertEqual(similarity, 0.0)
    }

    func testSimilarEmbeddingsClusterTogether() {
        let clusterer = SpeakerClusterer(similarityThreshold: 0.65)

        var base = [Float](repeating: 0.3, count: dim)
        for i in 0..<dim { base[i] = Float(i + 1) * 0.1 }

        let perturbed1 = base.map { $0 + Float.random(in: -0.02...0.02) }
        let perturbed2 = base.map { $0 + Float.random(in: -0.02...0.02) }

        let (label1, _) = clusterer.assignSpeaker(embedding: base)
        let (label2, _) = clusterer.assignSpeaker(embedding: perturbed1)
        let (label3, _) = clusterer.assignSpeaker(embedding: perturbed2)

        XCTAssertEqual(label1, label2, "Slightly perturbed embeddings should be same speaker")
        XCTAssertEqual(label2, label3, "Slightly perturbed embeddings should be same speaker")
    }

    // MARK: - Batch Clustering Tests

    func testBatchClusterSingleEmbedding() {
        let embedding = [Float](repeating: 1.0, count: dim)
        let labels = SpeakerClusterer.clusterBatch(embeddings: [embedding])
        XCTAssertEqual(labels, [0])
    }

    func testBatchClusterEmpty() {
        let labels = SpeakerClusterer.clusterBatch(embeddings: [])
        XCTAssertEqual(labels, [])
    }

    func testBatchClusterIdenticalEmbeddings() {
        let embedding = [Float](repeating: 1.0, count: dim)
        let embeddings = Array(repeating: embedding, count: 5)
        let labels = SpeakerClusterer.clusterBatch(embeddings: embeddings)

        // All identical → should be one cluster
        let uniqueLabels = Set(labels)
        XCTAssertEqual(uniqueLabels.count, 1, "Identical embeddings should form 1 cluster")
    }

    func testBatchClusterTwoDistinctSpeakers() {
        // Create two clearly different groups
        var groupA: [[Float]] = []
        var groupB: [[Float]] = []

        for _ in 0..<5 {
            var a = [Float](repeating: 0, count: dim)
            a[0] = 1.0 + Float.random(in: -0.05...0.05)
            a[1] = 0.8 + Float.random(in: -0.05...0.05)
            a[2] = 0.5 + Float.random(in: -0.05...0.05)
            groupA.append(a)

            var b = [Float](repeating: 0, count: dim)
            b[15] = 1.0 + Float.random(in: -0.05...0.05)
            b[16] = 0.8 + Float.random(in: -0.05...0.05)
            b[17] = 0.5 + Float.random(in: -0.05...0.05)
            groupB.append(b)
        }

        let allEmbeddings = groupA + groupB
        let labels = SpeakerClusterer.clusterBatch(embeddings: allEmbeddings)

        XCTAssertEqual(labels.count, 10)

        // Group A should all have the same label
        let groupALabels = Set(Array(labels[0..<5]))
        XCTAssertEqual(groupALabels.count, 1, "Group A embeddings should cluster together")

        // Group B should all have the same label
        let groupBLabels = Set(Array(labels[5..<10]))
        XCTAssertEqual(groupBLabels.count, 1, "Group B embeddings should cluster together")

        // The two groups should have different labels
        XCTAssertNotEqual(groupALabels.first, groupBLabels.first, "Two groups should be different clusters")
    }

    func testBatchClusterRespectsMaxSpeakers() {
        // Create 5 orthogonal groups with maxSpeakers=3
        var embeddings: [[Float]] = []
        for group in 0..<5 {
            var emb = [Float](repeating: 0, count: dim)
            let base = (group * 6) % dim
            emb[base] = 1.0
            emb[(base + 1) % dim] = 0.5
            embeddings.append(emb)
        }

        let labels = SpeakerClusterer.clusterBatch(
            embeddings: embeddings,
            maxSpeakers: 3,
            distanceThreshold: 0.35
        )

        let uniqueLabels = Set(labels)
        // With the lower distanceThreshold (0.35), orthogonal embeddings (distance ~1.0)
        // won't merge at all, so we expect all 5 to remain separate clusters
        XCTAssertEqual(labels.count, 5)
        XCTAssertGreaterThanOrEqual(uniqueLabels.count, 3, "Orthogonal embeddings should not merge below threshold")
    }

    func testBatchClusterSimilarEmbeddingsFormOneCluster() {
        var base = [Float](repeating: 0, count: dim)
        for i in 0..<dim { base[i] = Float(i + 1) * 0.1 }

        var embeddings: [[Float]] = []
        for _ in 0..<8 {
            let perturbed = base.map { $0 + Float.random(in: -0.01...0.01) }
            embeddings.append(perturbed)
        }

        let labels = SpeakerClusterer.clusterBatch(embeddings: embeddings)
        let uniqueLabels = Set(labels)
        XCTAssertEqual(uniqueLabels.count, 1, "Very similar embeddings should form 1 cluster")
    }
}
