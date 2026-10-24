import Foundation

/// The continuous distributions, which the system does not provide.
///
/// Accelerate covers linear algebra and vDSP the vector arithmetic, but there is
/// no t, F or chi-square anywhere in macOS. All three reduce to two functions —
/// the regularized incomplete beta and the regularized incomplete gamma —
/// evaluated by continued fraction on top of libm's `lgamma`. The normal
/// distribution is the exception and comes straight from `erfc`.
///
/// Upper tails are computed directly rather than as `1 - CDF`, so a very small
/// p-value keeps its significant digits instead of being rounded off against 1.
nonisolated enum Distributions {

    private static let epsilon = 3e-16
    private static let tiny = 1e-300
    private static let iterationLimit = 300

    // MARK: Normal

    static func normal(_ z: Double) -> Double {
        guard z.isFinite else { return z > 0 ? 1 : 0 }
        return erfc(-z / 2.0.squareRoot()) / 2
    }

    // MARK: Student's t

    static func studentT(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        guard t.isFinite else { return t > 0 ? 1 : 0 }
        let tail = self.incompleteBeta(df / (df + t * t), df / 2, 0.5) / 2
        return t > 0 ? 1 - tail : tail
    }

    /// `P(|T| > |t|)`, which is the two-sided p-value for a t statistic.
    static func twoTailedT(_ t: Double, df: Double) -> Double {
        guard df > 0 else { return .nan }
        guard t.isFinite else { return 0 }
        return self.incompleteBeta(df / (df + t * t), df / 2, 0.5)
    }

    // MARK: Chi-square

    static func chiSquare(_ x: Double, df: Double) -> Double {
        guard df > 0, x >= 0 else { return .nan }
        return self.lowerGamma(df / 2, x / 2)
    }

    /// The upper tail, which is the p-value for a test of independence.
    static func upperChiSquare(_ x: Double, df: Double) -> Double {
        guard df > 0, x.isFinite, x >= 0 else { return .nan }
        return self.upperGamma(df / 2, x / 2)
    }

    // MARK: F

    static func fDistribution(_ f: Double, _ d1: Double, _ d2: Double) -> Double {
        guard d1 > 0, d2 > 0, f >= 0 else { return .nan }
        return self.incompleteBeta(d1 * f / (d1 * f + d2), d1 / 2, d2 / 2)
    }

    /// The upper tail, which is the p-value for a model or ANOVA test.
    static func upperF(_ f: Double, _ d1: Double, _ d2: Double) -> Double {
        guard d1 > 0, d2 > 0 else { return .nan }
        guard f > 0, f.isFinite else { return f.isFinite ? 1 : 0 }
        return self.incompleteBeta(d2 / (d1 * f + d2), d2 / 2, d1 / 2)
    }

    /// The inverse of `studentT`, for the critical value behind a confidence
    /// interval. Found by bisection on the CDF: a mean difference's interval
    /// does not need Newton's speed, and bisection cannot be thrown off by a
    /// flat tail the way a derivative step can.
    static func inverseT(_ probability: Double, df: Double) -> Double {
        guard df > 0, probability > 0, probability < 1 else { return .nan }
        var low = -1.0, high = 1.0
        while self.studentT(low, df: df) > probability, low > -1e12 { low *= 2 }
        while self.studentT(high, df: df) < probability, high < 1e12 { high *= 2 }
        for _ in 0..<200 {
            let middle = (low + high) / 2
            if middle == low || middle == high { break }
            if self.studentT(middle, df: df) < probability { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    // MARK: Regularized incomplete beta

    static func incompleteBeta(_ x: Double, _ a: Double, _ b: Double) -> Double {
        guard a > 0, b > 0, !x.isNaN else { return .nan }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log1p(-x))
        // Each series converges quickly on only one side of this point, so the
        // symmetry I_x(a,b) = 1 - I_(1-x)(b,a) picks whichever side that is.
        if x < (a + 1) / (a + b + 2) {
            return front * self.betaFraction(x, a, b) / a
        }
        return 1 - front * self.betaFraction(1 - x, b, a) / b
    }

    /// Lentz's method for the continued fraction behind the incomplete beta.
    private static func betaFraction(_ x: Double, _ a: Double, _ b: Double) -> Double {
        let qab = a + b, qap = a + 1, qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < Self.tiny { d = Self.tiny }
        d = 1 / d
        var result = d
        for iteration in 1...Self.iterationLimit {
            let m = Double(iteration)
            let m2 = 2 * m
            var numerator = m * (b - m) * x / ((qam + m2) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < Self.tiny { d = Self.tiny }
            c = 1 + numerator / c
            if abs(c) < Self.tiny { c = Self.tiny }
            d = 1 / d
            result *= d * c
            numerator = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
            d = 1 + numerator * d
            if abs(d) < Self.tiny { d = Self.tiny }
            c = 1 + numerator / c
            if abs(c) < Self.tiny { c = Self.tiny }
            d = 1 / d
            let delta = d * c
            result *= delta
            if abs(delta - 1) < Self.epsilon { break }
        }
        return result
    }

    // MARK: Regularized incomplete gamma

    static func lowerGamma(_ a: Double, _ x: Double) -> Double {
        guard a > 0, x >= 0 else { return .nan }
        if x == 0 { return 0 }
        return x < a + 1 ? self.gammaSeries(a, x) : 1 - self.gammaFraction(a, x)
    }

    static func upperGamma(_ a: Double, _ x: Double) -> Double {
        guard a > 0, x >= 0 else { return .nan }
        if x == 0 { return 1 }
        return x < a + 1 ? 1 - self.gammaSeries(a, x) : self.gammaFraction(a, x)
    }

    private static func gammaSeries(_ a: Double, _ x: Double) -> Double {
        var term = 1 / a
        var sum = term
        var ap = a
        for _ in 0..<Self.iterationLimit {
            ap += 1
            term *= x / ap
            sum += term
            if abs(term) < abs(sum) * Self.epsilon { break }
        }
        return sum * exp(-x + a * log(x) - lgamma(a))
    }

    private static func gammaFraction(_ a: Double, _ x: Double) -> Double {
        var b = x + 1 - a
        var c = 1 / Self.tiny
        var d = 1 / b
        var result = d
        for iteration in 1...Self.iterationLimit {
            let an = -Double(iteration) * (Double(iteration) - a)
            b += 2
            d = an * d + b
            if abs(d) < Self.tiny { d = Self.tiny }
            c = b + an / c
            if abs(c) < Self.tiny { c = Self.tiny }
            d = 1 / d
            let delta = d * c
            result *= delta
            if abs(delta - 1) < Self.epsilon { break }
        }
        return result * exp(-x + a * log(x) - lgamma(a))
    }
}
