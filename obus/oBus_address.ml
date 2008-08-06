(*
 * oBus_address.ml
 * ---------------
 * Copyright : (c) 2008, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of obus, an ocaml implemtation of dbus.
 *)

type name = string
type key = string
type value = string
type guid = string

type family = Ipv4 | Ipv6

type desc =
  | Unix of string
  | Tcp of string * string * family option
  | Unknown of name * (key * value) list

type t = desc * guid option

exception Parse_error of string

let assoc key default list = match Util.assoc key list with
  | Some v -> v
  | None -> default

let of_string str =
  try
    let buf = Buffer.create 42 in
    let addresses = List.rev (Addr_lexer.addresses [] buf (Lexing.from_string str)) in
      List.map begin fun (name, params) ->
        (begin match name with
           | "unix" -> begin
               match Util.assoc "path" params, Util.assoc "abstract" params with
                 | Some path, None -> Unix path
                 | None, Some abst -> Unix ("\x00" ^ abst)
                 | None, None ->
                     ERROR("invalid unix address: can not specify \"path\" and \"abstract\" at the same time");
                     Unknown(name, params)
                 | Some _, Some _ ->
                     ERROR("invalid unix address: must specify \"path\" or \"abstract\"");
                     Unknown(name, params)
             end
           | "tcp" ->
               let host = assoc "host" "" params
               and port = assoc "port" "0" params in
               begin match Util.assoc "family" params with
                 | Some "ipv4" -> Tcp(host, port, Some Ipv4)
                 | Some "ipv6" -> Tcp(host, port, Some Ipv6)
                 | Some f ->
                     ERROR("unknown address family %s" f);
                     Unknown(name, params)
                 | None -> Tcp(host, port, None)
               end
           | _ -> Unknown(name, params)
         end,
         match Util.assoc "guid" params with
           | Some(guid_hex_encoded) ->
               let lexbuf = Lexing.from_string guid_hex_encoded in
                 Buffer.clear buf;
                 for i = 1 to (String.length guid_hex_encoded) / 2 do
                   Addr_lexer.unescape_char buf lexbuf
                 done;
                 Some(Buffer.contents buf)
           | None -> None) end addresses
  with
      Failure msg -> raise (Parse_error msg)

let system_bus_variable = "DBUS_SYSTEM_BUS_ADDRESS"
let session_bus_variable = "DBUS_SESSION_BUS_ADDRESS"
let session_bus_property = "_DBUS_SESSION_BUS_ADDRESS"

let default_system_bus_address = "unix:path=/var/run/dbus/system_bus_socket"

let system =
  lazy
    (of_string
       (try Sys.getenv system_bus_variable with
            Not_found ->
              DEBUG("environment variable %s not found, using internal default" system_bus_variable);
              default_system_bus_address))

let session =
  lazy
    (match
       try Some (Sys.getenv session_bus_variable) with
           Not_found ->
             LOG("environment variable %s not found" session_bus_variable);
             try
               (* Try with the root window property, this is bit ugly and
                  it depends on the presence of xprop... *)
               let ic = Unix.open_process_in
                 (Printf.sprintf "xprop -root %s" session_bus_property)
               in
               let result = try
                 Scanf.fscanf ic ("_DBUS_SESSION_BUS_ADDRESS(STRING) = %S") (fun s -> Some s)
               with
                   _ -> None
               in
                 ignore (Unix.close_process_in ic);
                 result
             with
                 _ ->
                   LOG("can not get session bus address from property %s on root window (maybe x11 is not running)"
                         session_bus_property);
                   None
     with
       | Some str -> of_string str
       | None -> [])
