(**************************************************************************)
(*  This file is part of a library developed with the support of the      *)
(*  Mancoosi Project. http://www.mancoosi.org                             *)
(*                                                                        *)
(*  Main author(s):  ADD authors here                                     *)
(*                                                                        *)
(*  Contributor(s):  ADD minor contributors here                          *)
(*                                                                        *)
(*  This library is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Lesser General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version.  A special linking    *)
(*  exception to the GNU Lesser General Public License applies to this    *)
(*  library, see the COPYING file for more information.                   *)
(**************************************************************************)

open ExtLib
open Common

let debug fmt = Util.make_debug "" fmt
let info fmt = Util.make_info "" fmt
let warning fmt = Util.make_warning "" fmt

module Options = struct
  open OptParse
  let description =
    "Report packages that aren't installable in any futures of a repository"
  let options = OptParser.make ~description

  include Boilerplate.MakeOptions(struct let options = options end)

  let explain = StdOpt.store_true ()
  let architecture = StdOpt.str_option ()
  let checkonly = Boilerplate.pkglist_option ()
  let brokenlist = StdOpt.store_true ()

  open OptParser
  add options ~short_name:'a' ~long_name:"architecture" 
  ~help:"Set the default architecture" architecture;

  add options ~long_name:"select" 
  ~help:"Check only these package ex. (sn1,sv1),(sn2,sv2)" checkonly;
  
  add options ~short_name:'b' 
  ~help:"Print the list of broken packages" brokenlist;

end

let rec get_versions acc = function
  |[] -> acc
  |(`Hi v|`Lo v|`Eq v)::t -> get_versions (v::acc) t
  |(`In (v1,v2))::t -> get_versions (v1::v2::acc) t
;;

let sync (sn,sv) p =
  let cn = "src/"^sn^"/"^sv in
  let v = p.Cudf.version in
  {p with
    Cudf.provides = (cn, Some (`Eq, v))::p.Cudf.provides;
    Cudf.conflicts = (cn, Some (`Neq, v))::p.Cudf.conflicts;
  }
;;

let dummy pkg number version =
  {Cudf.default_package with
   Cudf.package = pkg.Cudf.package;
   version = version;
   conflicts = pkg.Cudf.conflicts;
   provides = pkg.Cudf.provides;
   pkg_extra = [("number",`String number)]
  }

let outdated ?(verbose=false) ?(clusterlist=None) repository =
  let worktable = Hashtbl.create 1024 in
  let version_acc = ref [] in
  let constraints_table = Debian.Evolution.constraints repository in
  (* the repository here should contain only the most recent version of each
   * package *)
  let realpackages = Hashtbl.create 1023 in

  let clusters = Debian.Debutil.cluster repository in
  Hashtbl.iter (fun (sn,sv) l ->
    (* Printf.eprintf "source: %s %s\n%!" sn sv; *)
    List.iter (fun (version,cluster) ->
      (* Printf.eprintf "bin version: %s \n%!" version; *)
      let discr = Debian.Evolution.discriminants constraints_table cluster in
      let vl =
        List.fold_left (fun acc (target,equiv) ->
          (*
          Printf.eprintf "target : %s [%s]\n%!" (Debian.Evolution.string_of_range target)
          (String.concat " " (List.map Debian.Evolution.string_of_range equiv));
          *)
          get_versions (get_versions acc [target]) equiv
        ) [] discr
      in
      version_acc := vl @ !version_acc;
      List.iter (fun pkg ->
        Hashtbl.add realpackages pkg.Debian.Packages.name version
      ) cluster;
      Hashtbl.add worktable cluster (discr,sn,version)
    ) l
  ) clusters;

  version_acc := Util.list_unique !version_acc;

  Hashtbl.iter (fun name constr -> match (name,constr) with
    |(name,constr) when (Hashtbl.mem realpackages name) -> ()
    |(name,constr) -> begin
        match constr with
        |[] -> ()
        |[(`Eq,"0")] -> begin
          let pkg = {
            Debian.Packages.default_package with 
            Debian.Packages.name = name;
            version = "1";
            } 
          in
          let cluster = [pkg] in
          version_acc := "1" :: !version_acc;
          Hashtbl.add worktable cluster ([],name,"")
        end
        |_ -> begin
          let vl = Debian.Evolution.all_versions constr in
          let discr = Debian.Evolution.discriminant vl constr in
          let pkg = {
            Debian.Packages.default_package with 
            Debian.Packages.name = name;
            version = "1";
            } 
          in
          let cluster = [pkg] in
          version_acc := ("1" :: vl) @ !version_acc;
          Hashtbl.add worktable cluster (discr,name,"")
        end
    end
  ) constraints_table;
  Hashtbl.clear realpackages;
  info "1";

  let versionlist = Util.list_unique !version_acc in
  let tables = Debian.Debcudf.init_tables ~step:2 ~versionlist repository in
  let duplicates = Hashtbl.create 1023 in
  let getv = Debian.Debcudf.get_cudf_version tables in
  let pkglist = 
    Hashtbl.fold (fun cluster (constr,sn,sv) acc ->
      let sync x y = if List.length cluster > 1 then sync x y else y in
      let l = 
        List.fold_left (fun acc pkg ->
          let pn = pkg.Debian.Packages.name in
          let p = Debian.Debcudf.tocudf tables pkg in
          List.fold_left (fun acc (target,equiv) ->
            List.fold_left (fun acc target ->
              let newv =
                match target with
                |`Eq v -> getv (pn,v)
                |`Hi v -> (getv (pn,v)) + 1
                |`Lo v |`In (_,v) -> (getv (pn,v)) - 1
              in
              let number = Debian.Evolution.string_of_range target in
              if newv <> p.Cudf.version && not(Hashtbl.mem duplicates (pn,newv)) then begin
                Hashtbl.add duplicates (pn,newv) ();
                (sync (sn,sv) (dummy p number newv))::acc
              end else acc
            ) acc (target::equiv)
          ) ((sync (sn,sv) p)::acc) constr
        ) [] cluster
      in l@acc
    ) worktable []
  in
  info "2";
  (*
  List.iter (fun pkg ->
    Format.printf "%a@." Cudf_printer.pp_package pkg
  ) pkglist ;
  *)

  (* add additional pseudo-source packages *)
  let universe = Cudf.load_universe pkglist in
  info "3 %d" (List.length pkglist);

  let fmt = Format.std_formatter in
  Format.fprintf fmt "@[<v 1>report:@,";
  let callback d = if false then Diagnostic.fprintf ~failure:true ~explain:true fmt d in
  let i = Depsolver.univcheck ~callback universe in
  Format.fprintf fmt "@]@.";
;; 


let main () =
  let args = OptParse.OptParser.parse_argv Options.options in
  Boilerplate.enable_debug (OptParse.Opt.get Options.verbose);
  Boilerplate.enable_bars (OptParse.Opt.get Options.progress) [] ;
  Boilerplate.enable_timers (OptParse.Opt.get Options.timers) ["Solver"];

  let clusterlist = OptParse.Opt.opt Options.checkonly in
  let verbose = OptParse.Opt.get Options.brokenlist in

  let default_arch = OptParse.Opt.opt Options.architecture in
  let packagelist = Debian.Packages.input_raw ~default_arch args in
  let o = outdated packagelist in
  ()


;;

main ();;

