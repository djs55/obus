(*
 * binder.ml
 * ---------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, a ocaml implemtation of dbus.
 *)

module type LanguageType =
sig
  val name : string

  type mono
  type poly

  type expr
  type module_sig = mono Interface.t
  type module_str

  val correct_module_name : string -> string
  val correct_signal_name : string -> string
  val correct_method_name : string -> string

  val default_type : DBus.typ -> mono

  val string_of_type : mono -> string
  val type_of_string : string -> mono
  val write_module_sigs : string -> module_sig Tree.t -> unit
  val write_module_strs : string -> module_str Tree.t -> unit

  val args : (Arg.key * Arg.spec * Arg.doc) list
end

module MakeSig(L : LanguageType) =
struct
  open L

  let xml_fnames = ref []
  let skipped_interfaces = ref []
  let permit_default = ref false
  let prefix = ref ["org\\.freedesktop\\."]
  let out = ref "out.obus.xml"
  let same_level = ref false

  let args = [
    ("-skip", Arg.String (fun s -> skipped_interfaces := s :: !skipped_interfaces), "skip interfaces matching regexp");
    ("-allow-default", Arg.Set permit_default, "do not skip default interfaces");
    ("-o", Arg.Set_string out, "output file (default = out.mli)");
    ("-prefix", Arg.String (fun p -> prefix := p :: !prefix), "prefix to delete from interface names");
    ("-flat", Arg.Set same_level, "do not include interfaces in each other")
  ] @ L.args

  open Xml

  let map_default_type l = List.map (fun (name, typ) -> (name, default_type typ)) l

  let map_args node l =
    List.map (fun (n, t) -> Element(node, [("name", n);
                                           ("dbus_type", DBus.string_of_type t);
                                           ("type", string_of_type (default_type t))], [])) l

  let map_interface = function
    | None -> []
    | Some(defs) -> List.map begin function
        | Interface.Method(dbus_name, ins, outs) ->
            Element("method", [("dbus_name", dbus_name);
                               ("name", correct_method_name dbus_name)],
                    map_args "in" ins @ map_args "out" outs)
        | Interface.Signal(dbus_name, args) ->
            Element("signal", [("dbus_name", dbus_name);
                               ("name", correct_signal_name dbus_name)],
                    map_args "arg" args)
      end defs

  let rec map_cascade dbus_names lang_names l =
    List.flatten begin List.map begin fun (dbus_name, Tree.Node(defs, l)) ->
      let dbus_names = dbus_name :: dbus_names in
      let complete_dbus_name = Util.rjoin "." dbus_names in
      let lang_name = correct_module_name dbus_name in
      let lang_names = lang_name :: lang_names in
      let complete_lang_name = Util.rjoin "." lang_names in
        Element("interface",
                [("dbus_name", complete_dbus_name);
                 ("name", complete_lang_name)],
                map_interface defs) :: map_cascade dbus_names lang_names l
    end l end

  let rec map_flatten dbus_names l =
    List.flatten begin List.map begin fun (dbus_name, Tree.Node(defs, l)) ->
      let dbus_names = dbus_name :: dbus_names in
      let complete_dbus_name = Util.rjoin "." dbus_names in
      let lang_name = correct_module_name (Util.rjoin "_" dbus_names) in
        Element("interface",
                [("dbus_name", complete_dbus_name);
                 ("name", lang_name)],
                map_interface defs) :: map_flatten dbus_names l
    end l end

  let remove_empty_interfaces xml =
    List.filter (function
                   | Element("interface", _, []) -> false
                   | _ -> true) xml

  let main () =
    Arg.parse args
      (fun s -> xml_fnames := s :: !xml_fnames)
      "generate a caml module signature from a introspection data";
    if not !permit_default
    then skipped_interfaces := !skipped_interfaces @ ["org\\.freedesktop\\.DBus.*"];

    let filters = List.map Str.regexp !skipped_interfaces in
    let prefix = List.map Str.regexp !prefix in
    let accept name = not (List.exists (fun r -> Str.string_match r name 0) filters) in
    let rec delete_prefix name = function
      | [] -> name
      | prefix :: prefixes ->
          if Str.string_match prefix name 0
          then Str.replace_first prefix "" name
          else delete_prefix name prefixes
    in
    let dbus_interfaces = List.fold_left
      (fun acc (name, interf) -> if accept name then Tree.add (delete_prefix name prefix) interf acc else acc)
      Tree.empty
      (List.flatten (List.map (fun fname -> Util.with_open_in fname
                                 (fun ch -> Interface.from_instrospection
                                    (Lexing.from_channel ch))) !xml_fnames)) in
    let xml_map =
      let xml_map =
        let (Tree.Node(_, l)) = dbus_interfaces in
          if !same_level
          then map_flatten [] l
          else map_cascade [] [] l in
        Element("map",
                [("file", !out);
                 ("language", L.name)],
                remove_empty_interfaces xml_map) in
      Util.with_open_out !out begin fun ch ->
        Printf.fprintf ch "<!-- File generated with %s -->\n" (Filename.basename (Sys.argv.(0)));
        output_string ch (Xml.to_string_fmt xml_map)
      end
end

module MakeStr(L : LanguageType) =
struct
  let main () = ()
end