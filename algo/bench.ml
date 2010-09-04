(**************************************************************************************)
(*  Copyright (C) 2010 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2010 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

open ExtLib

module Options = struct
  open OptParse

  let verbose = StdOpt.incr_option ()
  let run = StdOpt.store_false ()

  let description = ""
  let options = OptParser.make ~description:description ()

  open OptParser
  (*
  add options ~short_name:'v' ~help:"Print information (can be repeated)" verbose;
  add options ~short_name:'r' ~long_name:"run" ~help:"run all tests" run;
  *)
end

(* ----------------------------------- *)


let main () =
  let posargs = OptParse.OptParser.parse_argv Options.options in

  let reps = Int64.of_int 4 in
  let latency s f = Benchmark.latency1 ~name:s reps f in 
  let load = latency "Depsolver.load" Depsolver.load in
  let trim = latency "Depsolver.trim" Depsolver.trim in
  let univcheck = latency "Depsolver.univcheck" Depsolver.univcheck in
  let strongdeps = latency "Strongdeps.strongdeps" Strongdeps.strongdeps_univ in
  let strongconflicts = latency "Strongconflicts.strongconflicts" Strongconflicts.strongconflicts in

  let run () =
    let universe =
      let f_debian = "tests/debian.cudf" in
      let (_,pl,_) = Cudf_parser.parse_from_file f_debian in
      Cudf.load_universe pl
    in
    List.fold_left Benchmark.merge [] [
      strongdeps universe;
      (* strongconflicts universe; *)
      univcheck universe;
      load universe;
      trim universe;
    ] 
  in

  if OptParse.Opt.get Options.run then begin
    let b = ExtBenchmark.make_benchmark (run ()) in
    ExtBenchmark.save_benchmark b
  end ;
  (* this will also read the new benchmark *)
  let l = ExtBenchmark.parse_benchmarks () in
  Format.printf "%a@." ExtBenchmark.pp_benchmarks l
;;

main () ;;

