inspection_init <- function(
  pipeline,
  meta = meta_init(),
  progress = progress_init(),
  targets_only = FALSE,
  names = NULL,
  shortcut = FALSE,
  allow = NULL,
  exclude = NULL,
  outdated = TRUE,
  reporter = "silent"
) {
  inspection_new(
    pipeline = pipeline,
    meta = meta,
    progress = progress,
    targets_only = targets_only,
    names = names,
    shortcut = shortcut,
    allow = allow,
    exclude = exclude,
    outdated = outdated,
    reporter = reporter
  )
}

inspection_new <- function(
  pipeline = NULL,
  meta = NULL,
  progress = NULL,
  targets_only = NULL,
  names = NULL,
  shortcut = NULL,
  allow = NULL,
  exclude = NULL,
  outdated = NULL,
  reporter = NULL,
  vertices = NULL,
  edges = NULL,
  vertices_imports = NULL,
  edges_imports = NULL,
  vertices_targets = NULL,
  edges_targets = NULL
) {
  inspection_class$new(
    pipeline = pipeline,
    meta = meta,
    progress = progress,
    targets_only = targets_only,
    names = names,
    shortcut = shortcut,
    allow = allow,
    exclude = exclude,
    outdated = outdated,
    reporter = reporter,
    vertices = vertices,
    edges = edges,
    vertices_imports = vertices_imports,
    edges_imports = edges_imports,
    vertices_targets = vertices_targets,
    edges_targets = edges_targets
  )
}

inspection_class <- R6::R6Class(
  classname = "tar_inspection",
  inherit = network_class,
  class = FALSE,
  portable = FALSE,
  cloneable = FALSE,
  public = list(
    outdated = NULL,
    reporter = NULL,
    initialize = function(
      pipeline = NULL,
      meta = NULL,
      progress = NULL,
      targets_only = NULL,
      names = NULL,
      shortcut = NULL,
      allow = NULL,
      exclude = NULL,
      outdated = NULL,
      reporter = NULL,
      vertices = NULL,
      edges = NULL,
      vertices_imports = NULL,
      edges_imports = NULL,
      vertices_targets = NULL,
      edges_targets = NULL
    ) {
      super$initialize(
        pipeline = pipeline,
        meta = meta,
        progress = progress,
        targets_only = targets_only,
        names = names,
        shortcut = shortcut,
        allow = allow,
        exclude = exclude,
        vertices = vertices,
        edges = edges,
        vertices_imports = vertices_imports,
        edges_imports = edges_imports,
        vertices_targets = vertices_targets,
        edges_targets = edges_targets
      )
      self$outdated <- outdated
      self$reporter <- reporter
    },
    hashes_to_vertices = function(hashes) {
      data_frame(
        name = hashes$name,
        type = hashes$type,
        new = hashes$data
      )
    },
    produce_outdated = function(vertices) {
      outdated <- outdated_init(
        pipeline = self$pipeline,
        queue = "sequential",
        meta = self$meta,
        names = self$names,
        shortcut = self$shortcut,
        reporter = self$reporter
      )
      outdated$run()
      names_outdated <- counter_get_names(outdated$outdated)
      is_outdated <- vertices$name %in% names_outdated
      ifelse(is_outdated, "outdated", "uptodate")
    },
    resolve_import_status = function(vertices) {
      out <- tar_outdated_globals(pipeline = self$pipeline, meta = self$meta)
      vertices$status <- ifelse(vertices$name %in% out, "outdated", "uptodate")
      vertices$status <- as.character(vertices$status)
      vertices$status[is.na(vertices$status)] <- "queued"
      vertices$seconds <- rep(NA_real_, nrow(vertices))
      vertices$bytes <- rep(NA_real_, nrow(vertices))
      vertices$branches <- rep(NA_integer_, nrow(vertices))
      vertices[, c("name", "type", "status", "seconds", "bytes", "branches")]
    },
    resolve_target_status = function(vertices) {
      vertices <- vertices[order(vertices$name),, drop = FALSE] # nolint
      status <- if_any(
        self$outdated,
        self$produce_outdated(vertices),
        rep("queued", nrow(vertices))
      )
      pipeline <- self$pipeline
      type <- map_chr(vertices$name, function(name) {
        target_get_type(pipeline_get_target(pipeline, name))
      })
      progress <- self$progress$database$read_condensed_data()
      # Keep this line for legacy reasons:
      progress$progress <- gsub("running", "started", x = progress$progress)
      if (self$outdated) {
        index <- !(progress$progress %in% c("skipped", "built"))
        progress <- progress[index,, drop = FALSE] # nolint
      }
      out <- merge(vertices, progress, all.x = TRUE, sort = FALSE)
      out <- out[order(out$name),, drop = FALSE] # nolint
      levels <- c("skipped", "started", "built", "canceled", "errored")
      in_levels <- !is.na(out$progress) & out$progress %in% levels
      status <- ifelse(in_levels, out$progress, status)
      status[is.na(status)] <- "queued"
      data_frame(name = vertices$name, type = type, status = status)
    },
    resolve_target_meta = function(vertices) {
      self$meta$database$ensure_preprocessed(write = FALSE)
      meta <- map(vertices$name, function(name) {
        if (self$meta$exists_record(name)) {
          record <- self$meta$get_record(name)
          data_frame(
            name = name,
            seconds = record$seconds,
            bytes = record$bytes,
            branches = if_any(
              anyNA(record$children) || identical(record$type, "stem"),
              NA_integer_,
              length(record$children)
            )
          )
        }
      })
      meta <- do.call(rbind, meta) %|||% data_frame(
        name = character(0),
        seconds = numeric(0),
        bytes = numeric(0),
        branches = integer(0)
      )
      merge(vertices, meta, all.x = TRUE, sort = FALSE)
    },
    update_imports = function() {
      envir <- self$pipeline$imports
      graph <- graph_envir(envir)
      edges <- lapply(as_data_frame(igraph::get.edgelist(graph)), as.character)
      edges <- data_frame(from = edges[[1]], to = edges[[2]])
      edges <- edges[edges$from != edges$to,, drop = FALSE] # nolint
      vertices <- self$hashes_to_vertices(hash_imports_graph(envir, graph))
      self$edges_imports <- edges
      vertices <- self$resolve_import_status(vertices)
      self$vertices_imports <- vertices
    },
    update_targets = function() {
      names <- pipeline_get_names(self$pipeline)
      vertices <- data_frame(name = names)
      vertices <- self$resolve_target_status(vertices)
      vertices <- self$resolve_target_meta(vertices)
      names <- c(names, names(self$pipeline$imports))
      edges <- pipeline_upstream_edges(self$pipeline, targets_only = FALSE)
      edges <- edges[edges$from %in% names & edges$to %in% names,, drop = FALSE] # nolint
      edges <- edges[edges$from != edges$to,, drop = FALSE] # nolint
      self$edges_targets <- edges
      self$vertices_targets <- vertices
    },
    validate = function() {
      super$validate()
      tar_assert_lgl(self$outdated)
    }
  )
)
