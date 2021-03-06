(**************************************************************************)
(*                                                                        *)
(*              OCamlPro-Inria-Irill Attribution AGPL                     *)
(*                                                                        *)
(*   Copyright OCamlPro-Inria-Irill 2011-2016. All rights reserved.       *)
(*   This file is distributed under the terms of the AGPL v3.0            *)
(*   (GNU Affero General Public Licence version 3.0) with                 *)
(*   a special OCamlPro-Inria-Irill attribution exception.                *)
(*                                                                        *)
(*     Contact: <typerex@ocamlpro.com> (http://www.ocamlpro.com/)         *)
(*                                                                        *)
(*  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,       *)
(*  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES       *)
(*  OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND              *)
(*  NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS   *)
(*  BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN    *)
(*  ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN     *)
(*  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE      *)
(*  SOFTWARE.                                                             *)
(**************************************************************************)



open CheckTypes.V
open CheckTypes
open StringCompat
open CopamInstall

let debug = (try ignore (Sys.getenv "OPAM_BUILDER_DEBUG"); true
  with _ -> false)

let checksum_rule targets checksum f =
  match targets with
  | [] -> assert false
  | target_file :: _ ->
    let checksum_file = target_file ^ ".checksum" in
    let all_targets = checksum_file :: targets in
    try
      List.iter (fun file ->
        if not (Sys.file_exists file) then begin
          if debug then begin
            Printf.eprintf "checksum_rule: missing target %s\n%!" file
          end;
          raise Exit
        end
      ) all_targets;
      let old_checksum = CheckDigest.digest_of_file checksum_file in
      if old_checksum <> checksum then begin
          if debug then begin
            Printf.eprintf "checksum_rule: mismatch checksum %s\n%!" target_file;
            Printf.eprintf "   old-crc: %s\n"
              (CheckDigest.to_printable_string old_checksum);
            Printf.eprintf "   new-crc: %s\n"
              (CheckDigest.to_printable_string checksum);
          end;
        raise Exit;
      end
          (* ok, everything is up to date *)
    with Exit ->
      List.iter (fun file ->
        try Sys.remove file with _ -> ()
      ) all_targets;
      f ();
      CheckDigest.file_of_digest checksum_file checksum

let new_package c package_name =
  try
    StringMap.find package_name c.packages
  with Not_found ->
    let p = {
      package_name;
      package_visited = 0;
      package_local_checksum = None;
      package_transitive_checksum = None;
      package_versions = StringMap.empty;
      package_deps = StringMap.empty;
      package_status = [||];
    } in
    c.packages <- StringMap.add package_name p c.packages;
    p

let new_version c
    version_package version_name version_checksum version_deps =
  let version_package = new_package c version_package in
  let v = {
    version_package;
    version_name;
    version_checksum;
    version_visited = 0;
    version_deps = StringMap.empty;
    version_status = [||];
    version_lint = None;
  } in
  version_package.package_versions <- StringMap.add version_name
    v version_package.package_versions;
  StringSet.iter (fun dep ->
    let p = new_package c dep in
    v.version_deps <- StringMap.add dep p v.version_deps;
    v.version_package.package_deps <- StringMap.add dep p
      v.version_package.package_deps;
  ) version_deps;
  v

let opam_file dirs v =
  let p = v.version_package in
  String.concat "/"
    [ dirs.repo_dir; "packages";
      p.package_name; v.version_name; "opam"]

let check_commit ~lint ~commit dirs switches =
  Printf.eprintf "check_commit %s\n%!" commit;

  let check_date = CopamMisc.gettime () in
  let c = {
    check_date;
    commit_name = commit;
    switches;
    versions = StringMap.empty;
    packages = StringMap.empty;
  } in
  let npackages = ref 0 in

  (* 1/ hash all packages'versions. Compute the graph of versions. *)

  Printf.eprintf "hashing repository...\n%!";
  CopamRepo.iter_packages dirs.repo_dir (fun package version dirname ->
    let opam_file = Filename.concat dirname "opam" in
    if Sys.file_exists opam_file then
      try
        let checksum = CheckHash.hash_directory dirname in

        let file = CopamOpamFile.parse opam_file in
        (*         CopamOpamFile.print file *)
        let deps = CopamOpamFile.all_possible_deps file in
        let v = new_version c package version checksum deps in
        c.versions <- StringMap.add version v c.versions;
        incr npackages;
        ()
      with exn ->
        Printf.eprintf "Warning: Could not parse %s\n%!" opam_file;
        Printf.eprintf "  Exception %S\n%!" (Printexc.to_string exn)
  );
  Printf.eprintf "hashing repository...%d done\n%!" !npackages;

  (* 2/ compute each package checksum, and lint it. *)

  StringMap.iter (fun _ p ->
    let package_dir = Filename.concat dirs.cache_dir p.package_name in
    if not (Sys.file_exists package_dir) then Unix.mkdir package_dir 0o775;

    StringMap.iter (fun _ v ->
      let version_dir = Filename.concat package_dir v.version_name in
      if not (Sys.file_exists version_dir) then Unix.mkdir version_dir 0o775;

      let checksum = v.version_checksum in

      let lint_file = Filename.concat version_dir
        (Printf.sprintf "%s.lint" v.version_name) in

      checksum_rule [lint_file] checksum (fun () ->

        if lint then
          let opam_file = opam_file dirs v in
          let lint = CopamLint.lint opam_file in
          CopamLint.save lint_file lint;
        else
          FileString.write_file lint_file "lint disabled\n"
      )
    ) p.package_versions;
  ) c.packages;


  (* 3/ compute a local hash of every package *)

  Printf.eprintf "computing package local checksums...\n%!";
  StringMap.iter (fun _ p ->
    CheckHash.hash_package_content p
  ) c.packages;

  (* 4/ compute a hash of the transitive closure of a package *)

  Printf.eprintf "computing package transitive checksums...\n%!";
  let visit = ref 0 in
  StringMap.iter (fun package_name p ->
    CheckHash.hash_package_closure p visit;
  ) c.packages;

  if not (Sys.file_exists dirs.cache_dir) then
    Unix.mkdir dirs.cache_dir 0o775;
  StringMap.iter (fun package_name p ->
    match p.package_transitive_checksum with
    | None -> assert false
    | Some (checksum, closure) ->

      let package_dir = Filename.concat dirs.cache_dir package_name in
      if not (Sys.file_exists package_dir) then Unix.mkdir package_dir 0o775;

      let closure_file = Filename.concat package_dir "closure.txt" in

      checksum_rule [closure_file] checksum (fun () ->
        let oc = open_out closure_file in
        StringMap.iter (fun package_name _ ->
          Printf.fprintf oc "%s\n" package_name;
        ) closure;
        close_out oc;
      );
  ) c.packages;

  Printf.eprintf "check_commit %s... done\n%!" commit;
  c
