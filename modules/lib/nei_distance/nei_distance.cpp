// The compiled form of nei_distance.R beside it, for projects large enough to want it.
//
// Same seam: frequencies by allele, the site index that groups them, and each site's effective
// sample sizes in; the raw and corrected pool-by-pool sums and the site counts out. One pass
// over the allele rows, holding one site's sums at a time, so the per-site matrices the
// vectorized R builds across the whole bin are never allocated.
//
// Sourced by Rcpp::sourceCpp at run time, so it is compiled on the machine that runs it. The
// vectorized R beside it is the reference; nothing compares the two at run time.
//
// A compiled function holds a pointer into the process that built it, so it cannot be sent to
// a parallel worker - each process sources this for itself.
//
// THE SITE INDEX MUST BE NON-DECREASING. rowsum() in the R groups equal values wherever they
// sit, and this walks boundaries instead, so a site index that revisits a value would give the
// two different answers. It is refused rather than reconciled.

#include <Rcpp.h>
#include <cmath>
#include <vector>

// [[Rcpp::export]]
Rcpp::List nei_distance_cpp(Rcpp::NumericMatrix freq, Rcpp::IntegerVector site,
                            Rcpp::NumericMatrix n_eff_site) {
    const R_xlen_t n_row = freq.nrow();
    const R_xlen_t n_pool = freq.ncol();

    if (n_eff_site.ncol() != n_pool) {
        Rcpp::stop("nei_distance: " + std::to_string((long long) n_pool) +
                   " pools of frequencies against " +
                   std::to_string((long long) n_eff_site.ncol()) +
                   " of effective sizes. Both are the same pools read in the same order.");
    }
    if (site.size() != n_row) {
        Rcpp::stop("nei_distance: " + std::to_string((long long) n_row) +
                   " allele rows against " + std::to_string((long long) site.size()) +
                   " site indices. The index names the site of every row.");
    }

    Rcpp::NumericMatrix raw(n_pool, n_pool);
    Rcpp::NumericMatrix corrected(n_pool, n_pool);
    Rcpp::NumericMatrix sites(n_pool, n_pool);

    std::vector<double> within(n_pool);
    std::vector<double> unbiased(n_pool);
    std::vector<double> between((size_t) n_pool * n_pool);

    const double* f = REAL(freq);
    const double* ne = REAL(n_eff_site);
    const R_xlen_t n_site_given = n_eff_site.nrow();
    R_xlen_t seen = 0;

    R_xlen_t from = 0;
    while (from < n_row) {
        const int here = site[from];
        R_xlen_t to = from + 1;
        while (to < n_row && site[to] == here) to++;
        if (to < n_row && site[to] < here) {
            Rcpp::stop("nei_distance: the site index falls from " +
                       std::to_string((long long) here) + " to " +
                       std::to_string((long long) site[to]) + " at row " +
                       std::to_string((long long) to + 1) +
                       ". A site's allele rows are consecutive.");
        }
        if (seen >= n_site_given) {
            Rcpp::stop("nei_distance: more sites in the frequencies than the " +
                       std::to_string((long long) n_site_given) +
                       " in the effective sizes. Both come from one parse of one table.");
        }

        // One site's sums of squares and cross products, over its allele rows.
        for (R_xlen_t a = 0; a < n_pool; a++) within[a] = 0.0;
        for (size_t i = 0; i < between.size(); i++) between[i] = 0.0;

        for (R_xlen_t r = from; r < to; r++) {
            for (R_xlen_t a = 0; a < n_pool; a++) {
                const double fa = f[a * n_row + r];
                within[a] += fa * fa;
                for (R_xlen_t b = a + 1; b < n_pool; b++) {
                    between[(size_t) a * n_pool + b] += fa * f[b * n_row + r];
                }
            }
        }

        // A pool worth one chromosome or fewer at this site has nothing left to divide by.
        for (R_xlen_t a = 0; a < n_pool; a++) {
            const double n = ne[a * n_site_given + seen];
            unbiased[a] = (!ISNAN(n) && n <= 1.0)
                ? NA_REAL
                : within[a] - (1.0 - within[a]) / (n - 1.0);
        }

        for (R_xlen_t a = 0; a < n_pool; a++) {
            for (R_xlen_t b = a + 1; b < n_pool; b++) {
                const double cross = between[(size_t) a * n_pool + b];
                const double here_raw = 0.5 * (within[a] + within[b]) - cross;
                const double here_adj = 0.5 * (unbiased[a] + unbiased[b]) - cross;
                if (!std::isfinite(here_raw) || !std::isfinite(here_adj)) continue;
                raw(a, b) += here_raw;
                corrected(a, b) += here_adj;
                sites(a, b) += 1.0;
            }
        }

        seen++;
        from = to;
    }

    if (seen != n_site_given) {
        Rcpp::stop("nei_distance: " + std::to_string((long long) seen) +
                   " sites in the frequencies against " +
                   std::to_string((long long) n_site_given) +
                   " in the effective sizes. Both come from one parse of one table.");
    }

    // The lower triangle, which the loops above leave at zero.
    for (R_xlen_t a = 0; a < n_pool; a++) {
        for (R_xlen_t b = a + 1; b < n_pool; b++) {
            raw(b, a) = raw(a, b);
            corrected(b, a) = corrected(a, b);
            sites(b, a) = sites(a, b);
        }
    }

    return Rcpp::List::create(Rcpp::Named("raw") = raw,
                              Rcpp::Named("corrected") = corrected,
                              Rcpp::Named("sites") = sites);
}
