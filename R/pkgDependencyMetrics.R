## private function from itdepends/R/utils.R
.flat_map_lst <- function(x, f, ...) {
  if (!length(x)) {
    NULL
  } else {
    if (typeof(x) == "closure" && !inherits(x, "function")) {
      class(x) <- c(class(x), "function")
    }
    unlist(lapply(x, f, ...), recursive = FALSE, use.names = FALSE)
  }
}

## private function from itdepends/R/utils.R
.char_or_sym <- function(x) {
  if (is.character(x)) {
    x
  } else if (is.symbol(x)) {
    as.character(x)
  } else {
    character()
  }
}

## Private function from itdepends/R/dep_locate.R
#' @importFrom rlang is_syntactic_literal is_symbol is_pairlist is_call
.dep_usage_lang <- function(x) {
  f <- function(x) {
    ## currently, for constants such as Biostrings::DNA_BASES
    ## is_symbol(x) == TRUE and therefore won't reported as
    ## functionality calls
    if (is_syntactic_literal(x) || is_symbol(x)) {
      return(NULL)
    }

    if (is_pairlist(x) || is.expression(x)) {
      return(.flat_map_lst(x, f))
    }

    if (is_call(x, c("::", ":::"))) {
      return(list(pkg = .char_or_sym(x[[2]]), fun = .char_or_sym(x[[3]])))
    }

    if (is_call(x) && length(x[[1]]) == 1) {
      return(
        c(
          list(pkg = NA, fun = .char_or_sym(x[[1]])),
          .flat_map_lst(x, f)
          )
        )
    }

    .flat_map_lst(x, f)
  }

  res <- f(x)
  if (length(res) > 0) {
    data.frame(
      pkg = as.character(res[seq(1, length(res), 2)]),
      fun = as.character(res[seq(2, length(res), 2)]), stringsAsFactors = FALSE)
  }
}

## Private function to check arguments for pkgDep* functions
.pkgDepCheckArgs <- function(pkg, depdf) {
  if (!is.data.frame(depdf) ||
      any(!c("Package", "dependency", "edgetype") %in%
           colnames(depdf)))
    stop("argument 'depdf' must be a 'data.frame' with columns ",
         "'Package', 'dependency' and 'edgetype'.")

  if (!pkg %in% depdf$Package)
    stop(sprintf("Package %s not in the package dependency 'data.frame'.",
                 pkg))
}

#' Calculate the 'dependency gain' from excluding one or more direct 
#' dependencies
#' 
#' Calculate the difference between the total number of dependencies of a 
#' package and the number of dependencies that would remain if one or more 
#' of the direct dependencies were removed. 
#' 
#' @param g Package dependency graph
#' @param pkg Character string representing the package of interest
#' @param depsToRemove Character vector representing the dependencies 
#'   to remove
#' 
#' @author Charlotte Soneson
#' 
#' @return The 'dependency gain' that would be achieved by excluding the 
#'   indicated direct dependencies
#' 
#' @keywords internal 
#' 
#' @importFrom igraph degree delete_vertices V delete_edges
#' 
.getDepGain <- function(g, pkg, depsToRemove) {
  ## First make sure that there are no vertices with in-degree 0 in the graph
  ## (these will anyway be removed below, but they are not dependencies 
  ## of pkg)
  while (sum(igraph::degree(g, mode = "in") == 0) > 1) {
    g <- igraph::delete_vertices(
      g, setdiff(names(which(igraph::degree(g, mode = "in") == 0)), pkg)
    )
  }
  
  ## Get number of vertices
  nVertices <- length(igraph::V(g))
  
  ## For each package in depsToRemove, remove the edge from pkg to
  ## the dependency
  for (dtr in depsToRemove) {
    g <- igraph::delete_edges(g, paste(pkg, dtr, sep = "|"))
  }
  
  ## Iteratively remove vertices with in-degree 0 
  ## (there's nothing left that depends on it)
  ## pkg will always have in-degree 0, but will be retained
  while (sum(igraph::degree(g, mode = "in") == 0) > 1) {
    g <- igraph::delete_vertices(
      g, setdiff(names(which(igraph::degree(g, mode = "in") == 0)), pkg)
    )
  }
  
  ## Return the dependency gain
  nVertices - length(igraph::V(g))
}

#' Report package imported functionality
#'
#' Function adapted from 'itdepends::dep_usage_pkg' at https://github.com/r-lib/itdepends
#' to obtain the functionality imported and used by a given package.
#'
#' @importFrom tibble tibble
#' @importFrom stats setNames
#'
#' @param pkg character() name of the package for which we want
#' to obtain the functionality calls imported from its dependencies
#' and used within the package.
#'
#' @details
#' Certain imported elements, such as built-in constants, will not
#' be identified as imported functionality by this function.
#'
#' @return A tidy data frame with two columns:
#'   * `pkg`: name of the package dependency.
#'   * `fun`: name of the functionality call imported from the
#'            the dependency in the column `pkg` and used within
#'            the analyzed package.
#'
#' @author Robert Castelo
#' 
#' @examples
#' pkgDepImports('BiocPkgTools')
#' 
#' @export
#' @md
pkgDepImports <- function(pkg) {

  ## fetch all imported functionality
  imp <- getNamespaceImports(pkg)
  mask <- sapply(imp, isTRUE)
  if (any(mask)) {
    imp[mask] <- lapply(names(imp)[mask], function(pkg2) {
      ns <- getNamespace(pkg2)
      exports <- getNamespaceExports(ns)
      nms <- intersect(exports, ls(envir=ns, all.names=TRUE, sorted=FALSE))
      setNames(nms, nms)
    })
  }
  imp <- lapply(imp, grep, pattern="^.__|^-.", invert=TRUE, value=TRUE)

  ## 'getNamespaceImports()' returns a list with imported functionality
  ## by package but the imported functionality of a package may be scattered
  ## throughout more than one list entry with the same name. here we glue
  ## together those entries to have a single one per package
  fun_to_imp <- setNames(rep(names(imp), lengths(imp)),
                         unlist(imp, use.names=FALSE))
  imp <- split(names(fun_to_imp), fun_to_imp)

  ## not all imported functionality may be actually used in a package,
  ## e.g., 'import(IRanges)' and using 'findOverlaps()' only. here we
  ## fetch all calls made from the package to know what is actually
  ## being used.
  pkg_funs <- mget(ls(envir=asNamespace(pkg), all.names=TRUE,
                      sorted=FALSE),
                   envir=asNamespace(pkg), mode="function",
                   inherits=TRUE, ifnotfound=NA)

  ## according to https://cran.r-project.org/doc/manuals/r-devel/R-ints.html#S4-objects
  ## names starting with .__C__classname correspond to classes and .__T__generic:package
  ## correspond to methods. for these two entries, 'pkg_funs' is NA and we should
  ## treat them separately
  mask <- sapply(pkg_funs, function(x) is_syntactic_literal(x) && is.na(x))
  pkg_calls <- do.call(rbind, c(lapply(pkg_funs[!mask], .dep_usage_lang),
                                lapply(strsplit(sub("^\\.__.__", "",
                                                    names(pkg_funs[mask])), ":"),
                                       function(x) c(pkg=x[2], fun=x[1])),
                                make.row.names=FALSE,
                                stringsAsFactors=FALSE))

  ## remove calls to functionality from 'pkg' itself. a call to a functionality is
  ## from the 'pkg' itself ("ours") if either is annotated to 'pkg' OR is not imported
  ## AND either is not annotated either to 'pkg' or has a missing package annotation
  pkg_calls$pkg[pkg_calls$pkg == "NA"] <- NA_character_
  missing_pkg <- is.na(pkg_calls$pkg)
  our_pkg <- !is.na(pkg_calls$pkg) & pkg_calls$pkg == pkg
  ours <- our_pkg | ((!pkg_calls$fun %in% names(fun_to_imp)) & (!our_pkg | missing_pkg))
  pkg_calls <- pkg_calls[!ours, ]
  pkg_calls$pkg[is.na(pkg_calls$pkg)] <- "__otherpkgs__"

  ## group calls to functionality by imported package
  pkg_calls <- split(pkg_calls$fun, pkg_calls$pkg)

  ## now filter out from the imported functionality the part
  ## that is not actually being called from the package
  imp <- lapply(as.list(setNames(names(imp), names(imp))),
                function(nm, implst, pkgcallslst) {
                  res <- intersect(implst[[nm]], pkgcallslst[["__otherpkgs__"]])
                  if (nm %in% names(pkgcallslst))
                    res <- intersect(implst[[nm]], pkgcallslst[[nm]])
                  res
                  }, imp, pkg_calls)
  ## remove functionality from 'base' R
  imp$base <- NULL

  res <- tibble(pkg=rep(names(imp), lengths(imp)),
                fun=unlist(imp, use.names=FALSE))
  res
}

#' Calculate dependency gain achieved by excluding combinations of packages
#' 
#' @param pkg character, the name of the package for which we want
#'   to estimate the dependency gain
#' @param depdf a tidy data frame with package dependency information
#'   obtained through the function \code{\link{buildPkgDependencyDataFrame}}
#' @param maxNbr numeric, the maximal number of direct dependencies to leave 
#'   out simultaneously
#' 
#' @export
#' 
#' @author Charlotte Soneson
#' 
#' @return A data frame with three columns: ExclPackages (the excluded direct 
#'   dependencies), NbrExcl (the number of excluded direct dependencies),
#'   DepGain (the dependency gain from excluding these direct dependencies)
#' 
#' @examples
#' depdf <- buildPkgDependencyDataFrame(
#'   dependencies=c("Depends", "Imports"), 
#'   repo=c("BioCsoft", "CRAN")
#' )
#' pcd <- pkgCombDependencyGain('GEOquery', depdf, maxNbr = 3L)
#' head(pcd[order(pcd$DepGain, decreasing = TRUE), ])
#' 
#' @importFrom igraph induced_subgraph subcomponent ego
#' @importFrom utils combn
#' 
pkgCombDependencyGain <- function(pkg, depdf, maxNbr = 3L) {
  
  ## check arguments
  .pkgDepCheckArgs(pkg, depdf)

  ## fetch dependency graph
  g <- buildPkgDependencyIgraph(depdf)
  
  ## exclude 'R', 'base' and 'methods'
  excludedpkgs <- c("R", "base", "methods")
  g <- igraph::induced_subgraph(g, setdiff(names(V(g)), excludedpkgs))
  
  ## get all reachable dependencies
  deppkgs <- igraph::subcomponent(g, pkg, mode="out")
  
  ## get the induced subgraph of dependencies for 'pkg'
  g.pkg <- igraph::induced_subgraph(g, deppkgs)
  
  ## fetch first level dependencies
  dep1pkgs <- names(igraph::ego(g.pkg, nodes=pkg, mode="out", mindist=1)[[1]])

  ## exclude each combination of dependencies and calculate the 
  ## dependency gain
  allcombs <- do.call(rbind, lapply(seq_len(min(maxNbr, length(dep1pkgs))), 
                                    function(i) {
    combs <- utils::combn(dep1pkgs, i)
    do.call(rbind, apply(combs, 2, function(w) {
      data.frame(Packages = paste(w, collapse = ", "),
                 NbrExcl = length(w), 
                 DepGain = .getDepGain(g = g.pkg, pkg = pkg, 
                                       depsToRemove = w),
                 stringsAsFactors = FALSE)
    }))
  }))
  allcombs
}

#' Report package dependency burden
#'
#' Elaborate a report on the dependency burden of a given package.
#'
#' @importFrom igraph subcomponent ego
#'
#' @param pkg character() name of the package for which we want
#' to obtain metrics on its dependency burden.
#'
#' @param depdf a tidy data frame with package dependency information
#' obtained through the function \code{\link{buildPkgDependencyDataFrame}}.
#'
#' @return A tidy data frame with different metrics on the
#'         package dependency burden. More concretely, the following columns:
#'  * `ImportedAndUsed`: number of functionality calls imported and used in
#'    the package.
#'  * `Exported`: number of functionality calls exported by the dependency.
#'  * `Usage`: (`ImportedAndUsed`x 100) / `Exported`. This value provides an
#'    estimate of what fraction of the functionality of the dependency is
#'    actually used in the given package.
#'  * `DepOverlap`: Similarity between the dependency graph structure of the
#'    given package and the one of the dependency in the corresponding row,
#'    estimated as the [Jaccard index](https://en.wikipedia.org/wiki/Jaccard_index)
#'    between the two sets of vertices of the corresponding graphs. Its values
#'    goes between 0 and 1, where 0 indicates that no dependency is shared, while
#'    1 indicates that the given package and the corresponding dependency depend
#'    on an identical subset of packages.
#'  * `DepGainIfExcluded`: The 'dependency gain' (decrease in the total number
#'    of dependencies) that would be obtained if this package was excluded
#'    from the list of direct dependencies.
#'
#'  The reported information is ordered by the `Usage` column to facilitate the
#'  identification of dependencies for which the analyzed package is using a small
#'  fraction of their functionality and therefore, it could be easier remove them.
#'  To aid in that decision, the column `DepOverlap` reports the overlap of the
#'  dependency graph of each dependency with the one of the analyzed package. Here
#'  a value above, e.g., 0.5, could, albeit not necessarily, imply that removing
#'  that dependency could substantially lighten the dependency burden of the analyzed
#'  package.
#'  
#'  An `NA` value in the `ImportedAndUsed` column indicates that the function
#'  `pkgDepMetrics()` could not identify what functionality calls in the analyzed
#'  package are made to the dependency.
#'
#' @author Robert Castelo
#' @author Charlotte Soneson
#'
#' @examples
#' depdf <- buildPkgDependencyDataFrame(
#'   dependencies=c("Depends", "Imports"), 
#'   repo=c("BioCsoft", "CRAN")
#' )
#' pkgDepMetrics('BiocPkgTools', depdf)
#' 
#' @export
#' @md
pkgDepMetrics <- function(pkg, depdf) {

  ## check arguments
  .pkgDepCheckArgs(pkg, depdf)

  ## fetch dependency graph
  g <- buildPkgDependencyIgraph(depdf)

  ## exclude 'R', 'base' and 'methods'
  excludedpkgs <- c("R", "base", "methods")
  g <- induced_subgraph(g, setdiff(names(V(g)), excludedpkgs))

  ## get all reachable dependencies
  deppkgs <- subcomponent(g, pkg, mode="out")

  ## get the induced subgraph of dependencies for 'pkg'
  g.pkg <- induced_subgraph(g, deppkgs)

  ## fetch first level dependencies
  dep1pkgs <- names(ego(g.pkg, nodes=pkg, mode="out", mindist=1)[[1]])

  ## fetch imported functionality
  du <- pkgDepImports(pkg)
  du <- sapply(split(du$fun, du$pkg), unique)
  du <- lengths(du)

  ifun <- efun <- dgain <- integer(length(dep1pkgs))
  names(ifun) <- names(efun) <- names(dgain) <- dep1pkgs
  ifun[dep1pkgs] <- du[dep1pkgs]

  depov <- numeric(length(dep1pkgs))
  names(depov) <- dep1pkgs

  gvtx <- names(V(g.pkg))
  for (p in dep1pkgs) {
    deppkgs <- subcomponent(g, p, mode="out")
    gdep <- induced_subgraph(g, deppkgs)
    gdepvtx <- names(V(gdep))
    depov[p] <- length(intersect(gvtx, gdepvtx)) / length(union(gvtx, gdepvtx))
    expfun <- getNamespaceExports(p)
    efun[p] <- length(expfun[grep("^\\.", expfun, invert=TRUE)])
    dgain[p] <- .getDepGain(g = g.pkg, pkg = pkg, depsToRemove = p)
  }

  res <- data.frame(ImportedAndUsed=ifun,
                    Exported=efun,
                    Usage=round(100*ifun/efun, digits=2),
                    DepOverlap=round(depov, digits=2),
                    DepGainIfExcluded=dgain,
                    row.names=dep1pkgs,
                    stringsAsFactors=FALSE)
  res[order(res$Usage), ]
}
