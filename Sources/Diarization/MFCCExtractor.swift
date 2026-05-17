import Accelerate
import Foundation

/// Extracts speaker embeddings from audio using MFCCs, pitch (F0), and spectral features
/// via the Accelerate framework.
///
/// The 34-dimensional embedding captures:
/// - **MFCC stddevs** (13): voice variability across the window
/// - **Delta MFCC means** (13): temporal dynamics — pitch contour, transitions
/// - **Pitch features** (4): median F0, F0 stddev, F0 range, voiced frame ratio
/// - **Spectral centroid** (2): mean + stddev — bright vs dark voice
/// - **Spectral spread** (2): mean + stddev — vocal resonance width
///
/// MFCC means are dropped (CMS zeros them by construction).
/// Pitch is the primary speaker discriminator for same-gender speakers.
struct MFCCExtractor: Sendable {
    /// Number of MFCC coefficients per frame.
    static let mfccCount = 13
    /// Total embedding dimensions: mfcc stddev(13) + delta mean(13) + pitch(4) + spectral(4).
    static let embeddingDimension = 34
    /// Number of mel filterbank bands.
    static let melFilterCount = 26
    /// Frame duration in seconds (25ms).
    static let frameDuration: Double = 0.025
    /// Hop duration in seconds (10ms).
    static let hopDuration: Double = 0.010
    /// Pre-emphasis coefficient.
    static let preEmphasis: Float = 0.97

    // Pitch detection constants
    /// Minimum detectable F0 (Hz) — low male voice.
    static let minF0: Float = 60
    /// Maximum detectable F0 (Hz) — high female/child voice.
    static let maxF0: Float = 500
    /// CMNDF threshold for pitch detection (lower = stricter).
    static let pitchThreshold: Float = 0.15

    /// Pitch subsampling stride: process every Nth frame for pitch detection.
    static let pitchStride = 4

    // MARK: - Cached Resources

    /// Thread-safe cache for FFT setup, Hann window, and mel filterbank.
    /// These are expensive to create and identical for a given frameLength,
    /// so we create them once and reuse across all windows.
    final class CachedResources: @unchecked Sendable {
        private let lock = NSLock()
        private var _fftSetup: FFTSetup?
        private var _hannWindow: [Float]?
        private var _filterbank: [[Float]]?
        private var _frameLength: Int = 0
        private var _fftSize: Int = 0
        private var _sampleRate: Double = 0

        static let shared = CachedResources()

        func get(frameLength: Int, sampleRate: Double) -> (fftSetup: FFTSetup, hannWindow: [Float], filterbank: [[Float]], fftSize: Int)? {
            lock.lock()
            defer { lock.unlock() }

            let fftSize = nextPowerOf2(frameLength)

            if frameLength == _frameLength && sampleRate == _sampleRate,
               let fftSetup = _fftSetup, let hannWindow = _hannWindow, let filterbank = _filterbank {
                return (fftSetup, hannWindow, filterbank, fftSize)
            }

            // Recreate for new parameters
            if let old = _fftSetup {
                vDSP_destroy_fftsetup(old)
            }

            guard let fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2)) else {
                return nil
            }

            var hannWindow = [Float](repeating: 0, count: frameLength)
            vDSP_hann_window(&hannWindow, vDSP_Length(frameLength), Int32(vDSP_HANN_NORM))

            let filterbank = makeMelFilterbank(
                numFilters: melFilterCount,
                fftSize: fftSize,
                sampleRate: sampleRate
            )

            _fftSetup = fftSetup
            _hannWindow = hannWindow
            _filterbank = filterbank
            _frameLength = frameLength
            _fftSize = fftSize
            _sampleRate = sampleRate

            return (fftSetup, hannWindow, filterbank, fftSize)
        }

        private func nextPowerOf2(_ n: Int) -> Int {
            var v = n - 1
            v |= v >> 1
            v |= v >> 2
            v |= v >> 4
            v |= v >> 8
            v |= v >> 16
            return v + 1
        }

        deinit {
            if let fft = _fftSetup {
                vDSP_destroy_fftsetup(fft)
            }
        }
    }

    /// Extract a 34-dimensional speaker embedding from audio samples.
    ///
    /// - Parameters:
    ///   - samples: Audio samples (mono, Float)
    ///   - sampleRate: Sample rate in Hz (default 16000)
    /// - Returns: 34-element embedding vector, or nil if input is too short
    static func extract(from samples: [Float], sampleRate: Double = 16000) -> [Float]? {
        return samples.withUnsafeBufferPointer { buffer in
            extract(from: buffer, range: 0..<samples.count, sampleRate: sampleRate)
        }
    }

    /// Extract a 34-dimensional speaker embedding from a range within a sample buffer.
    /// Avoids copying by indexing directly into the original array.
    static func extract(from buffer: UnsafeBufferPointer<Float>, range: Range<Int>, sampleRate: Double = 16000) -> [Float]? {
        let frameLength = Int(frameDuration * sampleRate)
        let hopLength = Int(hopDuration * sampleRate)
        let sampleCount = range.count

        guard sampleCount >= frameLength else { return nil }

        guard let cached = CachedResources.shared.get(frameLength: frameLength, sampleRate: sampleRate) else {
            return nil
        }
        let fftSetup = cached.fftSetup
        let hannWindow = cached.hannWindow
        let filterbank = cached.filterbank
        let fftSize = cached.fftSize
        let halfFFT = fftSize / 2

        // Step 1: Pre-emphasis — boost high frequencies
        var emphasized = [Float](repeating: 0, count: sampleCount)
        emphasized[0] = buffer[range.lowerBound]
        for i in 1..<sampleCount {
            emphasized[i] = buffer[range.lowerBound + i] - preEmphasis * buffer[range.lowerBound + i - 1]
        }

        // Step 2: Extract per-frame MFCCs and power spectra
        let numFrames = max(1, (sampleCount - frameLength) / hopLength + 1)
        var allMFCCs = [[Float]](repeating: [Float](repeating: 0, count: mfccCount), count: numFrames)
        var allPowerSpectra = [[Float]](repeating: [Float](repeating: 0, count: halfFFT + 1), count: numFrames)

        for frameIndex in 0..<numFrames {
            let start = frameIndex * hopLength
            let end = min(start + frameLength, sampleCount)
            let actualLength = end - start

            var frame = [Float](repeating: 0, count: fftSize)
            for i in 0..<actualLength {
                frame[i] = emphasized[start + i] * hannWindow[i]
            }

            let powerSpectrum = computePowerSpectrum(
                frame: &frame,
                fftSize: fftSize,
                fftSetup: fftSetup
            )
            allPowerSpectra[frameIndex] = powerSpectrum

            var melEnergies = [Float](repeating: 0, count: melFilterCount)
            for f in 0..<melFilterCount {
                var sum: Float = 0
                vDSP_dotpr(powerSpectrum, 1, filterbank[f], 1, &sum, vDSP_Length(halfFFT + 1))
                melEnergies[f] = max(sum, 1e-10)
            }

            var logMelCount = Int32(melFilterCount)
            vvlogf(&melEnergies, melEnergies, &logMelCount)

            let mfccs = dctTypeII(input: melEnergies, outputCount: mfccCount)
            allMFCCs[frameIndex] = mfccs
        }

        // Step 3: Cepstral Mean Subtraction (CMS)
        var cmsMean = [Float](repeating: 0, count: mfccCount)
        for frameMFCCs in allMFCCs {
            for i in 0..<mfccCount {
                cmsMean[i] += frameMFCCs[i]
            }
        }
        let frameScale = 1.0 / Float(numFrames)
        for i in 0..<mfccCount {
            cmsMean[i] *= frameScale
        }
        for f in 0..<numFrames {
            for i in 0..<mfccCount {
                allMFCCs[f][i] -= cmsMean[i]
            }
        }

        // Step 4: Compute delta MFCCs
        var allDeltas = [[Float]](repeating: [Float](repeating: 0, count: mfccCount), count: numFrames)
        for t in 0..<numFrames {
            let prev = t > 0 ? t - 1 : 0
            let next = t < numFrames - 1 ? t + 1 : numFrames - 1
            for i in 0..<mfccCount {
                allDeltas[t][i] = (allMFCCs[next][i] - allMFCCs[prev][i]) / 2.0
            }
        }

        // Step 5: Extract pitch (F0) per frame via autocorrelation (subsampled)
        let pitchFeatures = extractPitchFeatures(
            from: buffer,
            range: range,
            sampleRate: sampleRate,
            frameLength: frameLength,
            hopLength: hopLength,
            numFrames: numFrames
        )

        // Step 6: Extract spectral centroid and spread per frame
        let spectralFeatures = extractSpectralFeatures(
            powerSpectra: allPowerSpectra,
            fftSize: fftSize,
            sampleRate: sampleRate
        )

        // Step 7: Build 34-dim embedding
        var embedding = [Float](repeating: 0, count: embeddingDimension)

        // [0-12] MFCC stddevs (13)
        var mfccMean = [Float](repeating: 0, count: mfccCount)
        for frameMFCCs in allMFCCs {
            for i in 0..<mfccCount {
                mfccMean[i] += frameMFCCs[i]
            }
        }
        for i in 0..<mfccCount {
            mfccMean[i] *= frameScale
        }

        var mfccVar = [Float](repeating: 0, count: mfccCount)
        for frameMFCCs in allMFCCs {
            for i in 0..<mfccCount {
                let diff = frameMFCCs[i] - mfccMean[i]
                mfccVar[i] += diff * diff
            }
        }
        for i in 0..<mfccCount {
            embedding[i] = sqrt(mfccVar[i] * frameScale)
        }

        // [13-25] Delta MFCC means (13)
        var deltaMean = [Float](repeating: 0, count: mfccCount)
        for frameDelta in allDeltas {
            for i in 0..<mfccCount {
                deltaMean[i] += frameDelta[i]
            }
        }
        for i in 0..<mfccCount {
            embedding[mfccCount + i] = deltaMean[i] * frameScale
        }

        // [26-29] Pitch features (4) — normalized to [0,1]
        embedding[26] = pitchFeatures.medianF0
        embedding[27] = pitchFeatures.stddevF0
        embedding[28] = pitchFeatures.rangeF0
        embedding[29] = pitchFeatures.voicedRatio

        // [30-31] Spectral centroid mean + stddev (2)
        embedding[30] = spectralFeatures.centroidMean
        embedding[31] = spectralFeatures.centroidStddev

        // [32-33] Spectral spread mean + stddev (2)
        embedding[32] = spectralFeatures.spreadMean
        embedding[33] = spectralFeatures.spreadStddev

        // Step 8: Normalize embedding dimensions to comparable scales.
        // MFCC stddevs (~1-20) dominate cosine similarity over pitch (~0-1).
        // Scale dimensions so pitch contributes ~30% of similarity.

        // MFCC stddevs [0-12]: scale by 1/10 → range ~[0, 1.5]
        for i in 0..<mfccCount {
            embedding[i] *= 0.1
        }
        // Delta MFCC means [13-25]: scale by 1/3 → range ~[-0.7, 0.7]
        for i in 0..<mfccCount {
            embedding[mfccCount + i] *= (1.0 / 3.0)
        }
        // Pitch features [26-29]: weight by 3.0 → range ~[0, 3.0] (primary discriminator)
        for i in 26...29 {
            embedding[i] *= 3.0
        }
        // Spectral features [30-33]: weight by 2.0 → range ~[0, 0.8]
        for i in 30...33 {
            embedding[i] *= 2.0
        }

        return embedding
    }

    // MARK: - Pitch Extraction

    struct PitchFeatures {
        let medianF0: Float      // Normalized median pitch
        let stddevF0: Float      // Normalized pitch variability
        let rangeF0: Float       // Normalized pitch range
        let voicedRatio: Float   // Proportion of voiced frames [0,1]
    }

    /// Extract pitch features from raw audio using autocorrelation-based detection.
    /// Subsamples frames by `pitchStride` for performance (~4x fewer pitch computations).
    static func extractPitchFeatures(
        from buffer: UnsafeBufferPointer<Float>,
        range: Range<Int>,
        sampleRate: Double,
        frameLength: Int,
        hopLength: Int,
        numFrames: Int
    ) -> PitchFeatures {
        let minLag = Int(sampleRate / Double(maxF0))  // ~32 samples at 16kHz
        let maxLag = Int(sampleRate / Double(minF0))  // ~267 samples at 16kHz

        var f0Values: [Float] = []
        var framesProcessed = 0

        var frameIndex = 0
        while frameIndex < numFrames {
            let start = range.lowerBound + frameIndex * hopLength
            let end = min(start + frameLength, range.upperBound)
            let actualLength = end - start

            guard actualLength > maxLag else {
                frameIndex += pitchStride
                continue
            }

            framesProcessed += 1

            if let f0 = detectPitchAutocorrelation(
                buffer: buffer,
                offset: start,
                length: actualLength,
                sampleRate: sampleRate,
                minLag: minLag,
                maxLag: min(maxLag, actualLength - 1)
            ) {
                f0Values.append(f0)
            }

            frameIndex += pitchStride
        }

        guard !f0Values.isEmpty else {
            return PitchFeatures(medianF0: 0, stddevF0: 0, rangeF0: 0, voicedRatio: 0)
        }

        let sorted = f0Values.sorted()
        let median = sorted[sorted.count / 2]

        let mean = f0Values.reduce(0, +) / Float(f0Values.count)
        let variance = f0Values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(f0Values.count)
        let stddev = sqrt(variance)
        let range = (sorted.last! - sorted.first!)

        // Use framesProcessed (subsampled count) as denominator
        let voicedRatio = Float(f0Values.count) / Float(max(framesProcessed, 1))

        // Normalize to ~[0,1] relative to speech bounds
        let f0Range = maxF0 - minF0  // 440 Hz
        let normalizedMedian = (median - minF0) / f0Range
        let normalizedStddev = min(stddev / 100.0, 1.0)  // 100 Hz stddev → 1.0
        let normalizedRange = min(range / f0Range, 1.0)

        return PitchFeatures(
            medianF0: normalizedMedian,
            stddevF0: normalizedStddev,
            rangeF0: normalizedRange,
            voicedRatio: voicedRatio
        )
    }

    /// Legacy overload for tests and external callers that pass [Float] directly.
    static func extractPitchFeatures(
        from samples: [Float],
        sampleRate: Double,
        frameLength: Int,
        hopLength: Int,
        numFrames: Int
    ) -> PitchFeatures {
        return samples.withUnsafeBufferPointer { buffer in
            extractPitchFeatures(
                from: buffer,
                range: 0..<samples.count,
                sampleRate: sampleRate,
                frameLength: frameLength,
                hopLength: hopLength,
                numFrames: numFrames
            )
        }
    }

    /// Detect fundamental frequency using autocorrelation with CMNDF (simplified YIN).
    /// Vectorized with vDSP for the difference function inner loop.
    ///
    /// Algorithm:
    /// 1. Compute difference function d(tau) using vDSP_vsub + vDSP_svesq
    /// 2. Compute cumulative mean normalized difference function (CMNDF)
    /// 3. Find first dip below threshold → lag → f0
    static func detectPitchAutocorrelation(
        buffer: UnsafeBufferPointer<Float>,
        offset: Int,
        length: Int,
        sampleRate: Double,
        minLag: Int,
        maxLag: Int
    ) -> Float? {
        guard maxLag < length, minLag < maxLag else { return nil }

        // Compute difference function d(tau) = sum of (x[j] - x[j+tau])^2
        // Vectorized: for each tau, compute diff vector then sum of squares
        var diff = [Float](repeating: 0, count: maxLag + 1)

        let basePtr = buffer.baseAddress! + offset

        for tau in 1...maxLag {
            let count = length - tau
            var sumSquares: Float = 0
            // vDSP: compute sum of (x[j] - x[j+tau])^2
            // Use vDSP_distancesq which computes sum of squared differences
            vDSP_distancesq(basePtr, 1, basePtr + tau, 1, &sumSquares, vDSP_Length(count))
            diff[tau] = sumSquares
        }

        // Compute CMNDF: d'(tau) = d(tau) / ((1/tau) * sum(d(1..tau)))
        var cmndf = [Float](repeating: 0, count: maxLag + 1)
        cmndf[0] = 1.0
        var runningSum: Float = 0

        for tau in 1...maxLag {
            runningSum += diff[tau]
            if runningSum > 0 {
                cmndf[tau] = diff[tau] * Float(tau) / runningSum
            } else {
                cmndf[tau] = 1.0
            }
        }

        // Find first dip below threshold in the valid lag range
        for tau in minLag...maxLag {
            if cmndf[tau] < pitchThreshold {
                // Parabolic interpolation for sub-sample accuracy
                let refinedTau: Float
                if tau > minLag && tau < maxLag {
                    let alpha = cmndf[tau - 1]
                    let beta = cmndf[tau]
                    let gamma = cmndf[tau + 1]
                    let denom = 2.0 * (2.0 * beta - alpha - gamma)
                    if abs(denom) > 1e-10 {
                        let delta = (alpha - gamma) / denom
                        refinedTau = Float(tau) + delta
                    } else {
                        refinedTau = Float(tau)
                    }
                } else {
                    refinedTau = Float(tau)
                }

                let f0 = Float(sampleRate) / refinedTau
                if f0 >= minF0 && f0 <= maxF0 {
                    return f0
                }
            }
        }

        return nil  // No pitch detected (unvoiced frame)
    }

    /// Legacy overload that accepts a [Float] frame for tests.
    static func detectPitchAutocorrelation(
        frame: [Float],
        sampleRate: Double,
        minLag: Int,
        maxLag: Int
    ) -> Float? {
        return frame.withUnsafeBufferPointer { buffer in
            detectPitchAutocorrelation(
                buffer: buffer,
                offset: 0,
                length: frame.count,
                sampleRate: sampleRate,
                minLag: minLag,
                maxLag: maxLag
            )
        }
    }

    // MARK: - Spectral Features

    struct SpectralFeatures {
        let centroidMean: Float
        let centroidStddev: Float
        let spreadMean: Float
        let spreadStddev: Float
    }

    /// Extract spectral centroid and spread statistics across frames.
    static func extractSpectralFeatures(
        powerSpectra: [[Float]],
        fftSize: Int,
        sampleRate: Double
    ) -> SpectralFeatures {
        let halfFFT = fftSize / 2
        let numBins = halfFFT + 1

        // Frequency for each bin
        let binFreqs = (0..<numBins).map { Float(Double($0) * sampleRate / Double(fftSize)) }

        var centroids: [Float] = []
        var spreads: [Float] = []

        for spectrum in powerSpectra {
            let totalEnergy = spectrum.reduce(0, +)
            guard totalEnergy > 1e-10 else { continue }

            // Spectral centroid: weighted mean frequency
            var weightedSum: Float = 0
            for bin in 0..<numBins {
                weightedSum += binFreqs[bin] * spectrum[bin]
            }
            let centroid = weightedSum / totalEnergy

            // Spectral spread: weighted stddev around centroid
            var spreadSum: Float = 0
            for bin in 0..<numBins {
                let diff = binFreqs[bin] - centroid
                spreadSum += diff * diff * spectrum[bin]
            }
            let spread = sqrt(spreadSum / totalEnergy)

            centroids.append(centroid)
            spreads.append(spread)
        }

        guard !centroids.isEmpty else {
            return SpectralFeatures(centroidMean: 0, centroidStddev: 0, spreadMean: 0, spreadStddev: 0)
        }

        let n = Float(centroids.count)
        let nyquist = Float(sampleRate / 2.0)

        // Compute stats and normalize to [0,1] relative to Nyquist
        let cMean = centroids.reduce(0, +) / n
        let cVar = centroids.reduce(Float(0)) { $0 + ($1 - cMean) * ($1 - cMean) } / n
        let cStddev = sqrt(cVar)

        let sMean = spreads.reduce(0, +) / n
        let sVar = spreads.reduce(Float(0)) { $0 + ($1 - sMean) * ($1 - sMean) } / n
        let sStddev = sqrt(sVar)

        return SpectralFeatures(
            centroidMean: cMean / nyquist,
            centroidStddev: cStddev / nyquist,
            spreadMean: sMean / nyquist,
            spreadStddev: sStddev / nyquist
        )
    }

    // MARK: - Internal Helpers

    static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        return v + 1
    }

    static func makeHannWindow(length: Int) -> [Float] {
        var window = [Float](repeating: 0, count: length)
        vDSP_hann_window(&window, vDSP_Length(length), Int32(vDSP_HANN_NORM))
        return window
    }

    static func computePowerSpectrum(frame: inout [Float], fftSize: Int, fftSetup: FFTSetup) -> [Float] {
        let halfFFT = fftSize / 2

        var realPart = [Float](repeating: 0, count: halfFFT)
        var imagPart = [Float](repeating: 0, count: halfFFT)

        realPart.withUnsafeMutableBufferPointer { realBuf in
            imagPart.withUnsafeMutableBufferPointer { imagBuf in
                var splitComplex = DSPSplitComplex(
                    realp: realBuf.baseAddress!,
                    imagp: imagBuf.baseAddress!
                )
                frame.withUnsafeBufferPointer { frameBuf in
                    frameBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfFFT) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfFFT))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
            }
        }

        var powerSpectrum = [Float](repeating: 0, count: halfFFT + 1)
        powerSpectrum[0] = realPart[0] * realPart[0]
        powerSpectrum[halfFFT] = imagPart[0] * imagPart[0]
        for i in 1..<halfFFT {
            powerSpectrum[i] = realPart[i] * realPart[i] + imagPart[i] * imagPart[i]
        }

        let normFactor: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(powerSpectrum, 1, [normFactor], &powerSpectrum, 1, vDSP_Length(halfFFT + 1))

        return powerSpectrum
    }

    /// Convert frequency in Hz to mel scale.
    static func hzToMel(_ hz: Double) -> Double {
        return 2595.0 * log10(1.0 + hz / 700.0)
    }

    /// Convert mel scale to frequency in Hz.
    static func melToHz(_ mel: Double) -> Double {
        return 700.0 * (pow(10.0, mel / 2595.0) - 1.0)
    }

    /// Create triangular mel filterbank matrix.
    static func makeMelFilterbank(numFilters: Int, fftSize: Int, sampleRate: Double) -> [[Float]] {
        let halfFFT = fftSize / 2
        let numBins = halfFFT + 1

        let lowMel = hzToMel(0)
        let highMel = hzToMel(sampleRate / 2.0)

        let melPoints = (0...(numFilters + 1)).map { i in
            lowMel + Double(i) * (highMel - lowMel) / Double(numFilters + 1)
        }
        let hzPoints = melPoints.map { melToHz($0) }
        let binPoints = hzPoints.map { Int(floor($0 * Double(fftSize) / sampleRate)) }

        var filterbank = [[Float]](repeating: [Float](repeating: 0, count: numBins), count: numFilters)

        for f in 0..<numFilters {
            let leftBin = binPoints[f]
            let centerBin = binPoints[f + 1]
            let rightBin = binPoints[f + 2]

            if centerBin > leftBin {
                for k in leftBin...min(centerBin, numBins - 1) {
                    filterbank[f][k] = Float(k - leftBin) / Float(centerBin - leftBin)
                }
            }
            if rightBin > centerBin {
                for k in centerBin...min(rightBin, numBins - 1) {
                    filterbank[f][k] = Float(rightBin - k) / Float(rightBin - centerBin)
                }
            }
        }

        return filterbank
    }

    /// DCT Type-II: transform log mel energies to cepstral coefficients.
    static func dctTypeII(input: [Float], outputCount: Int) -> [Float] {
        let n = input.count
        var output = [Float](repeating: 0, count: outputCount)
        let scale = sqrt(2.0 / Float(n))

        for k in 0..<outputCount {
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            output[k] = sum * scale
        }

        return output
    }

    // MARK: - Range-based RMS Energy

    /// Compute RMS energy for a range within a buffer, avoiding array copies.
    static func rmsEnergyRange(_ buffer: UnsafeBufferPointer<Float>, range: Range<Int>) -> Float {
        let count = range.count
        guard count > 0 else { return 0 }
        var sumSquares: Float = 0
        vDSP_svesq(buffer.baseAddress! + range.lowerBound, 1, &sumSquares, vDSP_Length(count))
        return sqrt(sumSquares / Float(count))
    }
}
