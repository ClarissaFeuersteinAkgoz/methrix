get_source_idx = function(protocol = NULL){
  if(protocol == "MethylcTools"){
    return(list(col_idx = c(chr = 1, start = 2, strand = 3, context = 4, cnp_rate = 5, M = 6, U = 7),
                col_classes = c("character", "numeric", "character", "character", "numeric", "integer", "integer"),
                fix_missing = c("end := start+1", "cov := M+U", "beta := M/cov")))
  }else{
    #Bismark and methyldackel have same output format
    return(list(col_idx = c(chr = 1, start = 2, end = 3, beta = 4, M = 5, U = 6),
                col_classes = c("character", "numeric", "numeric", "numeric", "integer", "integer"),
                fix_missing = c("cov := M+U", "strand := '.'")))
  }
}

#--------------------------------------------------------------------------------------------------------------------------

#Parse custom indices and return missing info
parse_source_idx = function(chr = NULL, start = NULL, end = NULL, strand = NULL,
                            beta = NULL, n_meth = NULL, n_unmeth = NULL, cov = NULL, beta_fract = FALSE, verbose = TRUE){

  #mandatory chr and start field
  if(is.null(chr) | is.null(start)){
    stop("missing chromosome/start indices\nUse pipeline argument if the files are from Bismark, MethyDeckal, or MethylcTools", call. = FALSE)
  }

  #See if any indices are duplicated
  if(length(which(duplicated(c(chr, start, end, strand, beta, n_meth, n_unmeth, cov)))) > 0){
    stop("Duplicated indices.", call. = FALSE)
  }

  #Check maximum betavalues (Can be 1 or 100)
  if(beta_fract){
    cov_scale = 1
  }else{
    cov_scale = 100
  }
  fix_missing = vector()
  if(is.null(strand)){
    fix_missing = "strand := '*'"
  }

  #If beta and cov are missing
  if(all(is.null(beta), is.null(cov))){
    if(is.null(n_meth) | is.null(n_unmeth)){
      stop("Missing beta or coverage values.\nU and M are not available either!", call. = FALSE)
    }else{
      if(verbose){
        message("Missing beta and coverage info.\nEstimating them from M and U values.")
      }

      return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                              beta = beta, M = n_meth, U = n_unmeth, cov = cov),
                  fix_missing = c(fix_missing, "cov := M+U", "beta := M/(M+U)")))
    }
  }else if(is.null(beta) & !is.null(cov)){ #If anyone of them is present (case-1: coverage available, estimate beta)
    if(all(is.null(n_meth), is.null(n_unmeth))){
      stop("Missing beta values but coverage info available.\nEither U or M are required for estimating beta values!", call. = FALSE)
    }else if(all(!is.null(n_meth), !is.null(n_unmeth))){
      message("Estimating beta values from M and U..")
      return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                              beta = beta, M = n_meth, U = n_unmeth, cov = cov),
                  fix_missing = c(fix_missing, "beta := M/(M+U")))
    }else if(!is.null(n_meth)){ #M available
      message("Estimating beta values from M and coverage..")
      return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                              beta = beta, M = n_meth, U = n_unmeth, cov = cov),
                  fix_missing = c(fix_missing, "beta := M/cov")))
    }else if(!is.null(n_unmeth)){ #U available
      message("Estimating beta values from U and coverage..")
      return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                              beta = beta, M = n_meth, U = n_unmeth, cov = cov),
                  fix_missing = c(fix_missing, paste0("beta := 1- (U/cov)"))))
    }
  } else if(!is.null(beta) & is.null(cov)){ #If anyone of them is present (case-2: beta available, estimate coverage)
    if(all(is.null(n_meth), is.null(n_unmeth))){
      stop("Missing coverage info but beta values are available.\nU and M are required for estimating coverage values!", call. = FALSE)
    }else{
      if(verbose){
        message("Estimating coverage from M and U..")
      }

      return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                              beta = beta, M = n_meth, U = n_unmeth, cov = cov),
                  fix_missing = c(fix_missing, "cov := M+U")))
    }
  }else{
    if(verbose){
      message("All fields are present. Nice.")
    }

    return(list(col_idx = c(chr = chr, start = start, end = end, strand = strand,
                            beta = beta, cov = cov),
                fix_missing = NULL))
  }
}

#--------------------------------------------------------------------------------------------------------------------------

#Read bedgraphs, and add missing info
read_bdg = function(bdg, col_list = NULL, genome = NULL, verbose = TRUE, strand_collapse = FALSE){

  bdg_dat = data.table::fread(file = bdg, sep = "\t", colClasses = col_list$col_classes, verbose = FALSE, showProgress = FALSE)
  colnames(bdg_dat)[col_list$col_idx] = names(col_list$col_idx)

  if(!is.null(col_list$fix_missing)){
    for(cmd in col_list$fix_missing){
      bdg_dat[,eval(parse(text=cmd))]
    }
  }

  if(strand_collapse){
    #If strand information needs to collapsed, bring start position of crick strand to previous base (on watson base)
    #and estimate new M, U and beta values
    if(!all(c("M", "U") %in% names(bdg_dat))){
      stop("strand_collapse works only when M and U are available!")
    }

    bdg_dat[,start := ifelse(strand == '-', yes = start - 1, no = start)]
    bdg_dat = bdg_dat[, .(M = sum(M), U = sum(U)), .(chr, start)]
    bdg_dat[,cov := M + U]
    bdg_dat[,beta := M/cov]
    bdg_dat[,strand := "*"]
  }

  #Handle NaNs (resulting from 0/0)
  bdg_dat$beta = replace(x = bdg_dat$beta, list = is.nan(bdg_dat$beta), values = NA)
  bdg_dat = bdg_dat[,.(chr, start, beta, cov, strand)]
  bdg_dat[, chr := as.character(chr)]
  bdg_dat[, start := as.integer(start)]

  #Check for contig prefixes and add them if necessary
  if(grepl(pattern = "chr", x = genome[1, chr]) != grepl(pattern = "chr", x = bdg_dat[1, chr])){
    if(grepl(pattern = "chr", x = genome[1, chr])){
      bdg_dat[, chr := paste0("chr", chr)]
    }else if(grepl(pattern = "chr", x = bdg_dat[1, chr])){
      bdg_dat[, chr := paste0("chr", chr)]
    }else{
      stop("Prefix mismatch between provided CpGs and bedgraphs")
    }
  }

  missing_cpgs = genome[!bdg_dat[,list(chr, start)], on = c("chr", "start")]
  if(verbose){
    message(paste0("Missing ", nrow(missing_cpgs), " reference CpGs from: ", basename(bdg)))
  }
  if(nrow(missing_cpgs)>0){
    missing_cpgs[, width := NULL][, end := NULL][, beta := NA][, cov := 0]
    bdg_dat = data.table::rbindlist(list(bdg_dat, missing_cpgs), use.names = TRUE)
  }
  data.table::setkey(x = bdg_dat, "chr", "start")
  data.table::setkey(x = genome, "chr", "start")

  #Better than identical(); seems to take couple of seconds but this is crucial to make sure everything is in order
  if(data.table:::all.equal.data.table(target = bdg_dat[,.(chr, start)],
                                       current = genome[,.(chr, start)],
                                       ignore.row.order = FALSE)){
    return(bdg_dat)
  }else{
    stop("Something went wrong with filling up the non-covered CpG sites.")
  }
}

#--------------------------------------------------------------------------------------------------------------------------

#Process samples in batches. Batches are processed in vectorized manner (ideal for large number of samples)
vect_code_batch = function(files, col_idx, batch_size,  col_data = NULL, genome = NULL, strand_collapse = FALSE, thr = 1){
  batches = split(files, ceiling(seq_along(files)/batch_size))
  batches_samp_names = split(rownames(col_data), ceiling(seq_along(rownames(col_data))/batch_size))

  beta_mat_final = data.table::data.table()
  cov_mat_final = data.table::data.table()

  for(i in seq_along(batches)){
    #browser()
    message(paste0("Processing batch ",  i , " of ", length(batches)))
    batch_files = batches[[i]]
    samp_names = batches_samp_names[[i]]
    bdgs = parallel::mclapply(batch_files, read_bdg, col_list = col_idx, genome = genome, strand_collapse = strand_collapse, mc.cores = thr)
    names(bdgs) = samp_names

    if(i == 1){
      cov_mat_final = data.frame(lapply(bdgs, function(x) x[,.(cov)]), stringsAsFactors = FALSE)
      beta_mat_final = data.frame(lapply(bdgs, function(x) x[,.(beta)]), stringsAsFactors = FALSE)
      colnames(cov_mat_final) = colnames(beta_mat_final) = samp_names
    }else{
      cov_mat = data.frame(lapply(bdgs, function(x) x[,.(cov)]), stringsAsFactors = FALSE)
      beta_mat = data.frame(lapply(bdgs, function(x) x[,.(beta)]), stringsAsFactors = FALSE)
      colnames(cov_mat) = colnames(beta_mat) = samp_names
      cov_mat_final = cbind(cov_mat_final, cov_mat)
      beta_mat_final = cbind(beta_mat_final, beta_mat)
      rm(cov_mat)
      rm(beta_mat)
      gc()
    }
  }

  return(list(beta_matrix = data.table::setDT(beta_mat_final), cov_matrix = data.table::setDT(cov_mat_final)))
}

#--------------------------------------------------------------------------------------------------------------------------

#Use for loop for sample-by-sample processing, memory efficient, uses HDF5Array
non_vect_code = function(files, col_idx, coldata, verbose = TRUE,  genome = NULL, h5temp = NULL, h5 = FALSE, strand_collapse = FALSE){

  if(h5){
    if(is.null(h5temp)){
      h5temp <- tempdir()}
    sink_counter <- 1
    while(any(c(paste0("M_sink_",sink_counter, ".h5"),
                paste0("cov_sink_",sink_counter, ".h5")) %in%  dir(h5temp))){
      sink_counter <- sink_counter+1

    }
    grid <- DelayedArray::RegularArrayGrid(
      refdim = c(nrow(genome), length(files)),
      spacings = c(nrow(genome), 1L))

    M_sink <- HDF5Array::HDF5RealizationSink(
      dim = c(nrow(genome), length(files)),
      dimnames = NULL,
      type = "double",
      filepath = file.path(h5temp, paste0("M_sink_",sink_counter, ".h5")),
      name = "M", chunkdim = HDF5Array::getHDF5DumpChunkDim(c(nrow(genome), length(files))),
      level = 6)
    cov_sink <- HDF5Array::HDF5RealizationSink(
      dim = c(nrow(genome), length(files)),
      dimnames = NULL,
      type = "integer",
      filepath = file.path(h5temp, paste0("cov_sink_",sink_counter, ".h5")),
      name = "cov", chunkdim = HDF5Array::getHDF5DumpChunkDim(c(nrow(genome), length(files))),
      level = 6)
  } else {
    beta_mat = data.table::data.table()
    cov_mat = data.table::data.table()
  }
  if(h5){
    #browser()
    for(i in seq_along(files)){
      if(verbose){
        message("Processing: ", files[i])
      }
      b = read_bdg(bdg = files[i], col_list = col_idx, genome = genome, strand_collapse = strand_collapse)
      DelayedArray::write_block(block=as.matrix(b[, .(beta)]), viewport = grid[[i]], sink = M_sink)
      DelayedArray::write_block(block=as.matrix(b[, .(cov)]), viewport = grid[[i]], sink = cov_sink)
      rm(b)
      gc()
    }
    return(list(beta_matrix = as(M_sink, "HDF5Array"), cov_matrix = as(cov_sink, "HDF5Array")))
  } else {
    for(i in seq_along(files)){
      if(verbose){
        message("Processing: ", files[i])
      }
      if(i == 1){
        b = read_bdg(bdg = files[i], col_list = col_idx, genome = genome, strand_collapse = strand_collapse)
        beta_mat = b[,.(chr, start, beta)]
        cov_mat = b[,.(chr, start, cov)]
      }else{
        b = read_bdg(bdg = files[i], col_list = col_idx, genome = genome, strand_collapse = strand_collapse)
        beta_mat = cbind(beta_mat, b[,.(beta)])
        cov_mat = cbind(cov_mat, b[,.(cov)])
      }
      colnames(beta_mat)[ncol(beta_mat)] = colnames(cov_mat)[ncol(cov_mat)] = rownames(coldata)[i]
    }
    return(list(beta_matrix = beta_mat, cov_matrix = cov_mat))

  }
}