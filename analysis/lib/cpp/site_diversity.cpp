// The compiled form of analysis/lib/R/site_diversity.R, for projects large enough to want it.
//
// Same seam: a character vector of depth-table cells in, a list of two numeric vectors out. One
// pass over the strings, parsing digits as it goes, so nothing between the input and the two
// answers is ever allocated - which is what the vectorised R spends its time on once a genome
// runs to tens of millions of sites.
//
// Sourced by Rcpp::sourceCpp at run time, so it is compiled on the machine that runs it. The
// vectorised R beside it is the reference this is judged against, over a corpus of mixed-arity
// sites; nothing compares the two at run time.
//
// A compiled function holds a pointer into the process that built it, so it cannot be sent to
// a parallel worker - each process sources this for itself.
//
// A cell is REF then each ALT, comma separated. "." is bcftools' missing value and makes the
// whole site NA, as it does in the R.

#include <Rcpp.h>

// [[Rcpp::export]]
Rcpp::List site_diversity_cpp(Rcpp::CharacterVector cells) {
    const R_xlen_t n = cells.size();
    Rcpp::NumericVector depth(n);
    Rcpp::NumericVector h(n);

    for (R_xlen_t i = 0; i < n; i++) {
        if (cells[i] == NA_STRING) {
            depth[i] = NA_REAL;
            h[i] = NA_REAL;
            continue;
        }
        const char* s = CHAR(cells[i]);

        // Two passes over one short string: the total, then the squared frequencies. The
        // string stays in cache between them, and it saves holding the counts anywhere.
        double total = 0.0;
        bool missing = false;
        for (const char* c = s; *c != '\0'; ) {
            if (*c == ',') { c++; continue; }
            if (*c == '.') { missing = true; break; }
            double value = 0.0;
            while (*c >= '0' && *c <= '9') { value = value * 10.0 + (*c - '0'); c++; }
            total += value;
            while (*c != ',' && *c != '\0') c++;
        }
        if (missing) {
            depth[i] = NA_REAL;
            h[i] = NA_REAL;
            continue;
        }
        if (total <= 0.0) {
            depth[i] = 0.0;
            h[i] = NA_REAL;
            continue;
        }

        double squares = 0.0;
        for (const char* c = s; *c != '\0'; ) {
            if (*c == ',') { c++; continue; }
            double value = 0.0;
            while (*c >= '0' && *c <= '9') { value = value * 10.0 + (*c - '0'); c++; }
            const double p = value / total;
            squares += p * p;
            while (*c != ',' && *c != '\0') c++;
        }

        depth[i] = total;
        h[i] = 1.0 - squares;
    }

    return Rcpp::List::create(Rcpp::Named("depth") = depth, Rcpp::Named("h") = h);
}
