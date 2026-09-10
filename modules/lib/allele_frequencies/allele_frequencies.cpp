// The compiled form of allele_frequencies.R beside it, for projects large enough to want it.
//
// Same seam: a list of depth-table columns in, a list of site, alleles, depth and freq out. One
// pass over the strings, parsing digits as it goes, so the split lists the vectorized R spends
// its time allocating are never built.
//
// Sourced by Rcpp::sourceCpp at run time, so it is compiled on the machine that runs it. The
// vectorized R beside it is the reference; nothing compares the two at run time.
//
// A compiled function holds a pointer into the process that built it, so it cannot be sent to
// a parallel worker - each process sources this for itself.
//
// A cell is REF then each ALT, comma separated. THE ARITY RULE IS R'S strsplit RULE, trailing
// empty field and all: a count is the commas plus one, less one when the cell ends on a comma,
// and an empty cell is no alleles at all. A field that is not a run of digits - "." above all,
// which is bcftools' missing value - takes that pool's whole site with it, as it does in the R.

#include <Rcpp.h>
#include <string>
#include <vector>

// How many counts one cell holds, exactly as strsplit(cell, ",", fixed = TRUE) would say.
static inline R_xlen_t cell_arity(const char* s) {
    if (*s == '\0') return 0;
    R_xlen_t n = 1;
    char last = '\0';
    for (const char* c = s; *c != '\0'; c++) {
        if (*c == ',') n++;
        last = *c;
    }
    if (last == ',') n--;
    return n;
}

// [[Rcpp::export]]
Rcpp::List allele_frequencies_cpp(Rcpp::List columns) {
    const R_xlen_t n_pool = columns.size();
    if (n_pool == 0) Rcpp::stop("allele_frequencies: no pools to read");

    std::vector<Rcpp::CharacterVector> cols;
    cols.reserve(n_pool);
    for (R_xlen_t p = 0; p < n_pool; p++) {
        cols.push_back(Rcpp::as<Rcpp::CharacterVector>(columns[p]));
    }

    Rcpp::CharacterVector named;
    if (columns.hasAttribute("names")) named = columns.names();
    auto label = [&](R_xlen_t p) -> std::string {
        if (named.size() > p && named[p] != NA_STRING && CHAR(named[p])[0] != '\0') {
            return std::string(CHAR(named[p]));
        }
        return "column " + std::to_string((long long) p + 1);
    };

    const R_xlen_t n_site = cols[0].size();
    std::vector<R_xlen_t> sizes;
    for (R_xlen_t p = 0; p < n_pool; p++) {
        if (std::find(sizes.begin(), sizes.end(), cols[p].size()) == sizes.end()) {
            sizes.push_back(cols[p].size());
        }
    }
    if (sizes.size() > 1) {
        std::string held;
        for (size_t i = 0; i < sizes.size(); i++) {
            if (i > 0) held += ", ";
            held += std::to_string((long long) sizes[i]);
        }
        Rcpp::stop("allele_frequencies: the pools hold " + held +
                   " sites. Every column is the same table read down the same rows.");
    }

    // The arities of the first pool, which every other pool is held to.
    Rcpp::IntegerVector alleles(n_site);
    R_xlen_t n_row = 0;
    for (R_xlen_t i = 0; i < n_site; i++) {
        const R_xlen_t k = cols[0][i] == NA_STRING ? 1 : cell_arity(CHAR(cols[0][i]));
        if (k < 1) {
            Rcpp::stop("allele_frequencies: " + label(0) + " has no counts at site " +
                       std::to_string((long long) i + 1) +
                       ". A cell holds one count per allele and a site holds at least one "
                       "allele; an empty cell is a table that lost a field, not a pool that "
                       "saw nothing.");
        }
        alleles[i] = (int) k;
        n_row += k;
    }

    Rcpp::IntegerVector site(n_row);
    for (R_xlen_t i = 0, row = 0; i < n_site; i++) {
        for (R_xlen_t j = 0; j < alleles[i]; j++) site[row++] = (int) i + 1;
    }

    Rcpp::NumericMatrix depth(n_site, n_pool);
    Rcpp::NumericMatrix freq(n_row, n_pool);

    // ONE CELL'S COUNTS, PARSED ONCE. The frequencies need the total, which is not known until
    // the last count is read, so they are held rather than the digits being walked a second
    // time. Sites are biallelic almost always and the fixed buffer covers every real cell; the
    // vector is what an ALT list longer than that falls back to.
    double small[32];
    std::vector<double> large;

    for (R_xlen_t p = 0; p < n_pool; p++) {
        SEXP col = cols[p];
        double* depth_p = REAL(depth) + p * n_site;
        double* freq_p = REAL(freq) + p * n_row;
        R_xlen_t row = 0;

        for (R_xlen_t i = 0; i < n_site; i++) {
            const R_xlen_t k = alleles[i];
            SEXP cell = STRING_ELT(col, i);
            const bool is_na = cell == NA_STRING;

            // The first pool's arities are what `alleles` already holds, from these same cells.
            if (p > 0) {
                const R_xlen_t here = is_na ? 1 : cell_arity(CHAR(cell));
                if (here < 1) {
                    Rcpp::stop("allele_frequencies: " + label(p) + " has no counts at site " +
                               std::to_string((long long) i + 1) +
                               ". A cell holds one count per allele and a site holds at least "
                               "one allele; an empty cell is a table that lost a field, not a "
                               "pool that saw nothing.");
                }
                if (here != k) {
                    Rcpp::stop("allele_frequencies: " + label(p) + " holds " +
                               std::to_string((long long) here) + " counts at site " +
                               std::to_string((long long) i + 1) + " where " + label(0) +
                               " holds " + std::to_string((long long) k) +
                               ". One ALT list serves every pool, so a row where the cells "
                               "differ in length is not the table this reads.");
                }
            }

            double* v = small;
            if (k > (R_xlen_t) (sizeof small / sizeof *small)) {
                large.resize(k);
                v = large.data();
            }

            double total = 0.0;
            bool missing = is_na;
            if (!missing) {
                const char* s = CHAR(cell);
                for (R_xlen_t j = 0; j < k; j++) {
                    if (*s < '0' || *s > '9') { missing = true; break; }
                    double value = 0.0;
                    while (*s >= '0' && *s <= '9') { value = value * 10.0 + (*s - '0'); s++; }
                    if (*s != ',' && *s != '\0') { missing = true; break; }
                    if (*s == ',') s++;
                    v[j] = value;
                    total += value;
                }
            }

            if (missing) {
                depth_p[i] = NA_REAL;
                for (R_xlen_t j = 0; j < k; j++) freq_p[row + j] = NA_REAL;
            } else if (total <= 0.0) {
                depth_p[i] = 0.0;
                for (R_xlen_t j = 0; j < k; j++) freq_p[row + j] = NA_REAL;
            } else {
                depth_p[i] = total;
                for (R_xlen_t j = 0; j < k; j++) freq_p[row + j] = v[j] / total;
            }
            row += k;
        }
    }

    if (named.size() > 0) {
        Rcpp::List dn = Rcpp::List::create(R_NilValue, named);
        depth.attr("dimnames") = dn;
        freq.attr("dimnames") = dn;
    }

    return Rcpp::List::create(Rcpp::Named("site") = site,
                              Rcpp::Named("alleles") = alleles,
                              Rcpp::Named("depth") = depth,
                              Rcpp::Named("freq") = freq);
}
