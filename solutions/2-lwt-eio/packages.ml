open Lwt.Infix

module Store = Git_unix.Store
module Search = Git.Search.Make (Digestif.SHA1) (Store)

(* The set of versions available for some package name. To speed things up, we
   parse the opam files lazily.

   Ideally we'd also load the files lazily, but [get_versions] can't return a
   Lwt promise, as the solver doesn't use Lwt, so we can't use Git_unix
   in the solver callback. *)
type candidates = OpamFile.OPAM.t OpamPackage.Version.Map.t Eio.Lazy.t

type t = candidates OpamPackage.Name.Map.t

(* Load a Git directory tree from the store by hash. *)
let read_dir store hash =
  Store.read store hash >|= function
  | Error e -> Fmt.failwith "Failed to read tree: %a" Store.pp_error e
  | Ok (Git.Value.Tree tree) -> Some tree
  | Ok _ -> None

(* Load [pkg]'s opam file from its directory. *)
let read_package store pkg hash =
  Search.find store hash (`Path [ "opam" ]) >>= function
  | None ->
    Fmt.failwith "opam file not found for %s" (OpamPackage.to_string pkg)
  | Some hash -> (
      Store.read store hash >|= function
      | Ok (Git.Value.Blob blob) ->
        let blob = Store.Value.Blob.to_string blob in
        begin
          try OpamFile.OPAM.read_from_string blob
          with ex ->
            Fmt.failwith "Error parsing %s: %s" (OpamPackage.to_string pkg) (Printexc.to_string ex)
        end
      | _ ->
        Fmt.failwith "Bad Git object type for %s!" (OpamPackage.to_string pkg)
    )

(* Get a map of the versions inside [entry] (an entry under "packages") *)
let read_versions store (entry : Store.Value.Tree.entry) =
  Lwt_eio.run_lwt @@ fun () ->
  read_dir store entry.node >>= function
  | None -> Lwt.return OpamPackage.Version.Map.empty
  | Some tree ->
    Store.Value.Tree.to_list tree
    |> Lwt_list.filter_map_p (fun (entry : Store.Value.Tree.entry) ->
        match OpamPackage.of_string_opt entry.name with
        | Some pkg ->
          read_package store pkg entry.node >|= fun opam ->
          Some (pkg.version, opam)
        | None ->
          Log.info (fun f -> f "Invalid package name %S" entry.name);
          Lwt.return None
      )
    >|= OpamPackage.Version.Map.of_list

let read_packages ~store tree =
  Store.Value.Tree.to_list tree
  |> Lwt_list.filter_map_s (fun (entry : Store.Value.Tree.entry) ->
      match OpamPackage.Name.of_string entry.name with
      | exception ex ->
        Log.warn (fun f -> f "Invalid package name %S: %a" entry.name Fmt.exn ex);
        Lwt.return_none
      | name ->
        let versions = Eio.Lazy.from_fun ~cancel:`Restart (fun () -> read_versions store entry) in
        Lwt.return_some (name, versions)
    )
  >|= OpamPackage.Name.Map.of_list

let of_commit store commit : t =
  Lwt_eio.run_lwt @@ fun () ->
  Search.find store commit (`Commit (`Path [ "packages" ])) >>= function
  | None -> Fmt.failwith "Failed to find packages directory!"
  | Some tree_hash ->
    read_dir store tree_hash >>= function
    | None -> Fmt.failwith "'packages' is not a directory!"
    | Some tree -> read_packages ~store tree

let get_versions (t:t) name =
  match OpamPackage.Name.Map.find_opt name t with
  | None -> OpamPackage.Version.Map.empty
  | Some versions -> Eio.Lazy.force versions
