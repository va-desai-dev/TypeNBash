import Accelerate

/// Ordinary least squares, on LAPACK.
///
/// This is the one place the analysis layer needs real linear algebra, and the
/// one place it would be a mistake to hand-roll. A rank-deficient set of
/// predictors — two columns measuring the same thing, or a dummy set that sums
/// to the intercept — has to come back *as* a rank deficiency, not as a fit that
/// looks plausible. `dgelsd_` decides that by singular value rather than by
/// pivot magnitude, which is why the coefficients come from it.
///
/// The standard errors come from a separate QR of the same matrix: forming
/// `XᵀX` to invert it would square the condition number, and a design with a
/// VIF in the dozens is exactly where that starts to show.
nonisolated enum LeastSquares {

    struct Fit: Sendable {
        let coefficients: [Double]
        /// `(XᵀX)⁻¹`, whose diagonal scaled by the residual variance gives the
        /// squared standard errors.
        let covariance: [[Double]]
    }

    /// `design` is column-major, `observations` rows by `terms` columns,
    /// including whatever intercept column the caller put there.
    ///
    /// Returns nil when the design is rank deficient or too small to fit, which
    /// the caller reports as collinearity rather than as a failure.
    static func solve(
        design: [Double],
        observations: Int,
        terms: Int,
        outcome: [Double]
    ) -> Fit? {
        guard terms > 0, observations > terms,
              design.count == observations * terms, outcome.count == observations else { return nil }

        // Every LAPACK scalar gets its own variable: passing `&rows` as both the
        // row count and the leading dimension is two overlapping accesses to one
        // `var`, which Swift rejects at runtime.
        var rows = __LAPACK_int(observations)
        var columns = __LAPACK_int(terms)
        var rightHandSides = __LAPACK_int(1)
        var leadingA = __LAPACK_int(observations)
        var leadingB = __LAPACK_int(observations)
        var matrix = design
        var solution = outcome
        var singularValues = [Double](repeating: 0, count: terms)
        var conditionLimit = -1.0
        var rank = __LAPACK_int(0)
        var status = __LAPACK_int(0)
        var workSize = __LAPACK_int(-1)
        var work = [Double](repeating: 0, count: 1)
        var integerWork = [__LAPACK_int](repeating: 0, count: 1)

        dgelsd_(&rows, &columns, &rightHandSides, &matrix, &leadingA, &solution, &leadingB,
                &singularValues, &conditionLimit, &rank, &work, &workSize, &integerWork, &status)
        guard status == 0 else { return nil }
        workSize = __LAPACK_int(work[0])
        work = [Double](repeating: 0, count: max(1, Int(workSize)))
        integerWork = [__LAPACK_int](repeating: 0, count: max(Int(integerWork[0]), 64 * terms + 128))
        dgelsd_(&rows, &columns, &rightHandSides, &matrix, &leadingA, &solution, &leadingB,
                &singularValues, &conditionLimit, &rank, &work, &workSize, &integerWork, &status)
        guard status == 0, Int(rank) == terms else { return nil }
        let coefficients = Array(solution.prefix(terms))

        guard let inverse = Self.inverseCrossProduct(design: design,
                                                     observations: observations, terms: terms) else {
            return nil
        }
        return Fit(coefficients: coefficients, covariance: inverse)
    }

    /// `(XᵀX)⁻¹` by way of `X = QR`, so `(XᵀX)⁻¹ = R⁻¹R⁻ᵀ` and `XᵀX` is never
    /// formed.
    private static func inverseCrossProduct(
        design: [Double],
        observations: Int,
        terms: Int
    ) -> [[Double]]? {
        var rows = __LAPACK_int(observations)
        var columns = __LAPACK_int(terms)
        var leading = __LAPACK_int(observations)
        var matrix = design
        var reflectors = [Double](repeating: 0, count: terms)
        var status = __LAPACK_int(0)
        var workSize = __LAPACK_int(-1)
        var work = [Double](repeating: 0, count: 1)

        dgeqrf_(&rows, &columns, &matrix, &leading, &reflectors, &work, &workSize, &status)
        guard status == 0 else { return nil }
        workSize = __LAPACK_int(work[0])
        work = [Double](repeating: 0, count: max(1, Int(workSize)))
        dgeqrf_(&rows, &columns, &matrix, &leading, &reflectors, &work, &workSize, &status)
        guard status == 0 else { return nil }

        // R is the upper triangle of the factored matrix, packed down to p × p.
        var upper = [Double](repeating: 0, count: terms * terms)
        for column in 0..<terms {
            for row in 0...column {
                upper[row + column * terms] = matrix[row + column * observations]
            }
        }
        var order = __LAPACK_int(terms)
        var leadingR = __LAPACK_int(terms)
        dtrtri_("U", "N", &order, &upper, &leadingR, &status)
        guard status == 0 else { return nil }

        var inverse = [[Double]](repeating: [Double](repeating: 0, count: terms), count: terms)
        for row in 0..<terms {
            for column in 0..<terms {
                var total = 0.0
                for index in max(row, column)..<terms {
                    total += upper[row + index * terms] * upper[column + index * terms]
                }
                inverse[row][column] = total
            }
        }
        return inverse
    }
}
